#include "relay_control.h"

#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "pump_config.h"
#include "sdkconfig.h"

#define TAG "RELAY"

/* Relay 1 (START, and the held relay of a single-phase starter) and relay 2 (STOP). */
#define START_GPIO CONFIG_PUMP_RELAY_START_GPIO
#define STOP_GPIO CONFIG_PUMP_RELAY_STOP_GPIO

/* Bool Kconfig: undefined means "n" (active-low). */
#ifdef CONFIG_PUMP_RELAY_ACTIVE_HIGH
#define LEVEL_ACTIVE 1
#else
#define LEVEL_ACTIVE 0
#endif
#define LEVEL_IDLE (1 - LEVEL_ACTIVE)

static SemaphoreHandle_t s_mu;
static pump_starter_type_t s_type = PUMP_STARTER_NONE;
static bool s_running;
static uint8_t s_blocks; /* relay_block_t bits */
static bool s_start_ok;  /* GPIO assigned and configured */
static bool s_stop_ok;
static esp_timer_handle_t s_pulse_timer;
static int s_pulse_gpio = -1;
static int64_t s_pulse_end_us;
static uint16_t s_pulse_ms;

static esp_err_t configure_output(int gpio)
{
    /* Latch the idle level BEFORE enabling the output driver, so the pin never
     * drives the active level (out reg resets to 0 = ON for active-low). */
    gpio_set_level(gpio, LEVEL_IDLE);
    const gpio_config_t io = {
        .pin_bit_mask = 1ULL << gpio,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&io), TAG, "GPIO %d config", gpio);
    return gpio_set_level(gpio, LEVEL_IDLE);
}

/* ---- Pulses (two-button). Everything below runs with s_mu held. ---- */

static void end_pulse(void)
{
    if (s_pulse_gpio >= 0) {
        gpio_set_level(s_pulse_gpio, LEVEL_IDLE);
        s_pulse_gpio = -1;
    }
}

static void pulse_timer_cb(void *arg)
{
    (void)arg;
    xSemaphoreTake(s_mu, portMAX_DELAY);
    /* A new pulse may have started while this callback waited for the lock:
     * only end the pulse this timer was set for. */
    if (esp_timer_get_time() >= s_pulse_end_us) {
        end_pulse();
    }
    xSemaphoreGive(s_mu);
}

static void cancel_pulse(void)
{
    esp_timer_stop(s_pulse_timer); /* ESP_ERR_INVALID_STATE when idle: fine */
    end_pulse();
}

static void pulse(int gpio)
{
    cancel_pulse();
    s_pulse_gpio = gpio;
    s_pulse_end_us = esp_timer_get_time() + (int64_t)s_pulse_ms * 1000;
    gpio_set_level(gpio, LEVEL_ACTIVE);
    ESP_ERROR_CHECK(esp_timer_start_once(s_pulse_timer, (uint64_t)s_pulse_ms * 1000ULL));
}

/** Put both relays at rest, whatever the profile. */
static void all_idle(void)
{
    cancel_pulse();
    if (s_start_ok) {
        gpio_set_level(START_GPIO, LEVEL_IDLE);
    }
    if (s_stop_ok) {
        gpio_set_level(STOP_GPIO, LEVEL_IDLE);
    }
}

static void hw_start(void)
{
    switch (s_type) {
    case PUMP_STARTER_TWO_BUTTON:
        all_idle();
        if (s_start_ok) {
            pulse(START_GPIO);
        } else {
            ESP_LOGE(TAG, "start: relay 1 GPIO not assigned");
        }
        break;
    case PUMP_STARTER_SINGLE_PHASE:
        all_idle();
        if (s_start_ok) {
            gpio_set_level(START_GPIO, LEVEL_ACTIVE); /* held until stop */
        } else {
            ESP_LOGE(TAG, "start: relay 1 GPIO not assigned");
        }
        break;
    default:
        break;
    }
}

static void hw_stop(void)
{
    all_idle(); /* single-phase: dropping relay 1 is the stop */
    if (s_type == PUMP_STARTER_TWO_BUTTON) {
        if (s_stop_ok) {
            pulse(STOP_GPIO);
        } else {
            ESP_LOGE(TAG, "stop: relay 2 GPIO not assigned");
        }
    }
}

/* ---- Public ---- */

void relay_control_early_safe(void)
{
    /* Called first thing in app_main (before NVS): drive relays idle ASAP. */
    if (START_GPIO >= 0) {
        (void)configure_output(START_GPIO);
    }
    if (STOP_GPIO >= 0) {
        (void)configure_output(STOP_GPIO);
    }
}

esp_err_t relay_control_init(void)
{
    s_mu = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_mu, ESP_ERR_NO_MEM, TAG, "mutex");
    const esp_timer_create_args_t targs = {
        .callback = &pulse_timer_cb,
        .name = "relay_pulse",
    };
    ESP_RETURN_ON_ERROR(esp_timer_create(&targs, &s_pulse_timer), TAG, "pulse timer");

    s_type = (pump_starter_type_t)pump_config_starter_type(); /* checked on load */
    s_pulse_ms = pump_config_relay_pulse_ms();
    s_start_ok = START_GPIO >= 0 && configure_output(START_GPIO) == ESP_OK;
    s_stop_ok = STOP_GPIO >= 0 && configure_output(STOP_GPIO) == ESP_OK;

    ESP_LOGI(TAG, "type=%u relay1=GPIO%d (%s) relay2=GPIO%d (%s) pulse=%ums", (unsigned)s_type,
             START_GPIO, s_start_ok ? "ok" : "unassigned", STOP_GPIO,
             s_stop_ok ? "ok" : "unassigned", (unsigned)s_pulse_ms);

    /* Safety: always stop on boot, whether or not it was running. */
    relay_control_stop();
    return ESP_OK;
}

bool relay_control_start(void)
{
    xSemaphoreTake(s_mu, portMAX_DELAY);
    const bool ok = s_blocks == 0;
    if (!ok) {
        ESP_LOGW(TAG, "start denied: blocked (0x%02x)", s_blocks);
    } else if (!s_running) {
        hw_start();
        s_running = true;
        ESP_LOGI(TAG, "running type=%u", (unsigned)s_type);
    }
    xSemaphoreGive(s_mu);
    return ok;
}

void relay_control_stop(void)
{
    xSemaphoreTake(s_mu, portMAX_DELAY);
    hw_stop();
    s_running = false;
    xSemaphoreGive(s_mu);
    ESP_LOGI(TAG, "stop");
}

void relay_control_block(relay_block_t why, bool on)
{
    xSemaphoreTake(s_mu, portMAX_DELAY);
    const uint8_t before = s_blocks;
    s_blocks = on ? (uint8_t)(s_blocks | why) : (uint8_t)(s_blocks & ~why);
    const bool newly = before == 0 && s_blocks != 0;
    xSemaphoreGive(s_mu);
    if (newly) {
        ESP_LOGW(TAG, "blocked (0x%02x): stopping", s_blocks);
        relay_control_stop();
    } else if (before != 0 && s_blocks == 0) {
        ESP_LOGI(TAG, "unblocked");
    }
}

bool relay_control_is_blocked(void)
{
    return s_blocks != 0;
}

bool relay_control_is_running(void)
{
    return s_running;
}

pump_starter_type_t relay_control_get_type(void)
{
    return s_type;
}

esp_err_t relay_control_set_type(pump_starter_type_t type)
{
    if (type >= PUMP_STARTER_COUNT) {
        return ESP_ERR_INVALID_ARG;
    }
    xSemaphoreTake(s_mu, portMAX_DELAY);
    if (s_type != type) {
        hw_stop(); /* with the old profile: a held relay 1 drops here */
        s_running = false;
        s_type = type;
        ESP_LOGI(TAG, "starter type -> %u", (unsigned)type);
    }
    xSemaphoreGive(s_mu);
    return ESP_OK;
}

void relay_control_set_pulse_ms(uint16_t ms)
{
    xSemaphoreTake(s_mu, portMAX_DELAY);
    s_pulse_ms = ms;
    xSemaphoreGive(s_mu);
}
