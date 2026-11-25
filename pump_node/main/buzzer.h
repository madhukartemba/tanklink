#pragma once

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Low-level buzzer: an active buzzer on one GPIO, so a sound is only a
 * pattern of on/off times (no pitch, no volume). Sounds play on their own
 * task, so a caller never waits for one. Which events sound, and with which
 * sound, is in pump_buzz.c.
 */

/* Sent to the app as one byte (Buzzer characteristic): append only. */
typedef enum {
    BUZZER_SOUND_CLICK = 0,  /* 70 ms */
    BUZZER_SOUND_TICK = 1,   /* 20 ms, quietest */
    BUZZER_SOUND_LONG = 2,   /* 280 ms */
    BUZZER_SOUND_DOUBLE = 3, /* two short */
    BUZZER_SOUND_TRIPLE = 4, /* three short */
    BUZZER_SOUND_RISING = 5, /* short, short, long */
    BUZZER_SOUND_FALLING = 6, /* long, short */
    BUZZER_SOUND_CHIRP = 7,  /* four very fast ticks */
    BUZZER_SOUND_ALARM = 8,  /* six urgent beeps, about 1.5 s */
    BUZZER_SOUND_COUNT
} buzzer_sound_t;

esp_err_t buzzer_init(void);

/** Queue [sound]; returns at once. Dropped if several are already waiting. */
void buzzer_play(buzzer_sound_t sound);

#ifdef __cplusplus
}
#endif
