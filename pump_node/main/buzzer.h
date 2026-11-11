#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BUZZER_TONE_CLICK = 0, /* short tick (~60 ms) — kitchen button click */
    BUZZER_TONE_SOFT = 1,  /* quieter short (~35 ms) */
    BUZZER_TONE_SHARP = 2, /* longer attention (~120 ms) */
    BUZZER_TONE_DOUBLE = 3, /* two ticks */
    BUZZER_TONE_COUNT
} buzzer_tone_t;

esp_err_t buzzer_init(void);
void buzzer_set_enabled(bool enabled);
bool buzzer_enabled(void);
void buzzer_set_user_tone(buzzer_tone_t tone);
buzzer_tone_t buzzer_user_tone(void);

/** Play selected tone if master enable is on (or force=true for test). */
void buzzer_play(buzzer_tone_t tone, bool force);

/** Play the configured user tone. */
void buzzer_play_user(bool force);

void buzzer_off(void);

#ifdef __cplusplus
}
#endif
