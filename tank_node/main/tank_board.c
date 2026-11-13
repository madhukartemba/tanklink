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
    uint64_t mask = (1ULL << pin_full()) | (1ULL << pin_empty()) | (1ULL << pin_btn());
    gpio_config_t in = {
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
        .pin_bit_mask = mask,
    };
    ESP_ERROR_CHECK(gpio_config(&in));

    ESP_LOGI(TAG, "full=GPIO%d empty=GPIO%d (both pull-up) btn=GPIO%d led=GPIO%d",
             pin_full(), pin_empty(), pin_btn(), pin_led());
    return ESP_OK;
}

int tank_board_led_gpio(void)
{
    return pin_led();
}

bool tank_board_button_down(void)
{
    return gpio_get_level(pin_btn()) == 0;
}

void tank_board_read(tank_inputs_t *out)
{
    if (!out) {
        return;
    }
    out->full = gpio_get_level(pin_full()) != 0;
    out->empty = gpio_get_level(pin_empty()) != 0;
    out->button_down = tank_board_button_down();
}

static void arm_level(uint64_t mask, esp_sleep_gpio_wake_up_mode_t mode, const char *what)
{
    if (mask == 0) {
        return;
    }
    esp_err_t err = esp_sleep_enable_gpio_wakeup_on_hp_periph_powerdown(mask, mode);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "%s wake enable failed: %s", what, esp_err_to_name(err));
    }
}

void tank_board_prepare_deep_sleep(uint32_t heartbeat_sec)
{
    /* Button wake always (pair / OTA / manual TX). */
    if (gpio_get_level(pin_btn()) != 0) {
        arm_level(1ULL << pin_btn(), ESP_GPIO_WAKEUP_GPIO_LOW, "button");
    } else {
        ESP_LOGW(TAG, "button wake skipped (held or stuck LOW)");
    }

    if (heartbeat_sec == 0) {
        /* Unpaired: no timer, no float wake — only the button. */
        ESP_LOGI(TAG, "sleep: button-only (unpaired, no heartbeat)");
        return;
    }

    /* C3 deep-sleep GPIO wake is level-only. Arm the opposite of the level
     * sampled now so the next change (either way) wakes the chip. */
    uint64_t wake_high = 0;
    uint64_t wake_low = 0;
    if (gpio_get_level(pin_full()) == 0) {
        wake_high |= 1ULL << pin_full();
    } else {
        wake_low |= 1ULL << pin_full();
    }
    if (gpio_get_level(pin_empty()) == 0) {
        wake_high |= 1ULL << pin_empty();
    } else {
        wake_low |= 1ULL << pin_empty();
    }
    arm_level(wake_high, ESP_GPIO_WAKEUP_GPIO_HIGH, "float-high");
    arm_level(wake_low, ESP_GPIO_WAKEUP_GPIO_LOW, "float-low");
    ESP_LOGI(TAG, "float wake opposite: high_mask=0x%llx low_mask=0x%llx",
             (unsigned long long)wake_high, (unsigned long long)wake_low);

    if (heartbeat_sec < 5) {
        heartbeat_sec = 5;
    }
    ESP_ERROR_CHECK(esp_sleep_enable_timer_wakeup((uint64_t)heartbeat_sec * 1000000ULL));
    ESP_LOGI(TAG, "sleep: timer=%us + floats + button", (unsigned)heartbeat_sec);
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
    return gpio_get_level(pin_btn()) == 0;
}

bool tank_board_woke_from_float(void)
{
    if (!(esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_GPIO))) {
        return false;
    }
    if (gpio_get_level(pin_btn()) == 0) {
        return false;
    }
    /* Either edge is a float wake. The button path owns a held button. */
    return true;
}

bool tank_board_woke_from_timer(void)
{
    return (esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_TIMER)) != 0;
}

void tank_board_classify_button(uint32_t hold_threshold_ms, bool *is_hold,
                               uint32_t *held_ms,
                               void (*on_progress)(uint8_t pct, void *ctx),
                               void *ctx)
{
    if (is_hold) {
        *is_hold = false;
    }
    if (held_ms) {
        *held_ms = 0;
    }
    if (hold_threshold_ms < 1) {
        hold_threshold_ms = 1;
    }
    uint32_t t0 = xTaskGetTickCount();
    while (gpio_get_level(pin_btn()) == 0) {
        uint32_t ms = (xTaskGetTickCount() - t0) * portTICK_PERIOD_MS;
        if (held_ms) {
            *held_ms = ms;
        }
        if (on_progress) {
            uint8_t pct = (uint8_t)((ms >= hold_threshold_ms)
                                        ? 100
                                        : (ms * 100u / hold_threshold_ms));
            on_progress(pct, ctx);
        }
        if (ms >= hold_threshold_ms) {
            /* Enter hold/pair as soon as threshold is met — do not wait for
             * release (pairing mode waits for release before accepting cancel). */
            if (is_hold) {
                *is_hold = true;
            }
            if (held_ms) {
                *held_ms = ms;
            }
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (held_ms) {
        *held_ms = (xTaskGetTickCount() - t0) * portTICK_PERIOD_MS;
    }
    vTaskDelay(pdMS_TO_TICKS(30));
}

bool tank_board_wait_click(uint32_t timeout_ms)
{
    const TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(timeout_ms);
    /* Wait for press */
    while (xTaskGetTickCount() < deadline) {
        if (gpio_get_level(pin_btn()) == 0) {
            /* Debounce + wait release */
            vTaskDelay(pdMS_TO_TICKS(30));
            while (gpio_get_level(pin_btn()) == 0) {
                if (xTaskGetTickCount() >= deadline) {
                    return false;
                }
                vTaskDelay(pdMS_TO_TICKS(20));
            }
            vTaskDelay(pdMS_TO_TICKS(30));
            return true;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    return false;
}
