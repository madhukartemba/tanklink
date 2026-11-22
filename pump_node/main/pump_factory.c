#include "pump_factory.h"

#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "pump_control.h"
#include "relay_control.h"
#include "status_led.h"

#define TAG "FACTORY"

static void factory_reboot_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(1200)); /* the green cue, and the BLE reply */
    esp_restart();
}

esp_err_t pump_factory_reset(void)
{
    ESP_LOGW(TAG, "Factory reset: erasing every saved setting, then restarting");
    pump_control_set_silent(false, PUMP_CAUSE_SYSTEM);
    relay_control_block(RELAY_BLOCK_RESET, true); /* until the restart */

    /* One erase of the whole NVS partition clears everything (phones, tanks,
     * schedules, history, Wi-Fi, alert key, settings) and is cheaper on the
     * flash than clearing each item. Every module starts from its defaults
     * after the restart, and a new pump identity is made from the MAC. */
    const esp_err_t err = nvs_flash_erase();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS erase failed: %s", esp_err_to_name(err));
    }
    status_led_set_mode(err == ESP_OK ? STATUS_LED_UPDATE_OK : STATUS_LED_UPDATE_ERR);
    /* Restart either way: NVS is no longer usable until it is set up again. */
    if (xTaskCreate(factory_reboot_task, "fac_rst", 2048, NULL, 5, NULL) != pdPASS) {
        esp_restart();
    }
    return err;
}
