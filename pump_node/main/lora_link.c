#include "lora_link.h"

#include "esp_log.h"

#define TAG "LORA"

esp_err_t lora_link_init(void)
{
    ESP_LOGI(TAG, "stub init (no radio)");
    return ESP_OK;
}

void lora_link_poll(void)
{
    /* no-op */
}
