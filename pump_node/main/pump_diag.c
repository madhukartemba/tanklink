/*
 * Memory report on the serial log: heap now, the lowest it has been since
 * boot, the largest free block, how full the NVS partition is, and how many
 * bytes of each task's stack have never been used. A low-water mark that
 * keeps falling over days is a leak; a stack with little headroom needs a
 * bigger stack.
 */
#include "pump_diag.h"

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"

#define TAG "DIAG"
#define FIRST_REPORT_US (30LL * 1000000)
#define REPORT_EVERY_US (10LL * 60 * 1000000)

/* Our tasks, the NimBLE host and the system tasks that run our callbacks. */
static const char *const k_tasks[] = {
    "pair_poll", "lora_rx", "pump_btn", "status_led", "nimble_host", "esp_timer", "ipc0",
};

static int64_t s_next_us = FIRST_REPORT_US;

void pump_diag_log(void)
{
    const size_t free_now = heap_caps_get_free_size(MALLOC_CAP_8BIT);
    const size_t low = heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT);
    const size_t block = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
    ESP_LOGI(TAG, "heap free %u, lowest %u, largest block %u, up %llds", (unsigned)free_now,
             (unsigned)low, (unsigned)block, (long long)(esp_timer_get_time() / 1000000));
    nvs_stats_t nvs;
    if (nvs_get_stats(NULL, &nvs) == ESP_OK) {
        /* Entries are 32 bytes; a blob uses one per 32 bytes plus headers. */
        ESP_LOGI(TAG, "nvs entries used %u, free %u, total %u, namespaces %u",
                 (unsigned)nvs.used_entries, (unsigned)nvs.free_entries,
                 (unsigned)nvs.total_entries, (unsigned)nvs.namespace_count);
    }
    for (size_t i = 0; i < sizeof(k_tasks) / sizeof(k_tasks[0]); i++) {
        TaskHandle_t t = xTaskGetHandle(k_tasks[i]);
        if (t) {
            /* ESP-IDF stacks are counted in bytes. */
            ESP_LOGI(TAG, "stack %-11s never used %u B", k_tasks[i],
                     (unsigned)uxTaskGetStackHighWaterMark(t));
        }
    }
}

void pump_diag_poll(void)
{
    const int64_t now = esp_timer_get_time();
    if (now >= s_next_us) {
        s_next_us = now + REPORT_EVERY_US;
        pump_diag_log();
    }
}
