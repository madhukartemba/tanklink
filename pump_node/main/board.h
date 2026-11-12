#pragma once

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*board_button_cb_t)(void);
typedef void (*board_hold_progress_cb_t)(uint8_t percent);
typedef void (*board_long_press_cb_t)(void);

esp_err_t board_init(void);
void board_set_pump_on(bool on);

void board_set_start_callback(board_button_cb_t cb); /* short Start */
void board_set_stop_callback(board_button_cb_t cb);  /* short Stop */
void board_set_hold_progress_callback(board_hold_progress_cb_t cb);
void board_set_long_press_callback(board_long_press_cb_t cb); /* both held → BLE pair */

#ifdef __cplusplus
}
#endif
