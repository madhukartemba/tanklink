#include "pump_factory.h"

#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "gatt_svr.h"
#include "pump_control.h"
#include "lora_link.h"
#include "pump_config.h"
#include "pump_pair.h"
#include "pump_runlog.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "pump_history.h"
#include "relay_control.h"
#include "status_led.h"

#define TAG "FACTORY"

static void factory_reboot_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(1200));
    esp_restart();
}

esp_err_t pump_factory_reset(void)
{
    ESP_LOGW(TAG, "Factory reset — clearing pair, tank, config");
    pump_control_set_silent(false, PUMP_CAUSE_SYSTEM);
    relay_control_set_blocked(true);

    esp_err_t err = pump_pair_unpair();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "pair clear failed: %s", esp_err_to_name(err));
    }
    err = lora_link_unpair_all();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "tank clear failed: %s", esp_err_to_name(err));
    }
    err = pump_sched_clear();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "schedule clear failed: %s", esp_err_to_name(err));
    }
    err = pump_history_clear();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "history clear failed: %s", esp_err_to_name(err));
    }
    err = pump_tanks_clear();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "tank slot clear failed: %s", esp_err_to_name(err));
    }
    err = pump_config_reset_defaults();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "config reset failed: %s", esp_err_to_name(err));
    }
    pump_config_apply_buzzer();
    pump_config_apply_led();
    pump_control_clear_error();
    pump_runlog_clear_event();

    status_led_set_mode(STATUS_LED_UPDATE_OK);
    if (xTaskCreate(factory_reboot_task, "fac_rst", 2048, NULL, 5, NULL) != pdPASS) {
        vTaskDelay(pdMS_TO_TICKS(1200));
        esp_restart();
    }
    return ESP_OK;
}
