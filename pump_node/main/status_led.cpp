#include "status_led.h"

#include <algorithm>
#include <cmath>
#include <memory>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "pixelengine/pixel_engine.hpp"
#include "sdkconfig.h"

#define TAG "STATUS_LED"

#if !CONFIG_PUMP_ENABLE_NEOPIXEL

extern "C" esp_err_t status_led_init(void)
{
    ESP_LOGI(TAG, "disabled");
    return ESP_OK;
}
extern "C" void status_led_set_mode(status_led_mode_t mode)
{
    (void)mode;
}
extern "C" void status_led_set_hold_progress(uint8_t percent)
{
    (void)percent;
}
extern "C" void status_led_set_update_progress(uint8_t percent)
{
    (void)percent;
}
extern "C" void status_led_set_brightness(uint8_t percent)
{
    (void)percent;
}
extern "C" uint8_t status_led_get_brightness(void)
{
    return 70;
}
extern "C" status_led_mode_t status_led_get_mode(void)
{
    return STATUS_LED_IDLE;
}

#else

#ifndef CONFIG_PUMP_NEOPIXEL_COUNT
#define CONFIG_PUMP_NEOPIXEL_COUNT 1
#endif

/* ~50 Hz — enough for smooth breathe; less RMT contention vs BLE. */
#define FRAME_MS 20

using pixelengine::Color;
using pixelengine::Layout;
using pixelengine::PixelEngine;

namespace {

PixelEngine s_px;
volatile status_led_mode_t s_mode = STATUS_LED_BOOT;
volatile uint8_t s_hold_pct_target = 0;
volatile uint8_t s_ota_pct_target = 0;
volatile uint8_t s_brightness_pct = 70;
float s_hold_pct = 0.0f;
float s_ota_pct = 0.0f;
float s_bri = 0.70f;

static float clamp01(float v)
{
    if (v < 0.0f) {
        return 0.0f;
    }
    if (v > 1.0f) {
        return 1.0f;
    }
    return v;
}

static float smoother01(float t)
{
    t = clamp01(t);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

static float now_sec(void)
{
    return static_cast<float>(esp_timer_get_time()) * 1e-6f;
}

static uint32_t scale_bri(uint32_t c, float t)
{
    return Color::scale(c, clamp01(t) * s_bri);
}

/** Soft left→right fill used for hold + OTA progress. */
class ProgressFill final : public pixelengine::Animation {
   public:
    ProgressFill(size_t led_count, const float *pct, uint32_t color)
        : pct_(pct), color_(color)
    {
        led_count_ = led_count;
        layout_ = Layout::Linear;
        buffer_.assign(led_count_, 0);
    }

    void update() override
    {
        if (led_count_ == 0 || pct_ == nullptr) {
            return;
        }
        const float p = clamp01(*pct_ / 100.0f);
        const float lit = p * static_cast<float>(led_count_);
        for (size_t i = 0; i < led_count_; ++i) {
            float fill = lit - static_cast<float>(i);
            fill = clamp01(fill);
            /* Only progress LEDs lit — unfilled stay off. */
            buffer_[i] = (fill > 0.001f) ? scale_bri(color_, fill) : 0;
        }
    }

   private:
    const float *pct_;
    uint32_t color_;
};

/**
 * Idle / connected: center-only breathe with a visible floor.
 * Phase is wall-clock based to avoid FreeRTOS tick jitter looking choppy.
 * brightness_mul stacks on top of the global master brightness.
 */
class CenterIdleGlow final : public pixelengine::Animation {
   public:
    explicit CenterIdleGlow(size_t led_count, uint32_t color = Color::rgb(0, 210, 90),
                            float brightness_mul = 1.0f)
        : color_(color), brightness_mul_(brightness_mul)
    {
        led_count_ = led_count;
        layout_ = Layout::Linear;
        buffer_.assign(led_count_, 0);
        center_ = (led_count_ > 0) ? static_cast<size_t>((led_count_ - 1) / 2) : 0;
        t0_ = now_sec();
    }

    void update() override
    {
        if (led_count_ == 0) {
            return;
        }
        constexpr float kPeriod = 3.2f; /* seconds per breathe cycle */
        constexpr float kTwoPi = 6.28318530718f;
        const float phase = ((now_sec() - t0_) / kPeriod) * kTwoPi;
        const float raw = 0.5f + 0.5f * std::sinf(phase - 1.57079632679f);
        const float breathe = smoother01(raw);
        /* Floor ~0.22 of peak so standby never blanks. */
        const float level = 0.22f + 0.78f * breathe;
        const float peak = 0.42f * level * brightness_mul_;

        std::fill(buffer_.begin(), buffer_.end(), 0);
        buffer_[center_] = scale_bri(color_, peak);
    }

   private:
    uint32_t color_;
    float brightness_mul_ = 1.0f;
    size_t center_ = 0;
    float t0_ = 0.0f;
};

/** Traveling soft wave — used for connected (gentle) and pump-on (punchy). */
class SoftWave final : public pixelengine::Animation {
   public:
    SoftWave(size_t led_count, uint32_t color, float wavelength, float speed_hz, float floor,
             float contrast)
        : color_(color), wavelength_(wavelength), speed_hz_(speed_hz), floor_(floor),
          contrast_(contrast)
    {
        led_count_ = led_count;
        layout_ = Layout::Linear;
        buffer_.assign(led_count_, 0);
        t0_ = now_sec();
    }

    void update() override
    {
        if (led_count_ == 0) {
            return;
        }
        constexpr float kTwoPi = 6.28318530718f;
        const float phase = (now_sec() - t0_) * speed_hz_ * kTwoPi;
        const float wl = (wavelength_ < 1.0f) ? 1.0f : wavelength_;
        for (size_t i = 0; i < led_count_; ++i) {
            const float x = (kTwoPi * static_cast<float>(i) / wl) - phase;
            /* Sharper peaks when contrast is high: raise sine to a power. */
            float s = 0.5f + 0.5f * std::sinf(x);
            if (contrast_ > 1.01f) {
                s = std::pow(s, contrast_);
            }
            const float bri = floor_ + (1.0f - floor_) * s;
            buffer_[i] = scale_bri(color_, bri * 0.55f);
        }
    }

   private:
    uint32_t color_;
    float wavelength_;
    float speed_hz_;
    float floor_;
    float contrast_;
    float t0_ = 0.0f;
};

/** Blue ping-pong comet for pairing. */
class PingPong final : public pixelengine::Animation {
   public:
    PingPong(size_t led_count, uint32_t color = Color::rgb(40, 120, 255), float period_s = 1.6f)
        : color_(color), period_s_(period_s)
    {
        led_count_ = led_count;
        layout_ = Layout::Linear;
        buffer_.assign(led_count_, 0);
        t0_ = now_sec();
        trail_ = std::max<size_t>(3, led_count_ / 3);
    }

    void update() override
    {
        if (led_count_ == 0) {
            return;
        }
        std::fill(buffer_.begin(), buffer_.end(), 0);
        const float span = static_cast<float>(led_count_ > 1 ? led_count_ - 1 : 1);
        /* Triangle wave 0→1→0 for bounce without direction flips. */
        const float u = std::fmod(now_sec() - t0_, period_s_) / period_s_;
        const float tri = (u < 0.5f) ? (u * 2.0f) : (2.0f - u * 2.0f);
        const float pos = smoother01(tri) * span;

        for (size_t i = 0; i < led_count_; ++i) {
            const float dist = std::fabs(static_cast<float>(i) - pos);
            float bri = 0.0f;
            if (dist < static_cast<float>(trail_)) {
                const float t = 1.0f - dist / static_cast<float>(trail_);
                bri = t * t;
            }
            /* Soft base so the strip never looks empty between passes. */
            bri = std::max(bri, 0.03f);
            buffer_[i] = scale_bri(color_, bri);
        }
    }

   private:
    uint32_t color_;
    float period_s_;
    float t0_ = 0.0f;
    size_t trail_ = 3;
};

/**
 * Boot: gradual fill → fade → brief green success → fade → standby.
 */
class BootLoading final : public pixelengine::Animation {
   public:
    explicit BootLoading(size_t led_count)
    {
        led_count_ = led_count;
        layout_ = Layout::Linear;
        buffer_.assign(led_count_, 0);
        is_static_ = false;
        t0_ = now_sec();
    }

    bool finished() const { return stage_ == Stage::Done; }

    void update() override
    {
        if (led_count_ == 0) {
            return;
        }
        const float now = now_sec();
        float fill = 0.0f;
        float fade = 1.0f;
        uint32_t color = Color::rgb(170, 175, 195);
        float bri_scale = 0.38f;

        switch (stage_) {
        case Stage::Fill: {
            const float t = now - t0_;
            const float u = smoother01(std::min(1.0f, t / 1.35f));
            fill = u * static_cast<float>(led_count_);
            if (t >= 1.35f) {
                stage_ = Stage::Hold;
                t0_ = now;
                fill = static_cast<float>(led_count_);
            }
            break;
        }
        case Stage::Hold:
            fill = static_cast<float>(led_count_);
            if (now - t0_ >= 0.18f) {
                stage_ = Stage::FadeOut;
                t0_ = now;
            }
            break;
        case Stage::FadeOut: {
            fill = static_cast<float>(led_count_);
            fade = 1.0f - smoother01(std::min(1.0f, (now - t0_) / 0.4f));
            if (now - t0_ >= 0.4f) {
                stage_ = Stage::Success;
                t0_ = now;
                fade = 0.0f;
            }
            break;
        }
        case Stage::Success: {
            /* Full-strip soft green pulse — boot OK. */
            color = Color::rgb(0, 220, 90);
            bri_scale = 0.55f;
            fill = static_cast<float>(led_count_);
            const float t = now - t0_;
            const float pulse = smoother01(std::min(1.0f, t / 0.18f));
            fade = (t < 0.35f) ? pulse : 1.0f;
            if (t >= 0.55f) {
                stage_ = Stage::SuccessFade;
                t0_ = now;
            }
            break;
        }
        case Stage::SuccessFade: {
            color = Color::rgb(0, 220, 90);
            bri_scale = 0.55f;
            fill = static_cast<float>(led_count_);
            fade = 1.0f - smoother01(std::min(1.0f, (now - t0_) / 0.35f));
            if (now - t0_ >= 0.35f) {
                stage_ = Stage::Done;
                fade = 0.0f;
            }
            break;
        }
        case Stage::Done:
            fill = 0.0f;
            fade = 0.0f;
            break;
        }

        for (size_t i = 0; i < led_count_; ++i) {
            float cell = fill - static_cast<float>(i);
            cell = clamp01(cell);
            buffer_[i] = scale_bri(color, cell * fade * bri_scale);
        }
    }

   private:
    enum class Stage { Fill, Hold, FadeOut, Success, SuccessFade, Done };
    float t0_ = 0.0f;
    Stage stage_ = Stage::Fill;
};

/** Unpaired: slow amber whole-strip breathe with floor. */
class SoftBreathe final : public pixelengine::Animation {
   public:
    SoftBreathe(size_t led_count, uint32_t color, float period_s, float floor)
        : color_(color), period_s_(period_s), floor_(floor)
    {
        led_count_ = led_count;
        layout_ = Layout::Linear;
        buffer_.assign(led_count_, 0);
        t0_ = now_sec();
    }

    void update() override
    {
        if (led_count_ == 0) {
            return;
        }
        constexpr float kTwoPi = 6.28318530718f;
        const float phase = ((now_sec() - t0_) / period_s_) * kTwoPi;
        const float raw = 0.5f + 0.5f * std::sinf(phase - 1.57079632679f);
        const float bri = floor_ + (1.0f - floor_) * smoother01(raw);
        const uint32_t c = scale_bri(color_, bri * 0.45f);
        for (size_t i = 0; i < led_count_; ++i) {
            buffer_[i] = c;
        }
    }

   private:
    uint32_t color_;
    float period_s_;
    float floor_;
    float t0_ = 0.0f;
};

BootLoading *s_boot = nullptr;
bool s_boot_hold = true;

void apply_mode(status_led_mode_t mode)
{
    constexpr size_t kN = CONFIG_PUMP_NEOPIXEL_COUNT;
    if (mode != STATUS_LED_BOOT) {
        s_boot = nullptr;
    }
    switch (mode) {
    case STATUS_LED_BOOT: {
        auto boot = std::make_unique<BootLoading>(kN);
        s_boot = boot.get();
        s_px.addAnimation(std::move(boot));
        break;
    }
    case STATUS_LED_UNPAIRED:
        s_px.addAnimation(std::make_unique<SoftBreathe>(kN, Color::Amber, 2.4f, 0.25f));
        break;
    case STATUS_LED_PAIRING:
        s_px.addAnimation(std::make_unique<PingPong>(kN));
        break;
    case STATUS_LED_IDLE:
        s_px.addAnimation(std::make_unique<CenterIdleGlow>(kN));
        break;
    case STATUS_LED_CONNECTED:
        /* Same standby glow, cooler color, a bit brighter. */
        s_px.addAnimation(
            std::make_unique<CenterIdleGlow>(kN, Color::rgb(0, 190, 210), 1.25f));
        break;
    case STATUS_LED_PUMP_ON:
        /* Spaced high-contrast blue wave while the pump runs. */
        s_px.addAnimation(std::make_unique<SoftWave>(kN, Color::rgb(30, 110, 255), 9.5f, 0.42f,
                                                     0.05f, 2.2f));
        break;
    case STATUS_LED_HOLD_PROGRESS:
        s_px.addAnimation(
            std::make_unique<ProgressFill>(kN, &s_hold_pct, Color::rgb(40, 120, 255)));
        break;
    case STATUS_LED_UPDATING:
        s_px.addAnimation(
            std::make_unique<ProgressFill>(kN, &s_ota_pct, Color::rgb(0, 200, 220)));
        break;
    case STATUS_LED_UPDATE_OK:
        s_px.solid(Color::scale(Color::rgb(0, 230, 70), s_bri * 0.55f));
        break;
    case STATUS_LED_UPDATE_ERR:
        s_px.solid(Color::scale(Color::rgb(230, 40, 40), s_bri * 0.55f));
        break;
    default:
        s_px.addAnimation(std::make_unique<CenterIdleGlow>(kN));
        break;
    }
}

void anim_task(void *arg)
{
    (void)arg;
    status_led_mode_t last = static_cast<status_led_mode_t>(-1);
    bool boot_started = false;
    while (true) {
        s_bri = static_cast<float>(s_brightness_pct) / 100.0f;

        if (s_boot_hold) {
            if (!boot_started) {
                apply_mode(STATUS_LED_BOOT);
                last = STATUS_LED_BOOT;
                boot_started = true;
            }
            if (s_boot && s_boot->finished()) {
                s_boot_hold = false;
                s_boot = nullptr;
                last = static_cast<status_led_mode_t>(-1);
                if (s_mode == STATUS_LED_BOOT) {
                    s_mode = STATUS_LED_IDLE;
                }
            }
        } else {
            const status_led_mode_t mode = s_mode;
            if (mode != last) {
                apply_mode(mode);
                last = mode;
            }
        }

        s_hold_pct += (static_cast<float>(s_hold_pct_target) - s_hold_pct) * 0.28f;
        s_ota_pct += (static_cast<float>(s_ota_pct_target) - s_ota_pct) * 0.22f;

        s_px.update();
        vTaskDelay(pdMS_TO_TICKS(FRAME_MS));
    }
}

}  // namespace

extern "C" esp_err_t status_led_init(void)
{
    if (!s_px.begin(CONFIG_PUMP_NEOPIXEL_COUNT, CONFIG_PUMP_NEOPIXEL_GPIO, Layout::Linear)) {
        ESP_LOGE(TAG, "PixelEngine begin failed");
        return ESP_FAIL;
    }
    s_px.setFps(1000.0f / FRAME_MS);

    if (xTaskCreate(anim_task, "status_led", 6144, nullptr, 4, nullptr) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "PixelEngine GPIO %d count=%d (linear)", CONFIG_PUMP_NEOPIXEL_GPIO,
             CONFIG_PUMP_NEOPIXEL_COUNT);
    status_led_set_mode(STATUS_LED_BOOT);
    return ESP_OK;
}

extern "C" void status_led_set_mode(status_led_mode_t mode)
{
    s_mode = mode;
    if (mode == STATUS_LED_UPDATING) {
        s_ota_pct_target = 0;
        s_ota_pct = 0.0f;
    }
}

extern "C" void status_led_set_hold_progress(uint8_t percent)
{
    s_hold_pct_target = percent > 100 ? 100 : percent;
}

extern "C" void status_led_set_update_progress(uint8_t percent)
{
    s_ota_pct_target = percent > 100 ? 100 : percent;
}

extern "C" void status_led_set_brightness(uint8_t percent)
{
    if (percent < 1) {
        percent = 1;
    }
    if (percent > 100) {
        percent = 100;
    }
    s_brightness_pct = percent;
}

extern "C" uint8_t status_led_get_brightness(void)
{
    return s_brightness_pct;
}

extern "C" status_led_mode_t status_led_get_mode(void)
{
    return s_mode;
}

#endif /* CONFIG_PUMP_ENABLE_NEOPIXEL */
