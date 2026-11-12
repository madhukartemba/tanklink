#include "tank_board.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#define TAG "TANK_BOARD"

static int pin_full(void)
{
    return CONFIG_TANK_FLOAT_FULL_GPIO;
}
static int pin_empty(void)
{
    return CONFIG_TANK_FLOAT_EMPTY_GPIO;
}
static int pin_btn(void)
{
    return CONFIG_TANK_BUTTON_GPIO;
}
static int pin_led(void)
{
    return CONFIG_TANK_LED_GPIO;
}

esp_err_t tank_board_init(void)
{
    gpio_config_t in = {
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
        .pin_bit_mask = (1ULL << pin_full()) | (1ULL << pin_empty()) | (1ULL << pin_btn()),
    };
    ESP_ERROR_CHECK(gpio_config(&in));

    gpio_config_t led = {
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
        .pin_bit_mask = 1ULL << pin_led(),
    };
    ESP_ERROR_CHECK(gpio_config(&led));
    gpio_set_level(pin_led(), 0);

    ESP_LOGI(TAG, "full=GPIO%d empty=GPIO%d btn=GPIO%d led=GPIO%d", pin_full(),
             pin_empty(), pin_btn(), pin_led());
    return ESP_OK;
}

void tank_board_read(tank_inputs_t *out)
{
    if (!out) {
        return;
    }
    out->full = gpio_get_level(pin_full()) != 0;
    out->empty = gpio_get_level(pin_empty()) != 0;
    out->button_down = gpio_get_level(pin_btn()) == 0;
}

void tank_led_set(bool on)
{
    gpio_set_level(pin_led(), on ? 1 : 0);
}

void tank_led_blink(int times, int on_ms, int off_ms)
{
    for (int i = 0; i < times; i++) {
        tank_led_set(true);
        vTaskDelay(pdMS_TO_TICKS(on_ms));
        tank_led_set(false);
        if (i + 1 < times) {
            vTaskDelay(pdMS_TO_TICKS(off_ms));
        }
    }
}

void tank_led_tx_pulse(void)
{
    tank_led_set(true);
    vTaskDelay(pdMS_TO_TICKS(40));
    tank_led_set(false);
}

void tank_board_prepare_deep_sleep(uint32_t heartbeat_sec)
{
    /*
     * Level wake only if the pin is currently inactive — otherwise a floating
     * pull-up (unwired float = HIGH) would prevent sleep / instant-wake.
     * Unwired floats stuck HIGH → heartbeat-only until real floats are fitted.
     */
    uint64_t wake_high = 0;
    if (gpio_get_level(pin_full()) == 0) {
        wake_high |= 1ULL << pin_full();
    }
    if (gpio_get_level(pin_empty()) == 0) {
        wake_high |= 1ULL << pin_empty();
    }
    if (wake_high) {
        esp_err_t err = esp_sleep_enable_gpio_wakeup_on_hp_periph_powerdown(
            wake_high, ESP_GPIO_WAKEUP_GPIO_HIGH);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "float wake enable failed: %s", esp_err_to_name(err));
        }
    } else {
        ESP_LOGI(TAG, "float wake skipped (pins already HIGH / unwired)");
    }

    if (gpio_get_level(pin_btn()) != 0) {
        esp_err_t err = esp_sleep_enable_gpio_wakeup_on_hp_periph_powerdown(
            1ULL << pin_btn(), ESP_GPIO_WAKEUP_GPIO_LOW);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "button wake enable failed: %s", esp_err_to_name(err));
        }
    } else {
        ESP_LOGW(TAG, "button wake skipped (held or stuck LOW)");
    }

    if (heartbeat_sec < 30) {
        heartbeat_sec = 30;
    }
    ESP_ERROR_CHECK(esp_sleep_enable_timer_wakeup((uint64_t)heartbeat_sec * 1000000ULL));
    ESP_LOGI(TAG, "sleep: timer=%us", (unsigned)heartbeat_sec);
}

esp_sleep_wakeup_cause_t tank_board_wakeup_cause(void)
{
    const uint32_t causes = esp_sleep_get_wakeup_causes();
    if (causes & BIT(ESP_SLEEP_WAKEUP_TIMER)) {
        return ESP_SLEEP_WAKEUP_TIMER;
    }
    if (causes & BIT(ESP_SLEEP_WAKEUP_GPIO)) {
        return ESP_SLEEP_WAKEUP_GPIO;
    }
    return ESP_SLEEP_WAKEUP_UNDEFINED;
}

bool tank_board_woke_from_button(void)
{
    if (!(esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_GPIO))) {
        return false;
    }
    /* After wake, button still held → likely button; floats are level-high. */
    return gpio_get_level(pin_btn()) == 0;
}

bool tank_board_woke_from_float(void)
{
    if (!(esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_GPIO))) {
        return false;
    }
    return gpio_get_level(pin_btn()) != 0 &&
           (gpio_get_level(pin_full()) != 0 || gpio_get_level(pin_empty()) != 0);
}

bool tank_board_woke_from_timer(void)
{
    return (esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_TIMER)) != 0;
}

void tank_board_classify_button(uint32_t hold_threshold_ms, bool *is_hold,
                               uint32_t *held_ms)
{
    if (is_hold) {
        *is_hold = false;
    }
    if (held_ms) {
        *held_ms = 0;
    }
    uint32_t t0 = xTaskGetTickCount();
    while (gpio_get_level(pin_btn()) == 0) {
        uint32_t ms = (xTaskGetTickCount() - t0) * portTICK_PERIOD_MS;
        if (held_ms) {
            *held_ms = ms;
        }
        if (ms >= hold_threshold_ms) {
            if (is_hold) {
                *is_hold = true;
            }
            /* Wait for release so we don't re-wake immediately. */
            while (gpio_get_level(pin_btn()) == 0) {
                vTaskDelay(pdMS_TO_TICKS(20));
            }
            vTaskDelay(pdMS_TO_TICKS(30));
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (held_ms) {
        *held_ms = (xTaskGetTickCount() - t0) * portTICK_PERIOD_MS;
    }
    vTaskDelay(pdMS_TO_TICKS(30)); /* debounce release */
}
