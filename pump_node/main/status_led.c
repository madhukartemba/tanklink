#include "status_led.h"

#include <math.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "led_strip.h"
#include "sdkconfig.h"

#define TAG "STATUS_LED"

#if !CONFIG_PUMP_ENABLE_NEOPIXEL
esp_err_t status_led_init(void)
{
    ESP_LOGI(TAG, "disabled");
    return ESP_OK;
}
void status_led_set_mode(status_led_mode_t mode)
{
    (void)mode;
}
void status_led_set_hold_progress(uint8_t percent)
{
    (void)percent;
}
status_led_mode_t status_led_get_mode(void)
{
    return STATUS_LED_IDLE;
}
#else

#ifndef CONFIG_PUMP_NEOPIXEL_COUNT
#define CONFIG_PUMP_NEOPIXEL_COUNT 1
#endif

#define FRAME_MS            16  /* ~60 fps */
#define CROSSFADE_MS        280.0f
#define HOLD_SMOOTH_HZ      14.0f
#define TWO_PI              6.28318530718f

typedef struct {
    float r;
    float g;
    float b;
} rgb_f_t;

static led_strip_handle_t s_strip;
static volatile status_led_mode_t s_mode = STATUS_LED_BOOT;
static volatile status_led_mode_t s_mode_from = STATUS_LED_BOOT;
static volatile uint8_t s_hold_pct_target;
static float s_hold_pct;
static int64_t s_mode_change_us;
static int64_t s_anim_start_us;
static uint32_t s_frame;
static float s_dither_err[CONFIG_PUMP_NEOPIXEL_COUNT][3];

static float clampf(float x, float lo, float hi)
{
    if (x < lo) {
        return lo;
    }
    if (x > hi) {
        return hi;
    }
    return x;
}

static float smootherstep(float t)
{
    t = clampf(t, 0.0f, 1.0f);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

/**
 * Convert linear 0..1 brightness to an 8-bit LED code with temporal dithering.
 * Avoids gamma-squashing (that made low breathes look stepped) and fakes
 * intermediate levels by alternating adjacent codes across frames.
 */
static uint8_t dither_u8(float v, float *err, uint32_t frame, int ch)
{
    v = clampf(v, 0.0f, 1.0f);
    float x = v * 255.0f + *err;
    /* Rotating threshold so frac parts don't lock into a steady pattern. */
    float thresh = ((frame * 37u + (uint32_t)ch * 91u) & 255u) / 255.0f;
    float base = floorf(x);
    float frac = x - base;
    uint8_t out = (uint8_t)base;
    if (frac > thresh && out < 255) {
        out++;
    }
    *err = x - (float)out;
    /* Keep error bounded so it can't drift. */
    *err = clampf(*err, -1.0f, 1.0f);
    return out;
}

static void write_pixel_f(int i, float r, float g, float b)
{
    uint8_t rr = dither_u8(r, &s_dither_err[i][0], s_frame, 0);
    uint8_t gg = dither_u8(g, &s_dither_err[i][1], s_frame, 1);
    uint8_t bb = dither_u8(b, &s_dither_err[i][2], s_frame, 2);
    led_strip_set_pixel(s_strip, i, rr, gg, bb);
}

static float sine01(float period_ms, float t_ms)
{
    if (period_ms < 1.0f) {
        period_ms = 1.0f;
    }
    float phase = fmodf(t_ms, period_ms) / period_ms;
    return 0.5f + 0.5f * sinf(phase * TWO_PI);
}

static void fill_rgb(rgb_f_t *out, float r, float g, float b)
{
    for (int i = 0; i < CONFIG_PUMP_NEOPIXEL_COUNT; i++) {
        out[i] = (rgb_f_t){r, g, b};
    }
}

static void render_idle(float t_ms, rgb_f_t *out)
{
    /* Continuous sine breathe — keep amplitude wide enough for many 8-bit steps. */
    float s = sine01(4800.0f, t_ms);
    float wave = smootherstep(s);
    float br = 0.10f + 0.28f * wave;
    fill_rgb(out, 0.0f, br, 0.0f);
}

static void render_connected(float t_ms, rgb_f_t *out)
{
    float s = smootherstep(sine01(3600.0f, t_ms));
    float br = 0.12f + 0.26f * s;
    fill_rgb(out, 0.0f, br * 0.90f, br * 0.80f);
}

static void render_unpaired(float t_ms, rgb_f_t *out)
{
    float s = smootherstep(sine01(2400.0f, t_ms));
    float br = 0.14f + 0.42f * s;
    fill_rgb(out, br, br * 0.42f, 0.0f);
}

static void render_pairing(float t_ms, rgb_f_t *out)
{
    int n = CONFIG_PUMP_NEOPIXEL_COUNT;
    if (n <= 1) {
        float s = smootherstep(sine01(900.0f, t_ms));
        float br = 0.28f + 0.62f * s;
        out[0] = (rgb_f_t){br, br * 0.55f, 0.0f};
        return;
    }

    const float lap_ms = 1400.0f;
    float head = fmodf(t_ms, lap_ms) / lap_ms * (float)n;
    for (int i = 0; i < n; i++) {
        float d = fabsf((float)i - head);
        float wrap = (float)n - d;
        if (wrap < d) {
            d = wrap;
        }
        float falloff = expf(-d * d * 1.8f);
        float br = 0.08f + 0.90f * falloff;
        out[i] = (rgb_f_t){br, br * 0.55f, 0.0f};
    }
}

static void render_pump_on(float t_ms, rgb_f_t *out)
{
    float s = smootherstep(sine01(2800.0f, t_ms));
    float br = 0.22f + 0.16f * s;
    fill_rgb(out, 0.0f, br, 0.0f);
}

static void render_updating(float t_ms, rgb_f_t *out)
{
    float s = smootherstep(sine01(700.0f, t_ms));
    float br = 0.20f + 0.55f * s;
    fill_rgb(out, br * 0.15f, br * 0.75f, br);
}

static void render_boot(float t_ms, rgb_f_t *out)
{
    float s = smootherstep(sine01(1600.0f, t_ms));
    float br = 0.06f + 0.14f * s;
    fill_rgb(out, br, br, br);
}

static void render_hold(float pct, rgb_f_t *out)
{
    int n = CONFIG_PUMP_NEOPIXEL_COUNT;
    float p = clampf(pct / 100.0f, 0.0f, 1.0f);
    float eased = smootherstep(p);

    if (n <= 1) {
        float br = 0.08f + 0.85f * eased;
        out[0] = (rgb_f_t){br * 0.16f, br * 0.78f, br};
        return;
    }

    float lit = eased * (float)n;
    for (int i = 0; i < n; i++) {
        float fill = clampf(lit - (float)i, 0.0f, 1.0f);
        out[i] = (rgb_f_t){fill * 0.08f, fill * 0.47f, fill * 0.78f};
    }
}

static void render_mode(status_led_mode_t mode, float t_ms, float hold_pct, rgb_f_t *out)
{
    switch (mode) {
    case STATUS_LED_BOOT:
        render_boot(t_ms, out);
        break;
    case STATUS_LED_UNPAIRED:
        render_unpaired(t_ms, out);
        break;
    case STATUS_LED_PAIRING:
        render_pairing(t_ms, out);
        break;
    case STATUS_LED_PUMP_ON:
        render_pump_on(t_ms, out);
        break;
    case STATUS_LED_CONNECTED:
        render_connected(t_ms, out);
        break;
    case STATUS_LED_HOLD_PROGRESS:
        render_hold(hold_pct, out);
        break;
    case STATUS_LED_UPDATING:
        render_updating(t_ms, out);
        break;
    case STATUS_LED_IDLE:
    default:
        render_idle(t_ms, out);
        break;
    }
}

static void anim_task(void *arg)
{
    (void)arg;
    rgb_f_t cur[CONFIG_PUMP_NEOPIXEL_COUNT];
    rgb_f_t from[CONFIG_PUMP_NEOPIXEL_COUNT];
    int64_t last_us = esp_timer_get_time();

    while (1) {
        int64_t now = esp_timer_get_time();
        float dt = (now - last_us) / 1000000.0f;
        if (dt < 0.0f) {
            dt = 0.0f;
        }
        if (dt > 0.1f) {
            dt = 0.1f;
        }
        last_us = now;

        float t_ms = (now - s_anim_start_us) / 1000.0f;
        if (t_ms < 0.0f) {
            t_ms = 0.0f;
        }

        float alpha = 1.0f - expf(-HOLD_SMOOTH_HZ * dt);
        s_hold_pct += ((float)s_hold_pct_target - s_hold_pct) * alpha;

        status_led_mode_t mode = s_mode;
        status_led_mode_t mode_from = s_mode_from;
        float blend = 1.0f;
        if (mode != mode_from) {
            float elapsed_ms = (now - s_mode_change_us) / 1000.0f;
            blend = smootherstep(elapsed_ms / CROSSFADE_MS);
            if (blend >= 1.0f) {
                s_mode_from = mode;
                mode_from = mode;
                blend = 1.0f;
            }
        }

        render_mode(mode, t_ms, s_hold_pct, cur);
        if (blend < 1.0f) {
            render_mode(mode_from, t_ms, s_hold_pct, from);
            for (int i = 0; i < CONFIG_PUMP_NEOPIXEL_COUNT; i++) {
                cur[i].r = from[i].r + (cur[i].r - from[i].r) * blend;
                cur[i].g = from[i].g + (cur[i].g - from[i].g) * blend;
                cur[i].b = from[i].b + (cur[i].b - from[i].b) * blend;
            }
        }

        for (int i = 0; i < CONFIG_PUMP_NEOPIXEL_COUNT; i++) {
            write_pixel_f(i, cur[i].r, cur[i].g, cur[i].b);
        }
        led_strip_refresh(s_strip);
        s_frame++;
        vTaskDelay(pdMS_TO_TICKS(FRAME_MS));
    }
}

esp_err_t status_led_init(void)
{
    led_strip_config_t strip_config = {
        .strip_gpio_num = CONFIG_PUMP_NEOPIXEL_GPIO,
        .max_leds = CONFIG_PUMP_NEOPIXEL_COUNT,
    };
    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = 10 * 1000 * 1000,
        .flags.with_dma = false,
    };
    esp_err_t err = led_strip_new_rmt_device(&strip_config, &rmt_config, &s_strip);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "led_strip init failed: %s", esp_err_to_name(err));
        return err;
    }
    led_strip_clear(s_strip);
    memset(s_dither_err, 0, sizeof(s_dither_err));
    s_anim_start_us = esp_timer_get_time();
    s_mode_change_us = s_anim_start_us;
    if (xTaskCreate(anim_task, "status_led", 4096, NULL, 4, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "NeoPixel GPIO %d count=%d frame=%dms (dithered)",
             CONFIG_PUMP_NEOPIXEL_GPIO, CONFIG_PUMP_NEOPIXEL_COUNT, FRAME_MS);
    status_led_set_mode(STATUS_LED_BOOT);
    return ESP_OK;
}

void status_led_set_mode(status_led_mode_t mode)
{
    if (s_mode == mode) {
        return;
    }
    s_mode_from = s_mode;
    s_mode = mode;
    s_mode_change_us = esp_timer_get_time();
}

void status_led_set_hold_progress(uint8_t percent)
{
    s_hold_pct_target = percent > 100 ? 100 : percent;
}

status_led_mode_t status_led_get_mode(void)
{
    return s_mode;
}

#endif /* CONFIG_PUMP_ENABLE_NEOPIXEL */
