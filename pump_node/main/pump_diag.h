#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/** Log heap and task stack headroom now. */
void pump_diag_log(void);

/** Call often: logs 30 s after boot, then every 10 minutes. */
void pump_diag_poll(void);

#ifdef __cplusplus
}
#endif
