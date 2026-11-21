#include "gatt_payloads.h"

#include <string.h>

#include "esp_random.h"

#include "lora_link.h"
#include "pump_clock.h"
#include "pump_config.h"
#include "pump_control.h"
#include "pump_ota.h"
#include "pump_update.h"
#include "pump_pair.h"
#include "pump_runlog.h"

_Static_assert(TANKLINK_TANKS_ENTRY_LEN == 4 + PUMP_TANK_NAME_LEN, "Tanks entry layout");
_Static_assert(TANKLINK_NODES_ENTRY_LEN == 19 + TANKLINK_TOKEN_LEN, "Sensors entry layout");

static void put_u16(uint8_t *out, uint16_t v)
{
    out[0] = (uint8_t)(v & 0xff);
    out[1] = (uint8_t)(v >> 8);
}

static void put_u32(uint8_t *out, uint32_t v)
{
    out[0] = (uint8_t)(v & 0xff);
    out[1] = (uint8_t)((v >> 8) & 0xff);
    out[2] = (uint8_t)((v >> 16) & 0xff);
    out[3] = (uint8_t)((v >> 24) & 0xff);
}

static int8_t clamp_i8(int16_t v)
{
    return (int8_t)(v < -128 ? -128 : (v > 127 ? 127 : v));
}

size_t gatt_payload_info(uint8_t out[TANKLINK_INFO_LEN], bool authed)
{
    /* proto_major proto_minor hw_rev paired flags device_id(6)
     * fw_major fw_minor fw_patch run_secs(u32). Frozen across protocol
     * majors; new fields go after it (see tanklink_uuid.h). */
    uint8_t flags = 0;
    if (pump_pair_pairing_active()) {
        flags |= 0x01;
    }
    if (authed) {
        flags |= 0x02;
    }
    out[0] = TANKLINK_PROTO_MAJOR;
    out[1] = TANKLINK_PROTO_MINOR;
    out[2] = TANKLINK_HW_REV;
    out[3] = pump_pair_is_paired() ? 1 : 0;
    out[4] = flags;
    memcpy(&out[5], pump_pair_device_id(), TANKLINK_DEVICE_ID_LEN);
    out[11] = TANKLINK_FW_MAJOR;
    out[12] = TANKLINK_FW_MINOR;
    out[13] = TANKLINK_FW_PATCH;
    put_u32(&out[14], pump_control_run_seconds());
    return TANKLINK_INFO_LEN;
}

size_t gatt_payload_settings(uint8_t out[GATT_SETTINGS_READ_LEN])
{
    /* run(4) serial(5) buzzer_flags tone led starter pulse_ms(2), then usage:
     * flow_dlpm(2) watts(2) price_centi(2) currency(4) */
    put_u32(&out[0], pump_control_run_seconds());
    memcpy(&out[4], pump_pair_serial(), TANKLINK_SERIAL_LEN + 1);
    out[9] = pump_config_buzzer_flags();
    out[10] = pump_config_buzzer_tone();
    out[11] = pump_config_led_brightness();
    out[12] = pump_config_starter_type();
    put_u16(&out[13], pump_config_relay_pulse_ms());
    const pump_usage_t *u = pump_config_usage();
    put_u16(&out[15], u->flow_dlpm);
    put_u16(&out[17], u->watts);
    put_u16(&out[19], u->price_centi);
    memcpy(&out[21], u->currency, PUMP_USAGE_CURRENCY_LEN);
    out[25] = pump_config_auto_update() ? 1 : 0;
    memset(&out[26], 0, PUMP_NAME_MAX);
    strncpy((char *)&out[26], pump_config_name(), PUMP_NAME_MAX);
    return GATT_SETTINGS_READ_LEN;
}

/** Random, picked once per boot: lets the app tell that the pump restarted. */
static uint32_t boot_id(void)
{
    static uint32_t id;
    while (id == 0) {
        id = esp_random();
    }
    return id;
}

size_t gatt_payload_tank_status(uint8_t out[TANKLINK_TANK_STATUS_LEN])
{
    memset(out, 0, TANKLINK_TANK_STATUS_LEN);
    out[0] = lora_link_tank_bound() ? 1 : 0;
    out[1] = lora_link_tank_pairing_active() ? 1 : 0;
    memcpy(&out[2], lora_link_tank_id(), TANKLINK_DEVICE_ID_LEN);
    out[8] = lora_link_tank_fw_major();
    out[9] = lora_link_tank_fw_minor();
    out[10] = lora_link_tank_fw_patch();
    out[11] = lora_link_tank_flags();
    out[12] = lora_link_tank_battery_pct();
    out[13] = lora_link_tank_online() ? 1 : 0;
    put_u16(&out[14], lora_link_tank_age_sec());
    out[16] = (uint8_t)clamp_i8(lora_link_tank_rssi_dbm());
    out[17] = (uint8_t)lora_link_tank_snr_db();
    out[18] = pump_control_last_error();
    if (lora_link_tank_has_ble_token()) {
        memcpy(&out[19], lora_link_tank_ble_token(), TANKLINK_TOKEN_LEN);
    }
    const pump_runlog_event_t *ev = pump_runlog_event();
    if (ev) {
        uint8_t *o = &out[TANKLINK_TANK_STATUS_TOKEN_LEN];
        o[0] = ev->reason;
        put_u32(&o[1], ev->started_local);
        put_u32(&o[5], ev->last_seen_local);
        put_u32(&o[9], ev->back_local);
        put_u32(&o[13], ev->ran_sec);
    }
    out[TANKLINK_TANK_STATUS_HW_AT] = lora_link_tank_hw_rev();
    out[TANKLINK_TANK_STATUS_FAULT_AT] = lora_link_tank_fault();
    out[TANKLINK_TANK_STATUS_PUMP_FLAGS_AT] =
        pump_clock_lost_power_since_boot() ? TANKLINK_TANK_STATUS_CLOCK_LOST : 0;
    put_u32(&out[TANKLINK_TANK_STATUS_BOOT_ID_AT], boot_id());
    return TANKLINK_TANK_STATUS_LEN;
}

size_t gatt_payload_sched(uint8_t out[GATT_SCHED_MAX_LEN])
{
    /* clock_valid hour minute count, count × (enabled hour minute slot), then
     * clock_flags: bit 0 = RTC present, bit 1 = RTC holds a trusted time. */
    pump_civil_time_t now;
    const bool valid = pump_clock_now(&now);
    const unsigned count = pump_sched_count();
    out[0] = valid ? 1 : 0;
    out[1] = valid ? (uint8_t)now.hour : 0;
    out[2] = valid ? (uint8_t)now.minute : 0;
    out[3] = (uint8_t)count;
    const pump_sched_entry_t *entries = pump_sched_entries();
    uint8_t *o = &out[4];
    for (unsigned i = 0; i < count; i++, o += 4) {
        o[0] = entries[i].enabled ? 1 : 0;
        o[1] = entries[i].hour;
        o[2] = entries[i].minute;
        o[3] = entries[i].slot;
    }
    uint8_t clock_flags = 0;
    if (pump_clock_rtc_present()) {
        clock_flags |= 0x01;
    }
    if (pump_clock_rtc_ok()) {
        clock_flags |= 0x02;
    }
    *o = clock_flags;
    return 4 + count * 4 + 1;
}

size_t gatt_payload_tanks(uint8_t out[GATT_TANKS_MAX_LEN])
{
    /* active_slot count, count × (index sensor_pin sensor_index auto_off name[16]) */
    out[0] = pump_tanks_active();
    size_t o = 2;
    uint8_t written = 0;
    for (unsigned i = 0; i < pump_tanks_count() && i < PUMP_TANK_SLOT_MAX; i++) {
        uint8_t index = 0;
        pump_tank_slot_t slot;
        if (!pump_tanks_slot_at(i, &index, &slot)) {
            break;
        }
        out[o++] = index;
        out[o++] = slot.sensor;
        out[o++] = slot.node;
        out[o++] = slot.auto_off_min;
        memcpy(&out[o], slot.name, PUMP_TANK_NAME_LEN);
        o += PUMP_TANK_NAME_LEN;
        written++;
    }
    out[1] = written;
    out[o++] = pump_tanks_auto_fill_mask();
    return o;
}

size_t gatt_payload_nodes(uint8_t out[GATT_NODES_MAX_LEN])
{
    out[1] = PUMP_NODE_MAX;
    size_t o = 2;
    uint8_t count = 0;
    uint8_t faults[PUMP_NODE_MAX];
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        pump_tank_node_t node;
        lora_node_status_t st;
        if (!pump_tanks_node_get(n, &node) || !lora_link_node_status(n, &st)) {
            continue;
        }
        uint8_t *e = &out[o];
        e[0] = n;
        memcpy(&e[1], node.mac, 6);
        e[7] = node.mode;
        e[8] = st.raw_flags;
        e[9] = st.battery_pct;
        e[10] = st.online ? 1 : 0;
        put_u16(&e[11], st.age_sec);
        e[13] = (uint8_t)clamp_i8(st.rssi_dbm);
        e[14] = (uint8_t)st.snr_db;
        memcpy(&e[15], st.fw, 3);
        e[18] = st.hw_rev;
        if (st.has_ble_token) {
            memcpy(&e[19], st.ble_token, TANKLINK_TOKEN_LEN);
        } else {
            memset(&e[19], 0, TANKLINK_TOKEN_LEN);
        }
        faults[count] = st.fault;
        o += TANKLINK_NODES_ENTRY_LEN;
        count++;
    }
    out[0] = count;
    if (count > 0) {
        memcpy(&out[o], faults, count);
        o += count;
    }
    return o;
}

size_t gatt_payload_history(uint8_t out[GATT_HISTORY_MAX_LEN], uint8_t start)
{
    out[0] = (uint8_t)pump_history_count();
    out[1] = start;
    size_t o = 3;
    uint8_t count = 0;
    pump_fill_t f;
    for (unsigned i = start; count < TANKLINK_HISTORY_PAGE && pump_history_get(i, &f); i++) {
        put_u32(&out[o], f.started_local);
        put_u32(&out[o + 4], f.ran_sec);
        out[o + 8] = f.slot;
        out[o + 9] = f.started_by;
        out[o + 10] = f.stopped_by;
        out[o + 11] = 0;
        o += TANKLINK_HISTORY_ENTRY_LEN;
        count++;
    }
    out[2] = count;
    return o;
}

size_t gatt_payload_battery(uint8_t out[GATT_BATTERY_MAX_LEN])
{
    size_t o = 1;
    uint8_t count = 0;
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        if (!pump_tanks_node_get(n, NULL)) {
            continue;
        }
        pump_batlog_day_t days[PUMP_BATLOG_DAYS];
        const unsigned d = pump_battery_log_get(n, days);
        out[o++] = n;
        out[o++] = (uint8_t)d;
        for (unsigned i = 0; i < d; i++) {
            put_u16(&out[o], days[i].day);
            out[o + 2] = days[i].min_pct;
            out[o + 3] = days[i].max_pct;
            o += TANKLINK_BATTERY_DAY_LEN;
        }
        count++;
    }
    out[0] = count;
    return o;
}

size_t gatt_payload_ota_status(uint8_t out[GATT_OTA_STATUS_LEN])
{
    out[0] = pump_ota_state();
    out[1] = pump_ota_last_error();
    put_u32(&out[2], pump_ota_offset());
    return GATT_OTA_STATUS_LEN;
}

size_t gatt_payload_wifi_status(uint8_t out[GATT_WIFI_STATUS_MAX_LEN])
{
    const uint32_t ip = pump_wifi_ip();
    const char *ssid = pump_wifi_ssid();
    const size_t n = strlen(ssid);
    out[0] = (uint8_t)pump_wifi_state();
    out[1] = (uint8_t)pump_wifi_rssi();
    out[2] = (uint8_t)(ip & 0xff);
    out[3] = (uint8_t)((ip >> 8) & 0xff);
    out[4] = (uint8_t)((ip >> 16) & 0xff);
    out[5] = (uint8_t)((ip >> 24) & 0xff);
    out[6] = (uint8_t)n;
    memcpy(&out[7], ssid, n);
    uint8_t *u = &out[7 + n];
    u[0] = pump_update_state();
    u[1] = pump_update_check_result();
    pump_update_available_version(&u[2]);
    pump_update_overnight_version(&u[5]);
    put_u16(&u[8], pump_update_last_check_age_min());
    put_u32(&u[10], pump_update_available_size());
    return 7 + n + TANKLINK_WIFI_UPDATE_LEN;
}

size_t gatt_payload_wifi_scan(uint8_t out[GATT_WIFI_SCAN_MAX_LEN], uint8_t page)
{
    const int total = pump_wifi_scan_count();
    const int first = (int)page * PUMP_WIFI_SCAN_PAGE;
    size_t at = 3;
    int count = 0;
    for (int i = first; i < total && count < PUMP_WIFI_SCAN_PAGE; i++, count++) {
        pump_wifi_net_t net;
        if (!pump_wifi_scan_get(i, &net)) {
            break;
        }
        const size_t n = strlen(net.ssid);
        out[at++] = (uint8_t)n;
        memcpy(&out[at], net.ssid, n);
        at += n;
        out[at++] = (uint8_t)net.rssi;
        out[at++] = net.auth;
    }
    out[0] = pump_wifi_scan_busy() ? 1 : 0;
    out[1] = (uint8_t)total;
    out[2] = (uint8_t)count;
    return at;
}
