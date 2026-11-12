#pragma once

/**
 * Tank XIAO ESP32-C3 + RA-02 pin contract.
 *
 * Strapping: GPIO2 (D0), GPIO8 (D8), GPIO9 (D9/BOOT).
 * Seeed / community (C3 + SX1278):
 *  - Never put LoRa MISO on D9 — module drives MISO low at power-up → download boot.
 *  - SCK on D8 and RESET on D9 are OK if those nets are HIGH at reset
 *    (10 kΩ pull-ups on SCK + NSS; RESET idle-high).
 *
 * Canonical map:
 *   D0/2  BAT ADC     D1/3  Button      D2/4  Float FULL
 *   D3/5  Float EMPTY D4/6  LED         D5/7  LoRa DIO0
 *   D6/21 LoRa MISO   D7/20 LoRa NSS    D8/8  LoRa SCK
 *   D9/9  LoRa RESET  D10/10 LoRa MOSI
 */

#include "sdkconfig.h"
#include "esp_log.h"

#ifdef __cplusplus
extern "C" {
#endif

static inline bool tank_boot_pins_ok(void)
{
    /* Hard forbid: MISO (or any LoRa data that sits low) on BOOT pin. */
    if (CONFIG_TANK_LORA_MISO_GPIO == 9) {
        return false;
    }
    if (CONFIG_TANK_LORA_MOSI_GPIO == 9 || CONFIG_TANK_LORA_CS_GPIO == 9) {
        return false;
    }
    if (CONFIG_TANK_BUTTON_GPIO == 8 || CONFIG_TANK_LED_GPIO == 8) {
        /* Avoid strong drivers fighting SCK strap without care. */
    }
    return true;
}

static inline void tank_boot_pins_log(const char *tag)
{
#if CONFIG_TANK_ENABLE_EMPTY_FLOAT
    ESP_LOGI(tag,
             "pins bat=%d btn=%d full=%d empty=%d led=%d | lora sck=%d miso=%d mosi=%d cs=%d rst=%d dio0=%d",
             CONFIG_TANK_BAT_ADC_GPIO, CONFIG_TANK_BUTTON_GPIO, CONFIG_TANK_FLOAT_FULL_GPIO,
             CONFIG_TANK_FLOAT_EMPTY_GPIO, CONFIG_TANK_LED_GPIO, CONFIG_TANK_LORA_SCK_GPIO,
             CONFIG_TANK_LORA_MISO_GPIO, CONFIG_TANK_LORA_MOSI_GPIO, CONFIG_TANK_LORA_CS_GPIO,
             CONFIG_TANK_LORA_RST_GPIO, CONFIG_TANK_LORA_DIO0_GPIO);
#else
    ESP_LOGI(tag,
             "pins bat=%d btn=%d full=%d empty=off led=%d | lora sck=%d miso=%d mosi=%d cs=%d rst=%d dio0=%d",
             CONFIG_TANK_BAT_ADC_GPIO, CONFIG_TANK_BUTTON_GPIO, CONFIG_TANK_FLOAT_FULL_GPIO,
             CONFIG_TANK_LED_GPIO, CONFIG_TANK_LORA_SCK_GPIO, CONFIG_TANK_LORA_MISO_GPIO,
             CONFIG_TANK_LORA_MOSI_GPIO, CONFIG_TANK_LORA_CS_GPIO, CONFIG_TANK_LORA_RST_GPIO,
             CONFIG_TANK_LORA_DIO0_GPIO);
#endif
    ESP_LOGI(tag, "HW: 10k NSS+SCK+MOSI→3V3; 10k LED D4→GND (boot glimmer)");
    if (!tank_boot_pins_ok()) {
        ESP_LOGE(tag, "INVALID: LoRa MISO/MOSI/CS on GPIO9 (BOOT) — move MISO to D6/GPIO21");
    }
}

#ifdef __cplusplus
}
#endif

#if CONFIG_TANK_LORA_MISO_GPIO == 9
#error "TANK_LORA_MISO_GPIO on D9/GPIO9 (BOOT) — SX1278 pulls MISO low at power-up; use D6/GPIO21"
#endif
#if CONFIG_TANK_LORA_CS_GPIO == 9 || CONFIG_TANK_LORA_MOSI_GPIO == 9
#error "Do not put LoRa CS/MOSI on GPIO9 (BOOT)"
#endif
