#include "pump_buzz.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "nvs.h"
#include "pump_clock.h"
#include "pump_window.h"

#define TAG "PUMP_BUZZ"
#define NVS_NS "tl_buzz"
#define NVS_KEY "cfg"
#define BUZZ_MAGIC 0x425A5A31u /* 'BZZ1' */

#define EVT_BIT(e) (1u << (e))
#define DEFAULT_EVENTS                                                                     \
    (EVT_BIT(PUMP_BUZZ_BUTTON) | EVT_BIT(PUMP_BUZZ_PUMP_START) | EVT_BIT(PUMP_BUZZ_PUMP_STOP) |       \
     EVT_BIT(PUMP_BUZZ_TANK_FULL) | EVT_BIT(PUMP_BUZZ_AUTO_OFF) | EVT_BIT(PUMP_BUZZ_AUTO_FILL) |      \
     EVT_BIT(PUMP_BUZZ_SCHEDULE) | EVT_BIT(PUMP_BUZZ_DENIED) | EVT_BIT(PUMP_BUZZ_ALERT) |              \
     EVT_BIT(PUMP_BUZZ_PAIRING) | EVT_BIT(PUMP_BUZZ_POWER_UP))
#define ALL_EVENTS ((1u << PUMP_BUZZ_EVENT_COUNT) - 1u)

typedef struct {
    uint32_t magic;
    uint8_t flags;
    uint8_t quiet_sh, quiet_sm, quiet_eh, quiet_em;
    uint8_t reserved;
    uint16_t events;
    uint8_t sounds[PUMP_BUZZ_EVENT_COUNT];
} buzz_cfg_t;

static buzz_cfg_t s_cfg;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

static const uint8_t kDefaultSounds[PUMP_BUZZ_EVENT_COUNT] = {
    [PUMP_BUZZ_BUTTON] = BUZZER_SOUND_CLICK,
    [PUMP_BUZZ_PUMP_START] = BUZZER_SOUND_LONG,
    [PUMP_BUZZ_PUMP_STOP] = BUZZER_SOUND_CLICK,
    [PUMP_BUZZ_TANK_FULL] = BUZZER_SOUND_RISING,
    [PUMP_BUZZ_AUTO_OFF] = BUZZER_SOUND_DOUBLE,
    [PUMP_BUZZ_AUTO_FILL] = BUZZER_SOUND_TRIPLE,
    [PUMP_BUZZ_SCHEDULE] = BUZZER_SOUND_LONG,
    [PUMP_BUZZ_DENIED] = BUZZER_SOUND_DOUBLE,
    [PUMP_BUZZ_ALERT] = BUZZER_SOUND_ALARM,
    [PUMP_BUZZ_PAIRING] = BUZZER_SOUND_CHIRP,
    [PUMP_BUZZ_PHONE] = BUZZER_SOUND_TICK,
    [PUMP_BUZZ_POWER_UP] = BUZZER_SOUND_CLICK,
};

static void load_defaults(buzz_cfg_t *c)
{
    memset(c, 0, sizeof(*c));
    c->magic = BUZZ_MAGIC;
    c->flags = PUMP_BUZZ_F_ENABLED | PUMP_BUZZ_F_QUIET_BUTTON;
    c->quiet_sh = 22; /* quiet hours off, but ready at 22:00-07:00 */
    c->quiet_eh = 7;
    c->events = DEFAULT_EVENTS;
    memcpy(c->sounds, kDefaultSounds, sizeof(c->sounds));
}

static bool cfg_valid(const buzz_cfg_t *c)
{
    if ((c->flags & ~(PUMP_BUZZ_F_ENABLED | PUMP_BUZZ_F_QUIET | PUMP_BUZZ_F_QUIET_BUTTON)) ||
        (c->events & ~ALL_EVENTS) ||
        !pump_window_valid(PUMP_WINDOW_ALL_DAYS, c->quiet_sh, c->quiet_sm, c->quiet_eh,
                           c->quiet_em)) {
        return false;
    }
    for (int i = 0; i < PUMP_BUZZ_EVENT_COUNT; i++) {
        if (c->sounds[i] >= BUZZER_SOUND_COUNT) {
            return false;
        }
    }
    return true;
}

static esp_err_t save(const buzz_cfg_t *c)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY, c, sizeof(*c));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

esp_err_t pump_buzz_init(void)
{
    load_defaults(&s_cfg);
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READONLY, &h);
    if (err == ESP_OK) {
        buzz_cfg_t c;
        size_t len = sizeof(c);
        err = nvs_get_blob(h, NVS_KEY, &c, &len);
        nvs_close(h);
        if (err == ESP_OK && (len != sizeof(c) || c.magic != BUZZ_MAGIC || !cfg_valid(&c))) {
            err = ESP_ERR_NVS_INVALID_LENGTH;
        }
        if (err == ESP_OK) {
            s_cfg = c;
        }
    }
    if (err == ESP_ERR_NVS_NOT_FOUND || err == ESP_ERR_NVS_INVALID_LENGTH) {
        ESP_LOGW(TAG, "no valid buzzer settings saved; using defaults");
        load_defaults(&s_cfg);
        err = save(&s_cfg);
    } else if (err != ESP_OK) {
        ESP_LOGE(TAG, "buzzer settings read failed: %s", esp_err_to_name(err));
        load_defaults(&s_cfg);
    }
    ESP_LOGI(TAG, "flags=0x%02x events=0x%03x", s_cfg.flags, s_cfg.events);
    return err;
}

static buzz_cfg_t snapshot(void)
{
    portENTER_CRITICAL(&s_mux);
    const buzz_cfg_t c = s_cfg;
    portEXIT_CRITICAL(&s_mux);
    return c;
}

/* Without a known time quiet hours can't be judged, so the sound plays. */
static bool in_quiet_hours(const buzz_cfg_t *c)
{
    if (!(c->flags & PUMP_BUZZ_F_QUIET)) {
        return false;
    }
    pump_civil_time_t now;
    if (!pump_clock_now(&now)) {
        return false;
    }
    const pump_window_t w = {
        .days = PUMP_WINDOW_ALL_DAYS,
        .start = (uint16_t)(c->quiet_sh * 60 + c->quiet_sm),
        .end = (uint16_t)(c->quiet_eh * 60 + c->quiet_em),
    };
    return pump_window_open(&w, &now);
}

void pump_buzz(pump_buzz_event_t event)
{
    if (event >= PUMP_BUZZ_EVENT_COUNT) {
        return;
    }
    const buzz_cfg_t c = snapshot();
    if (!(c.flags & PUMP_BUZZ_F_ENABLED) || !(c.events & EVT_BIT(event))) {
        return;
    }
    /* Someone at the pump hears the button; everything else waits for morning. */
    const bool by_hand = event == PUMP_BUZZ_BUTTON || event == PUMP_BUZZ_DENIED;
    if (in_quiet_hours(&c) && !(by_hand && (c.flags & PUMP_BUZZ_F_QUIET_BUTTON))) {
        return;
    }
    buzzer_play((buzzer_sound_t)c.sounds[event]);
}

void pump_buzz_test(buzzer_sound_t sound)
{
    buzzer_play(sound);
}

size_t pump_buzz_payload(uint8_t out[PUMP_BUZZ_PAYLOAD_LEN])
{
    const buzz_cfg_t c = snapshot();
    out[0] = c.flags;
    out[1] = (uint8_t)(c.events & 0xFF);
    out[2] = (uint8_t)(c.events >> 8);
    memcpy(&out[3], c.sounds, PUMP_BUZZ_EVENT_COUNT);
    uint8_t *q = &out[3 + PUMP_BUZZ_EVENT_COUNT];
    q[0] = c.quiet_sh;
    q[1] = c.quiet_sm;
    q[2] = c.quiet_eh;
    q[3] = c.quiet_em;
    return PUMP_BUZZ_PAYLOAD_LEN;
}

esp_err_t pump_buzz_write(const uint8_t *d, size_t len)
{
    if (len != PUMP_BUZZ_PAYLOAD_LEN) {
        return ESP_ERR_INVALID_SIZE;
    }
    buzz_cfg_t c = snapshot();
    c.flags = d[0];
    c.events = (uint16_t)(d[1] | (d[2] << 8));
    memcpy(c.sounds, &d[3], PUMP_BUZZ_EVENT_COUNT);
    const uint8_t *q = &d[3 + PUMP_BUZZ_EVENT_COUNT];
    c.quiet_sh = q[0];
    c.quiet_sm = q[1];
    c.quiet_eh = q[2];
    c.quiet_em = q[3];
    if (!cfg_valid(&c)) {
        return ESP_ERR_INVALID_ARG;
    }
    const esp_err_t err = save(&c);
    if (err != ESP_OK) {
        return err;
    }
    portENTER_CRITICAL(&s_mux);
    s_cfg = c;
    portEXIT_CRITICAL(&s_mux);
    ESP_LOGI(TAG, "saved flags=0x%02x events=0x%03x", c.flags, c.events);
    return ESP_OK;
}
