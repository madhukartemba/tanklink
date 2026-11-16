#include "pump_clock.h"

#include "esp_timer.h"

static bool s_valid;
static int64_t s_anchor_us;
static int64_t s_anchor_unix;

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

bool pump_clock_is_valid(void)
{
    return s_valid;
}

esp_err_t pump_clock_set(int year, unsigned month, unsigned day,
                         unsigned hour, unsigned minute, unsigned second,
                         unsigned wday)
{
    (void)wday;
    if (!valid_date(year, month, day) || hour > 23 || minute > 59 || second > 59) {
        return ESP_ERR_INVALID_ARG;
    }
    pump_civil_time_t t = {
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
    s_anchor_unix = civil_to_unix(&t);
    s_anchor_us = esp_timer_get_time();
    s_valid = true;
    return ESP_OK;
}

bool pump_clock_now(pump_civil_time_t *out)
{
    if (!s_valid || !out) {
        return false;
    }
    int64_t elapsed = (esp_timer_get_time() - s_anchor_us) / 1000000LL;
    if (elapsed < 0) {
        elapsed = 0;
    }
    int64_t unix_sec = s_anchor_unix + elapsed;
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
    return true;
}
