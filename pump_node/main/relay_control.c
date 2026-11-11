#include "relay_control.h"

#include "esp_log.h"

#define TAG "RELAY"

esp_err_t relay_control_init(void)
{
    ESP_LOGI(TAG, "stub init (no relays)");
    return ESP_OK;
}

void relay_control_set_running(bool on)
{
    ESP_LOGD(TAG, "set_running=%d (stub)", (int)on);
}
