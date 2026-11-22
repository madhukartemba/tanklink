#include "pump_wifi.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "mdns.h"
#include "nvs.h"

#include "pump_clock.h"
#include "pump_pair.h"
#include "pump_wifi_api.h"
#include "pump_sched.h"
#include "tanklink_uuid.h"

#define TAG "WIFI"
#define NVS_NS "tl_wifi"
#define NVS_KEY_SSID "ssid"
#define NVS_KEY_PASS "pass"

/* esp_wifi_set_max_tx_power units: 0.25 dBm. */
#define PUMP_WIFI_TX_POWER 34

#define BACKOFF_MIN_MS 2000
/* A mains-powered pump with a router that is back should rejoin within a minute. */
#define BACKOFF_MAX_MS (60 * 1000)
/* Apply an SNTP time only when it differs this much, to spare the RTC. */
#define SNTP_MIN_STEP_SEC 2

static char s_ssid[PUMP_WIFI_SSID_MAX + 1];
static char s_pass[PUMP_WIFI_PASS_MAX + 1];
static bool s_have_creds;
static bool s_inited;  /* driver and netif created */
static bool s_started; /* esp_wifi_start() done */
static volatile pump_wifi_state_t s_state = PUMP_WIFI_OFF;
static volatile uint32_t s_ip;
static volatile int8_t s_rssi;
static uint32_t s_backoff_ms = BACKOFF_MIN_MS;
static esp_timer_handle_t s_retry_timer;
static esp_netif_t *s_netif;
static bool s_mdns_up;
static bool s_sntp_up;
static void (*s_change_cb)(void);

static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static volatile bool s_sntp_pending;
static volatile int64_t s_sntp_utc;

static pump_wifi_net_t s_scan[PUMP_WIFI_SCAN_MAX];
static int s_scan_n;
static volatile bool s_scanning;

static void notify_change(void)
{
    if (s_change_cb) {
        s_change_cb();
    }
}

static void set_state(pump_wifi_state_t st)
{
    if (s_state != st) {
        s_state = st;
        notify_change();
    }
}

/* ---------------------------------------------------------------------------
 * Saved network
 * ------------------------------------------------------------------------- */

static void load_creds(void)
{
    s_ssid[0] = '\0';
    s_pass[0] = '\0';
    s_have_creds = false;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    size_t n = sizeof(s_ssid);
    if (nvs_get_str(h, NVS_KEY_SSID, s_ssid, &n) == ESP_OK && s_ssid[0] != '\0') {
        s_have_creds = true;
        n = sizeof(s_pass);
        if (nvs_get_str(h, NVS_KEY_PASS, s_pass, &n) != ESP_OK) {
            s_pass[0] = '\0';
        }
    }
    nvs_close(h);
}

static esp_err_t save_creds(const char *ssid, const char *pass)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    if (ssid) {
        err = nvs_set_str(h, NVS_KEY_SSID, ssid);
        if (err == ESP_OK) {
            err = nvs_set_str(h, NVS_KEY_PASS, pass ? pass : "");
        }
    } else {
        nvs_erase_key(h, NVS_KEY_SSID);
        nvs_erase_key(h, NVS_KEY_PASS);
    }
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

/* ---------------------------------------------------------------------------
 * mDNS and SNTP
 * ------------------------------------------------------------------------- */

static void start_mdns(void)
{
    if (s_mdns_up) {
        return;
    }
    if (mdns_init() != ESP_OK) {
        ESP_LOGW(TAG, "mdns init failed");
        return;
    }
    char host[24];
    snprintf(host, sizeof(host), "tanklink-%s", pump_pair_serial());
    for (char *c = host; *c; c++) {
        *c = (char)tolower((unsigned char)*c);
    }
    mdns_hostname_set(host);
    mdns_instance_name_set(pump_pair_adv_name());

    const uint8_t *id = pump_pair_device_id();
    char id_hex[TANKLINK_DEVICE_ID_LEN * 2 + 1];
    for (int i = 0; i < TANKLINK_DEVICE_ID_LEN; i++) {
        snprintf(&id_hex[i * 2], 3, "%02x", id[i]);
    }
    char proto[8];
    snprintf(proto, sizeof(proto), "%d.%d", TANKLINK_PROTO_MAJOR, TANKLINK_PROTO_MINOR);
    mdns_txt_item_t txt[] = {{"id", id_hex}, {"proto", proto}};
    mdns_service_add(NULL, "_tanklink", "_tcp", PUMP_API_PORT, txt, 2);
    s_mdns_up = true;
    ESP_LOGI(TAG, "mDNS %s.local", host);
}

static void on_sntp_sync(struct timeval *tv)
{
    /* Runs in the TCP/IP task: just hand the time to pump_wifi_poll(). */
    portENTER_CRITICAL(&s_lock);
    s_sntp_utc = tv->tv_sec;
    s_sntp_pending = true;
    portEXIT_CRITICAL(&s_lock);
}

static void start_sntp(void)
{
    if (s_sntp_up) {
        return;
    }
    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    cfg.sync_cb = on_sntp_sync;
    if (esp_netif_sntp_init(&cfg) == ESP_OK) {
        s_sntp_up = true;
    } else {
        ESP_LOGW(TAG, "sntp init failed");
    }
}

void pump_wifi_poll(void)
{
    if (!s_sntp_pending) {
        return;
    }
    portENTER_CRITICAL(&s_lock);
    const int64_t utc = s_sntp_utc;
    s_sntp_pending = false;
    portEXIT_CRITICAL(&s_lock);

    int16_t off = 0;
    if (!pump_clock_utc_offset(&off)) {
        return; /* no phone has told us the zone yet: can't know local time */
    }
    const int64_t local = utc + (int64_t)off * 60;
    int64_t before = 0;
    const bool had_time = pump_clock_unix_now(&before);
    if (had_time && local - before < SNTP_MIN_STEP_SEC && before - local < SNTP_MIN_STEP_SEC) {
        return;
    }
    if (pump_clock_set_unix(local) != ESP_OK) {
        return;
    }
    int64_t after = 0;
    (void)pump_clock_unix_now(&after);
    const int64_t delta = after - before;
    if (!had_time || delta > 300 || delta < -300) {
        pump_sched_clear_fired(); /* same rule as a phone sync */
    }
    ESP_LOGI(TAG, "clock set from SNTP (utc offset %d min)", off);
}

/* ---------------------------------------------------------------------------
 * Connection
 * ------------------------------------------------------------------------- */

static void retry_cb(void *arg)
{
    (void)arg;
    if (s_have_creds && s_started) {
        esp_wifi_connect();
    }
}

static void schedule_retry(void)
{
    esp_timer_stop(s_retry_timer);
    esp_timer_start_once(s_retry_timer, (uint64_t)s_backoff_ms * 1000);
    s_backoff_ms = s_backoff_ms * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : s_backoff_ms * 2;
}

static uint8_t auth_kind(wifi_auth_mode_t mode)
{
    switch (mode) {
    case WIFI_AUTH_OPEN:
        return PUMP_WIFI_AUTH_OPEN;
    case WIFI_AUTH_WPA2_ENTERPRISE:
    case WIFI_AUTH_WPA3_ENTERPRISE:
        return PUMP_WIFI_AUTH_UNSUPPORTED;
    default:
        return PUMP_WIFI_AUTH_SECURED;
    }
}

/* Runs in the event task. Records are taken one at a time (each is freed as it
 * is read), so no buffer for the whole list is kept around: that was 3.8 KB of
 * RAM held for good, Wi-Fi or not. */
static void collect_scan(void)
{
    s_scan_n = 0;
    wifi_ap_record_t rec;
    /* Records come strongest first. Skip hidden and repeated names. */
    while (s_scan_n < PUMP_WIFI_SCAN_MAX && esp_wifi_scan_get_ap_record(&rec) == ESP_OK) {
        const char *name = (const char *)rec.ssid;
        if (name[0] == '\0') {
            continue;
        }
        bool dup = false;
        for (int j = 0; j < s_scan_n && !dup; j++) {
            dup = strcmp(s_scan[j].ssid, name) == 0;
        }
        if (dup) {
            continue;
        }
        pump_wifi_net_t *e = &s_scan[s_scan_n++];
        strlcpy(e->ssid, name, sizeof(e->ssid));
        e->rssi = rec.rssi;
        e->auth = auth_kind(rec.authmode);
    }
    esp_wifi_clear_ap_list(); /* whatever was not read */
    s_scanning = false;
    notify_change();
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    switch (id) {
    case WIFI_EVENT_STA_START:
        if (s_have_creds) {
            esp_wifi_connect();
        }
        break;
    case WIFI_EVENT_STA_CONNECTED:
        break;
    case WIFI_EVENT_STA_DISCONNECTED: {
        const wifi_event_sta_disconnected_t *d = data;
        s_ip = 0;
        s_rssi = 0;
        if (!s_have_creds) {
            set_state(PUMP_WIFI_OFF);
            break;
        }
        switch (d->reason) {
        case WIFI_REASON_NO_AP_FOUND:
            set_state(PUMP_WIFI_NOT_FOUND);
            break;
        /* Only a failed key exchange means a wrong password. AUTH_EXPIRE and
         * ASSOC_EXPIRE are the router not answering in time (busy, or the
         * radio shared with Bluetooth): just retry. */
        case WIFI_REASON_AUTH_FAIL:
        case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
        case WIFI_REASON_HANDSHAKE_TIMEOUT:
        case WIFI_REASON_MIC_FAILURE:
            set_state(PUMP_WIFI_WRONG_PASSWORD);
            break;
        default:
            /* Dropped (router restart, out of range): keep the last verdict
             * if it was an error, else show "connecting". */
            if (s_state == PUMP_WIFI_CONNECTED) {
                set_state(PUMP_WIFI_CONNECTING);
            }
            break;
        }
        ESP_LOGW(TAG, "disconnected reason=%d, retry in %u ms", d->reason,
                 (unsigned)s_backoff_ms);
        schedule_retry();
        break;
    }
    case WIFI_EVENT_SCAN_DONE:
        collect_scan();
        break;
    default:
        break;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    if (id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *e = data;
        s_ip = e->ip_info.ip.addr;
        s_backoff_ms = BACKOFF_MIN_MS;
        wifi_ap_record_t ap;
        s_rssi = esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
        ESP_LOGI(TAG, "got IP " IPSTR " rssi=%d", IP2STR(&e->ip_info.ip), s_rssi);
        start_mdns();
        start_sntp();
        pump_wifi_api_start();
        if (s_state == PUMP_WIFI_CONNECTED) {
            notify_change(); /* address changed */
        }
        set_state(PUMP_WIFI_CONNECTED);
    } else if (id == IP_EVENT_STA_LOST_IP) {
        s_ip = 0;
        notify_change();
    }
}

/** Create the netif and Wi-Fi driver once, and start station mode. A failed
 * try can be made again: each part is only created once. */
static esp_err_t ensure_started(void)
{
    if (s_started) {
        return ESP_OK;
    }
    if (!s_inited) {
        ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif init");
        esp_err_t err = esp_event_loop_create_default();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) { /* INVALID_STATE: already there */
            return err;
        }
        if (!s_netif) {
            s_netif = esp_netif_create_default_wifi_sta();
            ESP_RETURN_ON_FALSE(s_netif, ESP_FAIL, TAG, "netif create");
        }
        const wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");
        ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM)); /* we keep our own credentials */
        /* Modem sleep: BLE coexistence needs the gaps. */
        ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_MIN_MODEM));
        const esp_timer_create_args_t args = {.callback = retry_cb, .name = "wifi_retry"};
        ESP_ERROR_CHECK(esp_timer_create(&args, &s_retry_timer));
        ESP_ERROR_CHECK(
            esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL));
        ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, ESP_EVENT_ANY_ID, on_ip_event, NULL));
        s_inited = true;
    }
    esp_err_t err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err == ESP_OK) {
        err = esp_wifi_start();
    }
    s_started = err == ESP_OK;
    if (s_started) {
        /* 8.5 dBm. At the default (20 dBm) the C3 SuperMini's small antenna and
         * supply make the router miss the pump's first frames: every attempt
         * ended in "auth expired" (reason 2) and it never joined. Measured:
         * joins at once at 8.5 dBm, never at 20 dBm, 30 cm from the router. */
        ESP_ERROR_CHECK(esp_wifi_set_max_tx_power(PUMP_WIFI_TX_POWER));
    }
    return err;
}

static void apply_creds(void)
{
    wifi_config_t wc;
    memset(&wc, 0, sizeof(wc));
    strlcpy((char *)wc.sta.ssid, s_ssid, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, s_pass, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = s_pass[0] ? WIFI_AUTH_WPA_PSK : WIFI_AUTH_OPEN;
    /* Look at every channel and join the strongest access point of this name.
     * The default joins the first one heard, which with a mesh or several
     * routers sharing a name can be a far one that never answers. */
    wc.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    wc.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
    wc.sta.pmf_cfg.capable = true;
    wc.sta.pmf_cfg.required = false;
    esp_wifi_set_config(WIFI_IF_STA, &wc);
}

esp_err_t pump_wifi_init(void)
{
    load_creds();
    if (!s_have_creds) {
        return ESP_OK; /* stays off: nothing started, no memory used */
    }
    ESP_LOGI(TAG, "joining \"%s\"", s_ssid);
    set_state(PUMP_WIFI_CONNECTING);
    const esp_err_t err = ensure_started();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "start failed: %s", esp_err_to_name(err));
        return err;
    }
    apply_creds();
    esp_wifi_connect();
    return ESP_OK;
}

esp_err_t pump_wifi_set(const char *ssid, const char *pass)
{
    if (!ssid || ssid[0] == '\0' || strlen(ssid) > PUMP_WIFI_SSID_MAX ||
        (pass && strlen(pass) > PUMP_WIFI_PASS_MAX)) {
        return ESP_ERR_INVALID_ARG;
    }
    const esp_err_t err = save_creds(ssid, pass);
    if (err != ESP_OK) {
        return err;
    }
    strlcpy(s_ssid, ssid, sizeof(s_ssid));
    strlcpy(s_pass, pass ? pass : "", sizeof(s_pass));
    s_have_creds = true;
    s_backoff_ms = BACKOFF_MIN_MS;
    esp_err_t st = ensure_started();
    if (st != ESP_OK) {
        return st;
    }
    set_state(PUMP_WIFI_CONNECTING);
    s_ip = 0;
    esp_timer_stop(s_retry_timer);
    esp_wifi_disconnect();
    apply_creds();
    esp_wifi_connect();
    notify_change();
    return ESP_OK;
}

esp_err_t pump_wifi_forget(void)
{
    const esp_err_t err = save_creds(NULL, NULL);
    s_have_creds = false;
    s_ssid[0] = '\0';
    memset(s_pass, 0, sizeof(s_pass));
    if (s_started) {
        esp_timer_stop(s_retry_timer);
        esp_wifi_disconnect();
    }
    s_ip = 0;
    s_rssi = 0;
    set_state(PUMP_WIFI_OFF);
    notify_change();
    return err;
}

/* ---------------------------------------------------------------------------
 * Status and scan
 * ------------------------------------------------------------------------- */

pump_wifi_state_t pump_wifi_state(void)
{
    return s_state;
}

int8_t pump_wifi_rssi(void)
{
    if (s_state != PUMP_WIFI_CONNECTED) {
        return 0;
    }
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
        s_rssi = ap.rssi;
    }
    return s_rssi;
}

uint32_t pump_wifi_ip(void)
{
    return s_ip;
}

const char *pump_wifi_ssid(void)
{
    return s_ssid;
}

esp_err_t pump_wifi_scan_start(void)
{
    if (s_scanning) {
        return ESP_OK;
    }
    esp_err_t err = ensure_started();
    if (err != ESP_OK) {
        return err;
    }
    s_scan_n = 0;
    s_scanning = true;
    const wifi_scan_config_t sc = {.show_hidden = false};
    err = esp_wifi_scan_start(&sc, false);
    if (err != ESP_OK) {
        s_scanning = false;
    }
    return err;
}

bool pump_wifi_scan_busy(void)
{
    return s_scanning;
}

int pump_wifi_scan_count(void)
{
    return s_scan_n;
}

bool pump_wifi_scan_get(int i, pump_wifi_net_t *out)
{
    if (i < 0 || i >= s_scan_n || !out) {
        return false;
    }
    *out = s_scan[i];
    return true;
}

void pump_wifi_set_change_callback(void (*cb)(void))
{
    s_change_cb = cb;
}
