#include "pump_window.h"

#define DAY_MIN 1440u

unsigned pump_weekday(const pump_civil_time_t *t)
{
    /* Sakamoto: 0 = Sunday, then shifted so 0 = Monday. */
    static const int k[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    int y = t->year;
    const unsigned m = t->month >= 1 && t->month <= 12 ? t->month : 1;
    if (m < 3) {
        y -= 1;
    }
    const int sun0 = (y + y / 4 - y / 100 + y / 400 + k[m - 1] + (int)t->day) % 7;
    return (unsigned)((sun0 + 6) % 7);
}

bool pump_window_valid(uint8_t days, uint8_t sh, uint8_t sm, uint8_t eh, uint8_t em)
{
    return (days & PUMP_WINDOW_ALL_DAYS) != 0 && (days & ~PUMP_WINDOW_ALL_DAYS) == 0 &&
           sh < 24 && sm < 60 && eh < 24 && em < 60 && (sh != eh || sm != em);
}

static bool on_day(uint8_t days, unsigned wd)
{
    return (days & (1u << wd)) != 0;
}

bool pump_window_open(const pump_window_t *w, const pump_civil_time_t *now)
{
    const unsigned t = now->hour * 60u + now->minute;
    const unsigned wd = pump_weekday(now);
    const unsigned yd = (wd + 6) % 7;
    if (w->start < w->end) {
        return on_day(w->days, wd) && t >= w->start && t < w->end;
    }
    /* Past midnight: the part after the start today, or the tail of
     * yesterday's window. */
    return (on_day(w->days, wd) && t >= w->start) || (on_day(w->days, yd) && t < w->end);
}

uint32_t pump_window_minutes_until(const pump_window_t *w, const pump_civil_time_t *now)
{
    const unsigned t = now->hour * 60u + now->minute;
    const unsigned wd = pump_weekday(now);
    for (unsigned d = 0; d <= 7; d++) {
        if (!on_day(w->days, (wd + d) % 7)) {
            continue;
        }
        const uint32_t at = d * DAY_MIN + w->start;
        if (at > t) {
            return at - t;
        }
    }
    return PUMP_WINDOW_NEVER;
}
