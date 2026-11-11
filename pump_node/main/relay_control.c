#include "relay_control.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "pump_config.h"
#include "sdkconfig.h"

#define TAG "RELAY"

#ifndef CONFIG_PUMP_RELAY_START_GPIO
#define CONFIG_PUMP_RELAY_START_GPIO (-1)
#endif
#ifndef CONFIG_PUMP_RELAY_STOP_GPIO
#define CONFIG_PUMP_RELAY_STOP_GPIO (-1)
#endif
#ifndef CONFIG_PUMP_RELAY_ACTIVE_HIGH
#define CONFIG_PUMP_RELAY_ACTIVE_HIGH 1
#endif
#ifndef CONFIG_PUMP_RELAY_PULSE_MS
#define CONFIG_PUMP_RELAY_PULSE_MS 400
#endif

static SemaphoreHandle_t s_mu;
static pump_starter_type_t s_type = PUMP_STARTER_NONE;
static bool s_running;
static bool s_blocked;
static bool s_start_gpio_ok;
static bool s_stop_gpio_ok;
static esp_timer_handle_t s_pulse_timer;
static int s_pulse_gpio = -1;
static uint16_t s_pulse_ms = CONFIG_PUMP_RELAY_PULSE_MS;

static uint16_t clamp_pulse_ms(uint16_t ms)
{
    if (ms < 50) {
        return 50;
    }
    if (ms > 2000) {
        return 2000;
    }
    return ms;
}

static int start_gpio(void)
{
    return CONFIG_PUMP_RELAY_START_GPIO;
}

static int stop_gpio(void)
{
    return CONFIG_PUMP_RELAY_STOP_GPIO;
}

static int relay_idle_level(void)
{
    return CONFIG_PUMP_RELAY_ACTIVE_HIGH ? 0 : 1;
}

static int relay_active_level(void)
{
    return CONFIG_PUMP_RELAY_ACTIVE_HIGH ? 1 : 0;
}

static bool gpio_assigned(int gpio)
{
    return gpio >= 0;
}

bool relay_control_gpios_assigned(void)
{
    return s_start_gpio_ok && s_stop_gpio_ok;
}

static esp_err_t configure_output(int gpio)
{
    if (!gpio_assigned(gpio)) {
        return ESP_ERR_INVALID_ARG;
    }
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << gpio,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t err = gpio_config(&io);
    if (err != ESP_OK) {
        return err;
    }
    return gpio_set_level(gpio, relay_idle_level());
}

static void end_pulse(void)
{
    if (s_pulse_gpio >= 0) {
        gpio_set_level(s_pulse_gpio, relay_idle_level());
        s_pulse_gpio = -1;
    }
}

static void pulse_timer_cb(void *arg)
{
    (void)arg;
    if (s_mu && xSemaphoreTake(s_mu, 0) == pdTRUE) {
        end_pulse();
        xSemaphoreGive(s_mu);
    } else {
        end_pulse();
    }
}

static void pulse_gpio(int gpio)
{
    if (!gpio_assigned(gpio)) {
        return;
    }
    /* Cancel any in-flight pulse first (never leave a relay stuck on). */
    if (s_pulse_timer) {
        esp_timer_stop(s_pulse_timer);
    }
    end_pulse();
    s_pulse_gpio = gpio;
    gpio_set_level(gpio, relay_active_level());
    if (s_pulse_timer) {
        esp_timer_start_once(s_pulse_timer, (uint64_t)s_pulse_ms * 1000ULL);
    }
}

static void two_button_stop_pulse(void)
{
    /* Drop Start if somehow held, then pulse Stop. */
    if (s_start_gpio_ok) {
        gpio_set_level(start_gpio(), relay_idle_level());
    }
    if (s_pulse_timer) {
        esp_timer_stop(s_pulse_timer);
    }
    end_pulse();
    if (s_stop_gpio_ok) {
        pulse_gpio(stop_gpio());
    } else {
        ESP_LOGW(TAG, "Stop pulse skipped — STOP GPIO not assigned");
    }
}

static void two_button_start_pulse(void)
{
    if (s_stop_gpio_ok) {
        gpio_set_level(stop_gpio(), relay_idle_level());
    }
    if (s_pulse_timer) {
        esp_timer_stop(s_pulse_timer);
    }
    end_pulse();
    if (s_start_gpio_ok) {
        pulse_gpio(start_gpio());
    } else {
        ESP_LOGW(TAG, "Start pulse skipped — START GPIO not assigned");
    }
}

esp_err_t relay_control_init(void)
{
    s_mu = xSemaphoreCreateMutex();
    if (!s_mu) {
        return ESP_ERR_NO_MEM;
    }

    s_type = (pump_starter_type_t)pump_config_starter_type();
    if (s_type >= PUMP_STARTER_COUNT) {
        s_type = PUMP_STARTER_NONE;
    }
    s_pulse_ms = clamp_pulse_ms(pump_config_relay_pulse_ms());
    s_running = false;
    s_blocked = false;

    const int sg = start_gpio();
    const int tg = stop_gpio();
    s_start_gpio_ok = false;
    s_stop_gpio_ok = false;

    if (gpio_assigned(sg)) {
        if (configure_output(sg) == ESP_OK) {
            s_start_gpio_ok = true;
        } else {
            ESP_LOGE(TAG, "START GPIO %d config failed", sg);
        }
    }
    if (gpio_assigned(tg)) {
        if (configure_output(tg) == ESP_OK) {
            s_stop_gpio_ok = true;
        } else {
            ESP_LOGE(TAG, "STOP GPIO %d config failed", tg);
        }
    }

    const esp_timer_create_args_t targs = {
        .callback = &pulse_timer_cb,
        .name = "relay_pulse",
    };
    if (esp_timer_create(&targs, &s_pulse_timer) != ESP_OK) {
        ESP_LOGW(TAG, "pulse timer create failed — pulses may stick");
        s_pulse_timer = NULL;
    }

    ESP_LOGI(TAG,
             "type=%u start_gpio=%d (%s) stop_gpio=%d (%s) pulse=%ums",
             (unsigned)s_type, sg, s_start_gpio_ok ? "ok" : "unassigned", tg,
             s_stop_gpio_ok ? "ok" : "unassigned", (unsigned)s_pulse_ms);

    /* Safety: always force Stop on boot, whether or not we think it was on. */
    relay_control_force_off();
    return ESP_OK;
}

void relay_control_force_off(void)
{
    if (s_mu) {
        xSemaphoreTake(s_mu, portMAX_DELAY);
    }
    s_running = false;
    switch (s_type) {
    case PUMP_STARTER_TWO_BUTTON:
        two_button_stop_pulse();
        break;
    case PUMP_STARTER_NONE:
    default:
        end_pulse();
        break;
    }
    if (s_mu) {
        xSemaphoreGive(s_mu);
    }
    ESP_LOGI(TAG, "force_off");
}

void relay_control_set_running(bool on)
{
    if (s_mu) {
        xSemaphoreTake(s_mu, portMAX_DELAY);
    }

    if (on) {
        if (s_blocked) {
            ESP_LOGW(TAG, "start denied — blocked");
            if (s_mu) {
                xSemaphoreGive(s_mu);
            }
            return;
        }
        if (s_running) {
            if (s_mu) {
                xSemaphoreGive(s_mu);
            }
            return;
        }
        switch (s_type) {
        case PUMP_STARTER_TWO_BUTTON:
            two_button_start_pulse();
            break;
        case PUMP_STARTER_NONE:
        default:
            break;
        }
        s_running = true;
        ESP_LOGI(TAG, "running=1 type=%u", (unsigned)s_type);
    } else {
        if (!s_running) {
            /* Still pulse Stop for two-button — safer if out of sync. */
            if (s_type == PUMP_STARTER_TWO_BUTTON) {
                two_button_stop_pulse();
            }
            if (s_mu) {
                xSemaphoreGive(s_mu);
            }
            return;
        }
        switch (s_type) {
        case PUMP_STARTER_TWO_BUTTON:
            two_button_stop_pulse();
            break;
        case PUMP_STARTER_NONE:
        default:
            break;
        }
        s_running = false;
        ESP_LOGI(TAG, "running=0");
    }

    if (s_mu) {
        xSemaphoreGive(s_mu);
    }
}

void relay_control_set_blocked(bool blocked)
{
    if (s_mu) {
        xSemaphoreTake(s_mu, portMAX_DELAY);
    }
    const bool was = s_blocked;
    s_blocked = blocked;
    if (s_mu) {
        xSemaphoreGive(s_mu);
    }
    if (blocked && !was) {
        ESP_LOGW(TAG, "blocked — forcing off");
        relay_control_force_off();
    } else if (!blocked && was) {
        ESP_LOGI(TAG, "unblocked");
    }
}

bool relay_control_is_blocked(void)
{
    return s_blocked;
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
    if (s_mu) {
        xSemaphoreTake(s_mu, portMAX_DELAY);
    }
    if (s_type != type) {
        /* Changing profile: always stop first. */
        if (s_mu) {
            xSemaphoreGive(s_mu);
        }
        relay_control_force_off();
        if (s_mu) {
            xSemaphoreTake(s_mu, portMAX_DELAY);
        }
        s_type = type;
        ESP_LOGI(TAG, "starter type -> %u", (unsigned)type);
    }
    if (s_mu) {
        xSemaphoreGive(s_mu);
    }
    return ESP_OK;
}

uint16_t relay_control_get_pulse_ms(void)
{
    return s_pulse_ms;
}

void relay_control_set_pulse_ms(uint16_t ms)
{
    s_pulse_ms = clamp_pulse_ms(ms);
    ESP_LOGI(TAG, "pulse -> %ums", (unsigned)s_pulse_ms);
}
