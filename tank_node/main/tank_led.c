#include "tank_led.h"

#include <math.h>

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#define TAG "TANK_LED"
#define LEDC_MODE LEDC_LOW_SPEED_MODE
#define LEDC_TIMER LEDC_TIMER_0
#define LEDC_CHANNEL LEDC_CHANNEL_0
#define LEDC_DUTY_RES LEDC_TIMER_13_BIT
#define LEDC_FREQ_HZ 5000
#define LEDC_MAX_DUTY ((1 << 13) - 1)

static bool s_ok;
static int s_gpio = -1;
static uint8_t s_pct;

/* Breathing animation (pairing, OTA): one task drives it from the clock. */
#define BREATHE_PAIR_MS 2400
#define BREATHE_OTA_MS 1400
#define BREATHE_STEP_MS 20
static TaskHandle_t s_anim_task;
static volatile bool s_anim_on;
static volatile uint32_t s_anim_period_ms;

void tank_led_force_off_pin(int gpio)
{
    if (gpio < 0) {
        return;
    }
    /*
     * GPIO6 (MTCK) has a weak ROM/JTAG pull-up at reset — enough to faintly
     * light an LED. Drive low + enable pulldown ASAP. A ~10 kΩ D4→GND on the
     * board is still recommended to kill glow before app_main runs.
     */
    gpio_hold_dis((gpio_num_t)gpio);
    gpio_reset_pin((gpio_num_t)gpio);
    gpio_set_direction((gpio_num_t)gpio, GPIO_MODE_OUTPUT);
    gpio_pulldown_en((gpio_num_t)gpio);
    gpio_pullup_dis((gpio_num_t)gpio);
    gpio_set_level((gpio_num_t)gpio, 0);
}

/* Runs before app_main — shrinks the post-wake LED glimmer window. */
static void tank_led_early_off(void) __attribute__((constructor));
static void tank_led_early_off(void)
{
    tank_led_force_off_pin(CONFIG_TANK_LED_GPIO);
}

static uint32_t duty_from_pct(uint8_t pct)
{
    if (pct > 100) {
        pct = 100;
    }
    /* Gamma-ish curve so mid ramps feel smoother on a plain LED. */
    const uint32_t x = pct;
    return (uint32_t)((x * x * LEDC_MAX_DUTY) / 10000u);
}

esp_err_t tank_led_init(int gpio)
{
    s_gpio = gpio;
    tank_led_force_off_pin(gpio);

    ledc_timer_config_t timer = {
        .speed_mode = LEDC_MODE,
        .duty_resolution = LEDC_DUTY_RES,
        .timer_num = LEDC_TIMER,
        .freq_hz = LEDC_FREQ_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    esp_err_t err = ledc_timer_config(&timer);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "timer: %s", esp_err_to_name(err));
        return err;
    }
    ledc_channel_config_t ch = {
        .gpio_num = gpio,
        .speed_mode = LEDC_MODE,
        .channel = LEDC_CHANNEL,
        .timer_sel = LEDC_TIMER,
        .duty = 0,
        .hpoint = 0,
    };
    err = ledc_channel_config(&ch);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "channel: %s", esp_err_to_name(err));
        return err;
    }
    ledc_set_duty(LEDC_MODE, LEDC_CHANNEL, 0);
    ledc_update_duty(LEDC_MODE, LEDC_CHANNEL);
    s_ok = true;
    s_pct = 0;
    ESP_LOGI(TAG, "LEDC GPIO%d", gpio);
    return ESP_OK;
}

void tank_led_set_brightness(uint8_t pct)
{
    if (!s_ok) {
        return;
    }
    s_pct = pct > 100 ? 100 : pct;
    ledc_set_duty(LEDC_MODE, LEDC_CHANNEL, duty_from_pct(s_pct));
    ledc_update_duty(LEDC_MODE, LEDC_CHANNEL);
}

void tank_led_set(bool on)
{
    tank_led_set_brightness(on ? 100 : 0);
}

void tank_led_off(void)
{
    tank_led_set_brightness(0);
}

void tank_led_prepare_deep_sleep(void)
{
    if (s_gpio < 0) {
        return;
    }
    if (s_ok) {
        ledc_stop(LEDC_MODE, LEDC_CHANNEL, 0);
        s_ok = false;
    }
    /* Drive low + pulldown only — no digital gpio_deep_sleep_hold (leaks ~mA). */
    tank_led_force_off_pin(s_gpio);
}

void tank_led_fade_to(uint8_t pct, uint32_t ms)
{
    if (!s_ok) {
        return;
    }
    if (ms < 20) {
        tank_led_set_brightness(pct);
        return;
    }
    const uint8_t start = s_pct;
    const int steps = (int)(ms / 20);
    for (int i = 1; i <= steps; i++) {
        uint8_t v = (uint8_t)(start + ((int)pct - (int)start) * i / steps);
        tank_led_set_brightness(v);
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    tank_led_set_brightness(pct);
}

void tank_led_fade_in_out(uint8_t peak, uint32_t in_ms, uint32_t out_ms)
{
    tank_led_fade_to(peak, in_ms);
    tank_led_fade_to(0, out_ms);
}

void tank_led_blink(int times, int on_ms, int off_ms)
{
    for (int i = 0; i < times; i++) {
        tank_led_set_brightness(100);
        vTaskDelay(pdMS_TO_TICKS(on_ms));
        tank_led_off();
        if (i + 1 < times) {
            vTaskDelay(pdMS_TO_TICKS(off_ms));
        }
    }
}

void tank_led_tx_pulse(void)
{
    tank_led_fade_to(80, 40);
    tank_led_fade_to(0, 60);
}

void tank_led_boot(void)
{
    tank_led_fade_in_out(100, 350, 350);
    tank_led_fade_in_out(70, 250, 250);
}

void tank_led_success(void)
{
    /* Single soft pulse after a successful TX / pair ACK. */
    tank_led_fade_in_out(100, 180, 220);
}

void tank_led_failure(void)
{
    /* Generic failure: short hard blinks (distinct from numbered error codes). */
    for (int i = 0; i < 3; i++) {
        tank_led_set_brightness(100);
        vTaskDelay(pdMS_TO_TICKS(200));
        tank_led_off();
        vTaskDelay(pdMS_TO_TICKS(160));
    }
}

/** Cosine breathe: dark to full and back over one period, eased at both
 * ends. The phase comes from the clock, so a busy radio loop can't make it
 * stall or race. */
static void anim_task(void *arg)
{
    (void)arg;
    const int64_t t0 = esp_timer_get_time();
    while (s_anim_on) {
        const uint32_t period = s_anim_period_ms;
        const uint32_t ms = (uint32_t)((esp_timer_get_time() - t0) / 1000) % period;
        const float v = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * (float)ms / (float)period);
        tank_led_set_brightness((uint8_t)(2.0f + v * 98.0f));
        vTaskDelay(pdMS_TO_TICKS(BREATHE_STEP_MS));
    }
    s_anim_task = NULL;
    vTaskDelete(NULL);
}

static void anim_start(uint32_t period_ms)
{
    if (!s_ok) {
        return;
    }
    s_anim_period_ms = period_ms;
    if (s_anim_task) {
        return; /* already breathing: just the new speed */
    }
    s_anim_on = true;
    /* Above the main task, so it keeps time while the radio waits. */
    if (xTaskCreate(anim_task, "led_anim", 2048, NULL, 5, &s_anim_task) != pdPASS) {
        s_anim_on = false;
        s_anim_task = NULL;
        ESP_LOGW(TAG, "LED animation task not started");
    }
}

static void anim_stop(void)
{
    s_anim_on = false;
    /* Wait for the task to finish its step, so nothing writes after this. */
    for (int i = 0; i < 20 && s_anim_task; i++) {
        vTaskDelay(pdMS_TO_TICKS(5));
    }
    tank_led_off();
}

void tank_led_pairing_flash_start(void)
{
    anim_start(BREATHE_PAIR_MS);
}

void tank_led_pairing_flash_stop(void)
{
    anim_stop();
}

void tank_led_ota_pulse_start(void)
{
    anim_start(BREATHE_OTA_MS);
}

void tank_led_ota_pulse_stop(void)
{
    anim_stop();
}

void tank_led_show_error(uint8_t code)
{
    if (code < 1) {
        code = 1;
    }
    if (code > 9) {
        code = 9;
    }
    /* Short flash, long dark gap, so each flash is easy to count.
     * The same count is shown twice, with a longer gap between the two. */
    tank_led_off();
    for (int pass = 0; pass < 2; pass++) {
        vTaskDelay(pdMS_TO_TICKS(800));
        for (int i = 0; i < code; i++) {
            tank_led_set_brightness(100);
            vTaskDelay(pdMS_TO_TICKS(160));
            tank_led_off();
            vTaskDelay(pdMS_TO_TICKS(700));
        }
        if (pass == 0) {
            vTaskDelay(pdMS_TO_TICKS(1400));
        }
    }
}
