#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/** Log heap and task stack headroom now. */
void pump_diag_log(void);

/** Log a report from the poll loop soon (after a fill or a disconnect), so
 * logging doesn't add to the stack depth being measured. */
void pump_diag_request(void);

/** Call often: logs 30 s after boot, every 10 minutes, and when requested. */
void pump_diag_poll(void);

#ifdef __cplusplus
}
#endif
