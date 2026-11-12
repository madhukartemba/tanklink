#include "esp_log.h"
#include "esp_sleep.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TAG "BARE_SLEEP"
#define AWAKE_MS 15000

void app_main(void)
{
    ESP_LOGI(TAG, "bare deep sleep — no BLE/LoRa; awake %d ms then sleep", AWAKE_MS);
    vTaskDelay(pdMS_TO_TICKS(AWAKE_MS));
    ESP_ERROR_CHECK(esp_sleep_enable_timer_wakeup(60ULL * 1000000ULL));
    ESP_LOGI(TAG, "deep sleep now — measure BAT±, USB unplugged (expect ~40-50uA)");
    vTaskDelay(pdMS_TO_TICKS(50));
    esp_deep_sleep_start();
}
