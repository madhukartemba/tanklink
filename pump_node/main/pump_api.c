#include "pump_api.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#include "buzzer.h"
#include "gatt_payloads.h"
#include "gatt_svr.h"
#include "lora_link.h"
#include "pump_clock.h"
#include "pump_config.h"
#include "pump_control.h"
#include "pump_factory.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_runlog.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "pump_wifi.h"
#include "pump_alert.h"
#include "pump_autofill.h"
#include "pump_buzz.h"
#include "pump_update.h"
#include "pump_wifi_api.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "PUMP_API"

#define WIFI_READ_STATUS 0xFF

#ifndef CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS
#define CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS 60000
#endif

_Static_assert(GATT_HISTORY_MAX_LEN <= PUMP_API_READ_MAX, "read buffer");
_Static_assert(GATT_NODES_MAX_LEN <= PUMP_API_READ_MAX, "read buffer");
_Static_assert(GATT_BATTERY_MAX_LEN <= PUMP_API_READ_MAX, "read buffer");
_Static_assert(GATT_WIFI_SCAN_MAX_LEN <= PUMP_API_READ_MAX, "read buffer");

/* BLE and TCP handlers run in different tasks; one call at a time. */
static SemaphoreHandle_t s_lock;

void pump_api_init(void)
{
    if (!s_lock) {
        s_lock = xSemaphoreCreateMutex();
        configASSERT(s_lock);
    }
}

static void lock(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
}

static void unlock(void)
{
    xSemaphoreGive(s_lock);
}

void pump_api_session_init(pump_api_session_t *s, uint16_t id)
{
    memset(s, 0, sizeof(*s));
    s->id = id;
    s->phone = -1;
    s->wifi_page = WIFI_READ_STATUS;
    esp_fill_random(s->nonce, sizeof(s->nonce));
}

void pump_api_session_sign_out(pump_api_session_t *s)
{
    s->authed = false;
    s->phone = -1;
    memset(s->auth_nonce, 0, sizeof(s->auth_nonce));
}

bool pump_api_chr_notify_needs_auth(uint8_t chr)
{
    return chr != PUMP_API_CHR_STATE && chr != PUMP_API_CHR_OTA_STATUS;
}

bool pump_api_id_authed(uint16_t id)
{
    if (id == PUMP_API_LOCAL_ID) {
        return true;
    }
    return id >= PUMP_API_TCP_ID_BASE ? pump_wifi_api_is_authed(id)
                                      : gatt_svr_is_authed_conn(id);
}

void pump_api_drop_id(uint16_t id)
{
    if (id == PUMP_API_LOCAL_ID) {
        return; /* nobody to hang up on */
    }
    if (id >= PUMP_API_TCP_ID_BASE) {
        pump_wifi_api_drop(id);
    } else {
        gatt_svr_drop(id);
    }
}

static void sign_out_everyone(void)
{
    gatt_svr_sign_out_all();
    pump_wifi_api_sign_out_all();
}

static void drop_others(const pump_api_session_t *keep)
{
    gatt_svr_drop_others(keep->id);
    pump_wifi_api_drop_others(keep->id);
}

/* ---------------------------------------------------------------------------
 * Reads
 * ------------------------------------------------------------------------- */

pump_api_err_t pump_api_read(pump_api_session_t *s, uint8_t chr, uint8_t *out, size_t *len)
{
    /* Info, Auth, State, Settings and OtaStatus are public; the rest need sign-in. */
    const bool public_read = chr == PUMP_API_CHR_INFO || chr == PUMP_API_CHR_AUTH ||
                             chr == PUMP_API_CHR_STATE || chr == PUMP_API_CHR_SETTINGS ||
                             chr == PUMP_API_CHR_OTA_STATUS;
    if (!public_read && !s->authed) {
        return PUMP_API_ERR_NOT_AUTH;
    }
    lock();
    pump_api_err_t err = PUMP_API_OK;
    switch (chr) {
    case PUMP_API_CHR_INFO:
        *len = gatt_payload_info(out, s->authed);
        break;
    case PUMP_API_CHR_AUTH:
        memcpy(out, s->nonce, sizeof(s->nonce));
        *len = sizeof(s->nonce);
        break;
    case PUMP_API_CHR_STATE:
        out[0] = pump_control_is_on() ? 1 : 0;
        *len = 1;
        break;
    case PUMP_API_CHR_SETTINGS:
        *len = gatt_payload_settings(out);
        break;
    case PUMP_API_CHR_OTA_STATUS:
        *len = gatt_payload_ota_status(out);
        break;
    case PUMP_API_CHR_TANK:
        *len = gatt_payload_tank_status(out);
        break;
    case PUMP_API_CHR_SCHED:
        *len = gatt_payload_sched(out);
        break;
    case PUMP_API_CHR_TANKS:
        *len = gatt_payload_tanks(out);
        break;
    case PUMP_API_CHR_NODES:
        *len = gatt_payload_nodes(out);
        break;
    case PUMP_API_CHR_HISTORY:
        *len = gatt_payload_history(out, s->history_start);
        break;
    case PUMP_API_CHR_BATTERY:
        *len = gatt_payload_battery(out);
        break;
    case PUMP_API_CHR_ALERT_KEY:
        pump_alert_key(out);
        *len = 16;
        break;
    case PUMP_API_CHR_ALERT_LOG:
        *len = pump_alert_log_payload(out);
        break;
    case PUMP_API_CHR_BUZZER:
        *len = pump_buzz_payload(out);
        break;
    case PUMP_API_CHR_AUTO_FILL:
        *len = pump_autofill_payload(out);
        break;
    case PUMP_API_CHR_WIFI:
        *len = s->wifi_page == WIFI_READ_STATUS ? gatt_payload_wifi_status(out)
                                                : gatt_payload_wifi_scan(out, s->wifi_page);
        break;
    default:
        err = PUMP_API_ERR_REFUSED;
        break;
    }
    unlock();
    return err;
}

/* ---------------------------------------------------------------------------
 * Writes
 * ------------------------------------------------------------------------- */

static uint32_t get_u32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
           ((uint32_t)b[3] << 24);
}

static pump_api_err_t refused_if(bool failed)
{
    return failed ? PUMP_API_ERR_REFUSED : PUMP_API_OK;
}

/** Everything the app shows about tanks, after a sensor or slot change. */
static void notify_tank_change(void)
{
    lora_link_on_active_changed();
    gatt_svr_notify_tank();
    gatt_svr_notify_tanks();
    gatt_svr_notify_nodes();
}

/** Sensor index for a sensor_id(6) in a command, or -1. */
static int node_from_id(const uint8_t *body, size_t len, size_t at)
{
    if (len < at + TANKLINK_DEVICE_ID_LEN) {
        return -1;
    }
    return pump_tanks_node_find(&body[at]);
}

/** Runs one Cmd opcode. [body] is the whole write, [len] at least 1. */
static pump_api_err_t run_command(pump_api_session_t *s, const uint8_t *body, size_t len)
{
    status_led_notify_activity();
    switch (body[0]) {
    case TANKLINK_CMD_OFF:
    case TANKLINK_CMD_ON:
        pump_control_set(body[0] == TANKLINK_CMD_ON, PUMP_CAUSE_APP);
        return PUMP_API_OK;

    case TANKLINK_CMD_RENAME_PUMP:
        if (pump_config_set_name(&body[1], len - 1) != ESP_OK) {
            return PUMP_API_ERR_REFUSED; /* empty, too long, not UTF-8 or has control characters */
        }
        gatt_svr_notify_settings();
        return PUMP_API_OK;

    case TANKLINK_CMD_TEST_ALERT:
        pump_alert_raise(TL_ALERT_TEST, 0xFF);
        return PUMP_API_OK;

    case TANKLINK_CMD_UPDATE_CHECK:
        return refused_if(pump_update_request_check() != ESP_OK);

    case TANKLINK_CMD_UPDATE_INSTALL:
        return refused_if(pump_update_request_install() != ESP_OK);

    case TANKLINK_CMD_UPDATE_DISMISS:
        pump_update_dismiss_overnight();
        gatt_svr_notify_wifi();
        return PUMP_API_OK;

    case TANKLINK_CMD_UNPAIR:
        if (pump_update_in_progress()) {
            return PUMP_API_ERR_REFUSED; /* not in the middle of an update */
        }
        if (pump_pair_unpair() != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        sign_out_everyone();
        pump_control_set(false, PUMP_CAUSE_SYSTEM);
        return PUMP_API_OK;

    case TANKLINK_CMD_PAIRING_OPEN:
        /* The window switches the pump off; don't stop a fill from afar. */
        if (pump_control_is_on() || pump_update_in_progress()) {
            return PUMP_API_ERR_REFUSED;
        }
        return refused_if(pump_pair_enter_pairing_mode() != ESP_OK);

    case TANKLINK_CMD_PAIRING_CLOSE:
        pump_pair_exit_pairing_mode();
        return PUMP_API_OK;

    case TANKLINK_CMD_FORGET_OTHER_PHONES:
        if (pump_pair_forget_others(s->phone) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        drop_others(s);
        return PUMP_API_OK;

    case TANKLINK_CMD_TEST_BEEP:
        /* The sound to play: the app's preview, whatever the settings. */
        if (len < 2) {
            return PUMP_API_ERR_LEN;
        }
        if (body[1] >= BUZZER_SOUND_COUNT) {
            return PUMP_API_ERR_REFUSED;
        }
        pump_buzz_test((buzzer_sound_t)body[1]);
        return PUMP_API_OK;

    case TANKLINK_CMD_TANK_PAIR_STOP:
        lora_link_stop_tank_pair();
        return PUMP_API_OK;

    case TANKLINK_CMD_TANK_PAIR:
        return refused_if(lora_link_start_tank_pair(CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS) !=
                          ESP_OK);

    case TANKLINK_CMD_TANK_UNPAIR: {
        /* Refused while the pump fills one of that sensor's tanks. */
        const int node = node_from_id(body, len, 1);
        if (node < 0) {
            return PUMP_API_ERR_LEN;
        }
        return refused_if(lora_link_unpair_node((uint8_t)node) != ESP_OK);
    }

    case TANKLINK_CMD_SENSOR_MODE: {
        const int node = node_from_id(body, len, 1);
        if (node < 0 || len < 1 + TANKLINK_DEVICE_ID_LEN + 1) {
            return PUMP_API_ERR_LEN;
        }
        if (pump_tanks_set_node_mode((uint8_t)node, body[1 + TANKLINK_DEVICE_ID_LEN],
                                     pump_control_is_on()) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        notify_tank_change();
        gatt_svr_notify_sched();
        return PUMP_API_OK;
    }

    case TANKLINK_CMD_FACTORY_RESET:
        if (pump_update_in_progress()) {
            return PUMP_API_ERR_REFUSED;
        }
        return refused_if(pump_factory_reset() != ESP_OK);

    case TANKLINK_CMD_CLEAR_ERROR:
        pump_control_clear_error();
        return PUMP_API_OK;

    case TANKLINK_CMD_DISMISS_INTERRUPT:
        pump_runlog_clear_event();
        gatt_svr_notify_tank();
        return PUMP_API_OK;

    case TANKLINK_CMD_TANK_SELECT:
        if (len < 2) {
            return PUMP_API_ERR_LEN;
        }
        if (pump_tanks_select(body[1], pump_control_is_on()) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        notify_tank_change();
        return PUMP_API_OK;

    case TANKLINK_CMD_TANK_RENAME:
        if (len < 3) {
            return PUMP_API_ERR_LEN;
        }
        if (pump_tanks_rename(body[1], &body[2], len - 2) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        gatt_svr_notify_tanks();
        return PUMP_API_OK;

    case TANKLINK_CMD_TANK_AUTO_FILL:
        if (len < 3) {
            return PUMP_API_ERR_LEN;
        }
        if (pump_tanks_set_auto_fill(body[1], body[2] != 0) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        /* Turned on by hand: fill if it is low now, not only on the next drop. */
        if (body[2] != 0) {
            pump_autofill_arm();
        }
        gatt_svr_notify_tanks();
        return PUMP_API_OK;

    case TANKLINK_CMD_USAGE: {
        if (len < 1 + TANKLINK_USAGE_LEN) {
            return PUMP_API_ERR_LEN;
        }
        pump_usage_t u;
        memset(&u, 0, sizeof(u));
        u.flow_dlpm = (uint16_t)(body[1] | (body[2] << 8));
        u.watts = (uint16_t)(body[3] | (body[4] << 8));
        u.price_centi = (uint16_t)(body[5] | (body[6] << 8));
        memcpy(u.currency, &body[7], PUMP_USAGE_CURRENCY_LEN);
        if (pump_config_set_usage(&u) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        gatt_svr_notify_settings();
        return PUMP_API_OK;
    }

    case TANKLINK_CMD_TANK_AUTO_OFF:
        if (len < 3) {
            return PUMP_API_ERR_LEN;
        }
        if (pump_tanks_set_auto_off(body[1], body[2]) != ESP_OK) {
            return PUMP_API_ERR_REFUSED;
        }
        gatt_svr_notify_tanks();
        return PUMP_API_OK;

    default:
        ESP_LOGW(TAG, "Unknown command 0x%02x", body[0]);
        return PUMP_API_ERR_REFUSED;
    }
}

static pump_api_err_t write_settings(const uint8_t *buf, size_t len)
{
    /* led starter pulse_ms(u16) auto_update */
    if (len != TANKLINK_SETTINGS_WRITE_LEN) {
        return PUMP_API_ERR_LEN;
    }
    const pump_settings_t set = {
        .led_brightness = buf[0],
        .starter_type = buf[1],
        .relay_pulse_ms = (uint16_t)(buf[2] | (buf[3] << 8)),
        .auto_update = buf[4] != 0,
    };
    /* A new starter type stops the motor with the old profile first: never
     * mid-fill, or the pump would think it still runs. */
    if (set.starter_type != pump_config_starter_type() && pump_control_is_on()) {
        return PUMP_API_ERR_REFUSED;
    }
    if (pump_config_set_settings(&set) != ESP_OK) {
        return PUMP_API_ERR_REFUSED;
    }
    gatt_svr_notify_settings();
    return PUMP_API_OK;
}

/** Set-clock write: year(u16) month day hour minute second [utc_offset(i16)]. */
static pump_api_err_t set_clock(const uint8_t *buf, size_t len)
{
    if (len < TANKLINK_SCHED_CLOCK_LEN) {
        return PUMP_API_ERR_LEN;
    }
    if (len >= TANKLINK_SCHED_CLOCK_UTC_OFF_AT + 2) {
        pump_clock_set_utc_offset(
            (int16_t)((uint16_t)buf[TANKLINK_SCHED_CLOCK_UTC_OFF_AT] |
                      ((uint16_t)buf[TANKLINK_SCHED_CLOCK_UTC_OFF_AT + 1] << 8)));
    }
    const int year = (int)buf[1] | ((int)buf[2] << 8);
    int64_t before = 0;
    const bool had_time = pump_clock_unix_now(&before);
    if (pump_clock_set(year, buf[3], buf[4], buf[5], buf[6], buf[7]) != ESP_OK) {
        return PUMP_API_ERR_REFUSED;
    }
    /* The app re-syncs every 15 min. Keep "already started today" marks
     * across small corrections, or a sync inside a schedule's minute would
     * start the pump again. Clear them on a real jump. */
    int64_t after = 0;
    (void)pump_clock_unix_now(&after);
    const int64_t delta = after - before;
    if (!had_time || delta > 300 || delta < -300) {
        pump_sched_clear_fired();
    }
    ESP_LOGI(TAG, "clock set %04d-%02u-%02u %02u:%02u:%02u", year, buf[3], buf[4], buf[5],
             buf[6], buf[7]);
    return PUMP_API_OK;
}

/** Replace-list write: count, then count x (enabled hour minute slot). */
static pump_api_err_t set_schedules(const uint8_t *buf, size_t len)
{
    if (len < 2) {
        return PUMP_API_ERR_LEN;
    }
    const unsigned count = buf[1];
    if (count > PUMP_SCHED_MAX || len < 2 + count * 4) {
        return PUMP_API_ERR_LEN;
    }
    pump_sched_entry_t entries[PUMP_SCHED_MAX];
    memset(entries, 0, sizeof(entries));
    const uint8_t *e = &buf[2];
    for (unsigned i = 0; i < count; i++, e += 4) {
        entries[i].enabled = e[0] ? 1 : 0;
        entries[i].hour = e[1];
        entries[i].minute = e[2];
        entries[i].slot = e[3];
    }
    return refused_if(pump_sched_set(entries, count) != ESP_OK);
}

static pump_api_err_t write_sched(const uint8_t *buf, size_t len)
{
    pump_api_err_t err;
    switch (buf[0]) {
    case TANKLINK_SCHED_OP_SET_CLOCK:
        err = set_clock(buf, len);
        break;
    case TANKLINK_SCHED_OP_SET_LIST:
        err = set_schedules(buf, len);
        break;
    default:
        return PUMP_API_ERR_REFUSED;
    }
    if (err == PUMP_API_OK) {
        gatt_svr_notify_sched();
    }
    return err;
}

/**
 * Wifi SET. The password is XOR'd with a keystream made from this phone's
 * token and the nonce it signed in with, so it never crosses an unencrypted
 * link in the clear (BLE) or at all in the open (TCP).
 */
static pump_api_err_t wifi_set(const pump_api_session_t *s, const uint8_t *buf, size_t len)
{
    if (len < 3) {
        return PUMP_API_ERR_LEN;
    }
    const unsigned ssid_len = buf[1];
    if (ssid_len == 0 || ssid_len > PUMP_WIFI_SSID_MAX || len < 2 + ssid_len + 1) {
        return PUMP_API_ERR_LEN;
    }
    const unsigned pass_len = buf[2 + ssid_len];
    if (pass_len > PUMP_WIFI_PASS_MAX || len < 3 + ssid_len + pass_len) {
        return PUMP_API_ERR_LEN;
    }
    char ssid[PUMP_WIFI_SSID_MAX + 1];
    char pass[PUMP_WIFI_PASS_MAX + 1];
    memcpy(ssid, &buf[2], ssid_len);
    ssid[ssid_len] = '\0';
    if (pass_len > 0) {
        uint8_t token[TANKLINK_TOKEN_LEN];
        if (!tl_nonzero(s->auth_nonce, sizeof(s->auth_nonce)) ||
            !pump_pair_phone_token(s->phone, token)) {
            return PUMP_API_ERR_NOT_AUTH; /* sign in again first */
        }
        uint8_t ks[TANKLINK_WIFI_KEYSTREAM_LEN];
        for (uint8_t block = 0; block < 2; block++) {
            const uint8_t tail[5] = {'w', 'i', 'f', 'i', block};
            tl_hmac_sha256(token, sizeof(token), s->auth_nonce, sizeof(s->auth_nonce), tail,
                           sizeof(tail), &ks[block * 32]);
        }
        memset(token, 0, sizeof(token));
        for (unsigned i = 0; i < pass_len; i++) {
            pass[i] = (char)(buf[3 + ssid_len + i] ^ ks[i]);
        }
        memset(ks, 0, sizeof(ks));
    }
    pass[pass_len] = '\0';
    const esp_err_t err = pump_wifi_set(ssid, pass);
    memset(pass, 0, sizeof(pass));
    ESP_LOGI(TAG, "wifi set \"%s\": %s", ssid, esp_err_to_name(err));
    return refused_if(err != ESP_OK);
}

static pump_api_err_t write_wifi(pump_api_session_t *s, const uint8_t *buf, size_t len)
{
    status_led_notify_activity();
    switch (buf[0]) {
    case TANKLINK_WIFI_OP_SET:
        s->wifi_page = WIFI_READ_STATUS;
        return wifi_set(s, buf, len);
    case TANKLINK_WIFI_OP_FORGET:
        s->wifi_page = WIFI_READ_STATUS;
        return refused_if(pump_wifi_forget() != ESP_OK);
    case TANKLINK_WIFI_OP_SCAN:
        s->wifi_page = WIFI_READ_STATUS;
        return refused_if(pump_wifi_scan_start() != ESP_OK);
    case TANKLINK_WIFI_OP_SCAN_PAGE:
        if (len < 2) {
            return PUMP_API_ERR_LEN;
        }
        s->wifi_page = buf[1] == WIFI_READ_STATUS ? 0 : buf[1];
        return PUMP_API_OK;
    case TANKLINK_WIFI_OP_STATUS:
        s->wifi_page = WIFI_READ_STATUS;
        return PUMP_API_OK;
    default:
        return PUMP_API_ERR_REFUSED;
    }
}

static pump_api_err_t write_ota_ctrl(pump_api_session_t *s, const uint8_t *buf, size_t len)
{
    /* Frozen layout: start(size, sha256) / abort / finish. */
    uint8_t err;
    switch (buf[0]) {
    case TANKLINK_OTA_OP_START:
        if (len != 1 + 4 + 32) {
            return PUMP_API_ERR_LEN;
        }
        err = pump_ota_start(s->id, get_u32(&buf[1]), &buf[5]);
        break;
    case TANKLINK_OTA_OP_ABORT:
        err = pump_ota_abort_from(s->id);
        break;
    case TANKLINK_OTA_OP_FINISH:
        err = pump_ota_finish(s->id);
        break;
    default:
        return PUMP_API_ERR_REFUSED;
    }
    gatt_svr_notify_ota_status();
    return refused_if(err != TANKLINK_OTA_ERR_OK);
}

pump_api_err_t pump_api_write(pump_api_session_t *s, uint8_t chr, const uint8_t *data,
                              size_t len)
{
    /* Public writes: Auth (that is how a phone signs in) and the OTA
     * characteristics (pump_ota checks the session itself). */
    const bool public_write = chr == PUMP_API_CHR_AUTH || chr == PUMP_API_CHR_OTA_CTRL ||
                              chr == PUMP_API_CHR_OTA_DATA;
    if (!public_write && !s->authed) {
        return PUMP_API_ERR_NOT_AUTH;
    }

    lock();
    pump_api_err_t err;
    switch (chr) {
    case PUMP_API_CHR_AUTH: {
        /* HMAC-SHA256(token, "TLauth" || nonce), first 16 bytes. The nonce
         * changes after every try, so a recorded answer is useless. */
        if (len != TL_AUTH_RESP_LEN) {
            err = PUMP_API_ERR_LEN;
            break;
        }
        const int phone = pump_pair_check_response(s->nonce, data);
        if (phone >= 0) {
            memcpy(s->auth_nonce, s->nonce, sizeof(s->auth_nonce));
        }
        esp_fill_random(s->nonce, sizeof(s->nonce));
        s->authed = phone >= 0;
        s->phone = (int8_t)phone;
        ESP_LOGI(TAG, "Auth %s id=%u phone=%d", phone >= 0 ? "OK" : "FAILED", s->id, phone);
        if (phone >= 0) {
            pump_buzz(PUMP_BUZZ_PHONE);
        }
        err = phone >= 0 ? PUMP_API_OK : PUMP_API_ERR_NOT_AUTH;
        break;
    }
    case PUMP_API_CHR_CMD:
        /* Longest command: renaming the pump = opcode + name (24). */
        err = len < 1 || len > 1 + PUMP_NAME_MAX ? PUMP_API_ERR_LEN
                                                          : run_command(s, data, len);
        break;
    case PUMP_API_CHR_SETTINGS:
        err = write_settings(data, len);
        break;
    case PUMP_API_CHR_BUZZER:
        if (len != PUMP_BUZZ_PAYLOAD_LEN) {
            err = PUMP_API_ERR_LEN;
        } else if (pump_buzz_write(data, len) != ESP_OK) {
            err = PUMP_API_ERR_REFUSED;
        } else {
            gatt_svr_notify_buzzer();
            err = PUMP_API_OK;
        }
        break;
    case PUMP_API_CHR_AUTO_FILL: {
        const esp_err_t e = pump_autofill_write(data, len);
        err = e == ESP_ERR_INVALID_SIZE ? PUMP_API_ERR_LEN
              : e != ESP_OK             ? PUMP_API_ERR_REFUSED
                                        : PUMP_API_OK;
        if (err == PUMP_API_OK) {
            gatt_svr_notify_autofill();
        }
        break;
    }
    case PUMP_API_CHR_SCHED:
        err = len < 1 || len > 2 + PUMP_SCHED_MAX * 4 + 4 ? PUMP_API_ERR_LEN
                                                         : write_sched(data, len);
        break;
    case PUMP_API_CHR_HISTORY:
        if (len != 1) {
            err = PUMP_API_ERR_LEN;
        } else {
            s->history_start = data[0];
            err = PUMP_API_OK;
        }
        break;
    case PUMP_API_CHR_WIFI:
        err = len < 1 || len > 2 + PUMP_WIFI_SSID_MAX + 1 + PUMP_WIFI_PASS_MAX
                  ? PUMP_API_ERR_LEN
                  : write_wifi(s, data, len);
        break;
    case PUMP_API_CHR_OTA_CTRL:
        err = len < 1 || len > 1 + 4 + 32 ? PUMP_API_ERR_LEN : write_ota_ctrl(s, data, len);
        break;
    case PUMP_API_CHR_OTA_DATA:
        /* offset(u32) + payload. Frozen layout. */
        if (len < 5 || len > PUMP_API_WRITE_MAX) {
            err = PUMP_API_ERR_LEN;
        } else {
            err = refused_if(pump_ota_write(s->id, get_u32(data), &data[4],
                                            (uint16_t)(len - 4)) != TANKLINK_OTA_ERR_OK);
        }
        break;
    default:
        err = PUMP_API_ERR_REFUSED;
        break;
    }
    unlock();
    return err;
}
