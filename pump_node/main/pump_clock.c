#include "pump_clock.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "nvs.h"
#include "freertos/FreeRTOS.h"
#include "pump_control.h"
#include "pump_errors.h"
#include "pump_rtc.h"
#include "status_led.h"

#define TAG "CLOCK"
/* Re-anchor to the DS3231 this often so ESP32 crystal drift never builds up. */
#define RTC_RESYNC_US (60LL * 60 * 1000000)

static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static bool s_valid;
static int64_t s_anchor_us;
static int64_t s_anchor_unix;
static bool s_rtc_ok;
static int64_t s_last_rtc_read_us;
static uint8_t s_fault;
static bool s_faults_armed;

static bool clock_fault_code(uint8_t code)
{
    return code == PUMP_ERR_I2C || code == PUMP_ERR_RTC_MISSING ||
           code == PUMP_ERR_RTC_LOST || code == PUMP_ERR_RTC_COMM;
}

/* The DS3231 lost power at some point since this boot (its oscillator had
 * stopped). Unlike the fault code, setting the time doesn't clear it: the
 * app keeps telling the user the clock battery is likely flat. */
static bool s_lost_since_boot;

bool pump_clock_lost_power_since_boot(void)
{
    return s_lost_since_boot;
}

static void publish_fault(uint8_t code)
{
    if (code == PUMP_ERR_RTC_LOST) {
        s_lost_since_boot = true;
    }
    const uint8_t prev = s_fault;
    s_fault = code;
    if (!s_faults_armed || code == prev) {
        return;
    }
    const uint8_t cur = pump_control_last_error();
    if (code == 0) {
        if (clock_fault_code(cur)) {
            pump_control_clear_error();
        }
        return;
    }
    if (cur == PUMP_ERR_NONE || clock_fault_code(cur)) {
        pump_control_set_error(code);
        status_led_show_error(code);
    }
}

static bool valid_date(int y, unsigned m, unsigned d)
{
    if (y < 2020 || y > 2099 || m < 1 || m > 12 || d < 1 || d > 31) {
        return false;
    }
    static const unsigned mdays[] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    unsigned dim = mdays[m];
    const bool leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
    if (m == 2 && leap) {
        dim = 29;
    }
    return d <= dim;
}

/* Howard Hinnant civil-date algorithms (public domain). */
static int64_t days_from_civil(int y, unsigned m, unsigned d)
{
    y -= m <= 2;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (int64_t)era * 146097 + (int64_t)doe - 719468;
}

static void civil_from_days(int64_t z, int *y, unsigned *m, unsigned *d)
{
    z += 719468;
    const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    const unsigned doe = (unsigned)(z - era * 146097);
    const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const int y_out = (int)yoe + (int)era * 400;
    const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const unsigned mp = (5 * doy + 2) / 153;
    const unsigned d_out = doy - (153 * mp + 2) / 5 + 1;
    const unsigned m_out = mp < 10 ? mp + 3 : mp - 9;
    *y = y_out + (m_out <= 2);
    *m = m_out;
    *d = d_out;
}

static int64_t civil_to_unix(const pump_civil_time_t *t)
{
    const int64_t days = days_from_civil(t->year, t->month, t->day);
    return days * 86400 + (int64_t)t->hour * 3600 + (int64_t)t->minute * 60 +
           (int64_t)t->second;
}

static void unix_to_civil(int64_t unix_sec, pump_civil_time_t *out)
{
    int64_t days = unix_sec / 86400;
    int sod = (int)(unix_sec % 86400);
    if (sod < 0) {
        sod += 86400;
        days -= 1;
    }
    int y = 0;
    unsigned m = 0;
    unsigned d = 0;
    civil_from_days(days, &y, &m, &d);
    out->year = y;
    out->month = m;
    out->day = d;
    out->hour = (unsigned)(sod / 3600);
    out->minute = (unsigned)((sod % 3600) / 60);
    out->second = (unsigned)(sod % 60);
}

static bool valid_civil(const pump_civil_time_t *t)
{
    return valid_date(t->year, t->month, t->day) && t->hour <= 23 && t->minute <= 59 &&
           t->second <= 59;
}

static void anchor(int64_t unix_sec)
{
    const int64_t now_us = esp_timer_get_time();
    portENTER_CRITICAL(&s_lock);
    s_anchor_unix = unix_sec;
    s_anchor_us = now_us;
    s_valid = true;
    portEXIT_CRITICAL(&s_lock);
}

/* Read the DS3231 and anchor to it. ESP_ERR_INVALID_STATE means the oscillator stopped. */
static esp_err_t load_from_rtc(void)
{
    s_last_rtc_read_us = esp_timer_get_time();
    pump_civil_time_t t;
    esp_err_t err = pump_rtc_read(&t);
    if (err == ESP_ERR_INVALID_STATE) {
        s_rtc_ok = false;
        ESP_LOGW(TAG, "RTC lost power (oscillator stopped); waiting for phone time");
        return err;
    }
    if (err != ESP_OK || !valid_civil(&t)) {
        ESP_LOGW(TAG, "RTC read failed (%s)", esp_err_to_name(err));
        return err != ESP_OK ? err : ESP_ERR_INVALID_RESPONSE;
    }
    s_rtc_ok = true;
    anchor(civil_to_unix(&t));
    return ESP_OK;
}

#define NVS_NS "tl_clock"
#define NVS_KEY_UTC_OFF "utc_off"

static int16_t s_utc_off_min;
static bool s_utc_off_known;

static void load_utc_offset(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    int16_t v = 0;
    if (nvs_get_i16(h, NVS_KEY_UTC_OFF, &v) == ESP_OK) {
        s_utc_off_min = v;
        s_utc_off_known = true;
    }
    nvs_close(h);
}

bool pump_clock_utc_offset(int16_t *minutes)
{
    if (!s_utc_off_known) {
        return false;
    }
    if (minutes) {
        *minutes = s_utc_off_min;
    }
    return true;
}

void pump_clock_set_utc_offset(int16_t minutes)
{
    if (s_utc_off_known && s_utc_off_min == minutes) {
        return;
    }
    s_utc_off_min = minutes;
    s_utc_off_known = true;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    if (nvs_set_i16(h, NVS_KEY_UTC_OFF, minutes) == ESP_OK) {
        nvs_commit(h);
    }
    nvs_close(h);
}

esp_err_t pump_clock_set_unix(int64_t local_unix)
{
    pump_civil_time_t t;
    unix_to_civil(local_unix, &t);
    return pump_clock_set(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

void pump_clock_init(void)
{
    load_utc_offset();
    const esp_err_t err = pump_rtc_init();
    if (err == ESP_ERR_NOT_SUPPORTED) {
        return;
    }
    if (err == ESP_ERR_NOT_FOUND) {
        ESP_LOGI(TAG, "no RTC; clock starts when the phone sends the time");
        s_fault = PUMP_ERR_RTC_MISSING;
        return;
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "I2C init failed");
        s_fault = PUMP_ERR_I2C;
        return;
    }
    const esp_err_t rd = load_from_rtc();
    if (rd == ESP_OK) {
        pump_civil_time_t t;
        pump_clock_now(&t);
        ESP_LOGI(TAG, "clock from RTC %04d-%02u-%02u %02u:%02u:%02u", t.year, t.month,
                 t.day, t.hour, t.minute, t.second);
    } else if (rd == ESP_ERR_INVALID_STATE) {
        s_fault = PUMP_ERR_RTC_LOST;
        s_lost_since_boot = true;
    } else {
        s_fault = PUMP_ERR_RTC_COMM;
    }
}

uint8_t pump_clock_fault(void)
{
    return s_fault;
}

void pump_clock_arm_faults(void)
{
    s_faults_armed = true;
    if (s_fault != 0) {
        const uint8_t code = s_fault;
        s_fault = 0;
        publish_fault(code);
    }
}

void pump_clock_poll(void)
{
    if (!pump_rtc_present() || !s_rtc_ok) {
        return;
    }
    if (esp_timer_get_time() - s_last_rtc_read_us < RTC_RESYNC_US) {
        return;
    }
    const esp_err_t err = load_from_rtc();
    if (err == ESP_OK) {
        publish_fault(0);
    } else if (err == ESP_ERR_INVALID_STATE) {
        publish_fault(PUMP_ERR_RTC_LOST);
    } else {
        publish_fault(PUMP_ERR_RTC_COMM);
    }
}

bool pump_clock_rtc_present(void)
{
    return pump_rtc_present();
}

bool pump_clock_rtc_ok(void)
{
    return s_rtc_ok;
}

bool pump_clock_is_valid(void)
{
    return s_valid;
}

esp_err_t pump_clock_set(int year, unsigned month, unsigned day,
                         unsigned hour, unsigned minute, unsigned second)
{
    pump_civil_time_t t = {
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
    if (!valid_civil(&t)) {
        return ESP_ERR_INVALID_ARG;
    }
    anchor(civil_to_unix(&t));
    if (pump_rtc_present()) {
        esp_err_t err = pump_rtc_write(&t);
        if (err == ESP_OK) {
            s_rtc_ok = true;
            s_last_rtc_read_us = esp_timer_get_time();
            publish_fault(0);
        } else {
            ESP_LOGW(TAG, "RTC write failed: %s", esp_err_to_name(err));
            publish_fault(PUMP_ERR_RTC_COMM);
        }
    }
    return ESP_OK;
}

bool pump_clock_unix_now(int64_t *out)
{
    if (!out) {
        return false;
    }
    portENTER_CRITICAL(&s_lock);
    const bool valid = s_valid;
    const int64_t anchor_us = s_anchor_us;
    const int64_t anchor_unix = s_anchor_unix;
    portEXIT_CRITICAL(&s_lock);
    if (!valid) {
        return false;
    }
    int64_t elapsed = (esp_timer_get_time() - anchor_us) / 1000000LL;
    if (elapsed < 0) {
        elapsed = 0;
    }
    *out = anchor_unix + elapsed;
    return true;
}

bool pump_clock_now(pump_civil_time_t *out)
{
    int64_t unix_sec = 0;
    if (!out || !pump_clock_unix_now(&unix_sec)) {
        return false;
    }
    unix_to_civil(unix_sec, out);
    return true;
}
