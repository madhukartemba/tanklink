#include "tank_board.h"

#include "driver/gpio.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

/** Release shorter than this is contact bounce, not the end of a press. */
#define BUTTON_RELEASE_MS 80
/** A press shorter than this shows no light. */
#define HOLD_FEEDBACK_DELAY_MS 600

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

static void release_hold(int gpio)
{
    gpio_hold_dis((gpio_num_t)gpio);
}

/** Internal pull-up, no pull-down. Hold from the previous deep sleep locks the pad. */
static void force_pullup(int gpio)
{
    gpio_hold_dis((gpio_num_t)gpio);
    gpio_set_pull_mode((gpio_num_t)gpio, GPIO_PULLUP_ONLY);
}

esp_err_t tank_board_init(void)
{
    release_hold(pin_full());
    release_hold(pin_empty());
    release_hold(pin_btn());

    uint64_t mask = (1ULL << pin_full()) | (1ULL << pin_empty()) | (1ULL << pin_btn());
    gpio_config_t in = {
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
        .pin_bit_mask = mask,
    };
    esp_err_t err = gpio_config(&in);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "input config: %s", esp_err_to_name(err));
        return err;
    }

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
    out->sensor1 = gpio_get_level(pin_full()) != 0;
    out->sensor2 = gpio_get_level(pin_empty()) != 0;
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

/* The button was down when the tank last went to sleep (held, or stuck in
 * the enclosure). Kept through deep sleep. While it stays down it is not a
 * press: a float or timer wake must not read it as a hold and start pairing. */
static RTC_DATA_ATTR bool s_btn_stuck;

bool tank_board_button_pressed(void)
{
    const bool down = tank_board_button_down();
    if (!down) {
        s_btn_stuck = false; /* released: the next press is real */
    }
    return down && !s_btn_stuck;
}

void tank_board_prepare_deep_sleep(uint32_t timer_sec, bool float_wake)
{
    /* Always pull-up. C3 deep-sleep wake is level-only, so "state change"
     * means arming the opposite of the level sampled here. IDF must not
     * replace that pull-up with a pull-down (ESP_SLEEP_GPIO_ENABLE_INTERNAL_RESISTORS=n);
     * it then gpio_hold_en()s these pads and latches the pull-up through sleep. */
    force_pullup(pin_btn());
    force_pullup(pin_full());
    force_pullup(pin_empty());

    /* Button wake (pair / update / manual send). A button that is down now
     * can't be armed (it would wake at once); the timer below brings the
     * tank back to look again. */
    s_btn_stuck = gpio_get_level(pin_btn()) == 0;
    if (!s_btn_stuck) {
        arm_level(1ULL << pin_btn(), ESP_GPIO_WAKEUP_GPIO_LOW, "button");
    } else {
        ESP_LOGW(TAG, "button down at sleep: not armed, checked again at the next timer wake");
    }

    if (float_wake) {
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
    }

    /* A timer wake is always set, whatever else failed: no state can leave
     * the tank asleep for good with only the (unreachable) reset button. */
    if (timer_sec < 5) {
        timer_sec = 5;
    }
    ESP_ERROR_CHECK(esp_sleep_enable_timer_wakeup((uint64_t)timer_sec * 1000000ULL));
    ESP_LOGI(TAG, "sleep: timer=%us, floats %s, button %s", (unsigned)timer_sec,
             float_wake ? "armed" : "off", s_btn_stuck ? "off (down)" : "armed");
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

static bool wakeup_mask_has_button(void)
{
    uint64_t mask = esp_sleep_get_gpio_wakeup_status();
    while (mask) {
        const unsigned bit = (unsigned)__builtin_ctzll(mask);
        mask &= mask - 1;
        if ((int)esp_sleep_wakeup_io_bit2num(bit) == pin_btn()) {
            return true;
        }
    }
    return false;
}

bool tank_board_woke_from_button(void)
{
    if (!(esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_GPIO))) {
        return false;
    }
    /* A short tap is already released by the time we read the pin. The wake
     * mask still names the button, so it is not treated as a float change. A
     * button still down from before the sleep is not a press. */
    return tank_board_button_pressed() || wakeup_mask_has_button();
}

bool tank_board_woke_from_timer(void)
{
    return (esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_TIMER)) != 0;
}

void tank_button_hold_reset(tank_button_hold_t *hold)
{
    if (hold) {
        hold->hold_start_us = 0;
        hold->up_since_us = 0;
        hold->active = false;
    }
}

tank_button_hold_event_t tank_button_hold_poll(tank_button_hold_t *hold,
                                               uint32_t threshold_ms,
                                               uint32_t *held_ms, uint8_t *pct)
{
    if (held_ms) {
        *held_ms = 0;
    }
    if (pct) {
        *pct = 0;
    }
    if (!hold) {
        return TANK_HOLD_NONE;
    }
    if (threshold_ms < 1) {
        threshold_ms = 1;
    }
    const bool down = tank_board_button_down();
    const int64_t now = esp_timer_get_time();
    if (down) {
        hold->up_since_us = 0;
        if (!hold->active) {
            hold->active = true;
            hold->hold_start_us = now;
        }
        uint32_t ms = (uint32_t)((now - hold->hold_start_us) / 1000);
        if (held_ms) {
            *held_ms = ms;
        }
        /* Dark for a normal press; the light only starts once it is clearly
         * a hold, then ramps to full at the threshold. */
        uint8_t p = 100;
        if (ms < threshold_ms) {
            p = ms <= HOLD_FEEDBACK_DELAY_MS || threshold_ms <= HOLD_FEEDBACK_DELAY_MS
                    ? 0
                    : (uint8_t)((ms - HOLD_FEEDBACK_DELAY_MS) * 100u /
                                (threshold_ms - HOLD_FEEDBACK_DELAY_MS));
        }
        if (pct) {
            *pct = p;
        }
        return ms >= threshold_ms ? TANK_HOLD_REACHED : TANK_HOLD_HOLDING;
    }
    if (!hold->active) {
        return TANK_HOLD_NONE;
    }
    if (hold->up_since_us == 0) {
        hold->up_since_us = now;
    }
    const uint32_t ms = (uint32_t)((hold->up_since_us - hold->hold_start_us) / 1000);
    if (held_ms) {
        *held_ms = ms;
    }
    if ((now - hold->up_since_us) / 1000 < BUTTON_RELEASE_MS) {
        return TANK_HOLD_HOLDING;
    }
    hold->active = false;
    hold->hold_start_us = 0;
    hold->up_since_us = 0;
    return TANK_HOLD_RELEASED;
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
    tank_button_hold_t hold;
    tank_button_hold_reset(&hold);
    if (!tank_board_button_down()) {
        return;
    }
    for (;;) {
        uint32_t ms = 0;
        uint8_t pct = 0;
        const tank_button_hold_event_t ev =
            tank_button_hold_poll(&hold, hold_threshold_ms, &ms, &pct);
        if (held_ms) {
            *held_ms = ms;
        }
        if (on_progress && (ev == TANK_HOLD_HOLDING || ev == TANK_HOLD_REACHED)) {
            on_progress(pct, ctx);
        }
        if (ev == TANK_HOLD_REACHED) {
            if (is_hold) {
                *is_hold = true;
            }
            return;
        }
        if (ev == TANK_HOLD_RELEASED) {
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

