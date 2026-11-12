#include "tank_battery.h"

#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"
#include "sdkconfig.h"

#define TAG "TANK_BAT"

/* 100k/100k divider → Vpin ≈ Vbat/2. Atten DB11 ~0-3100 mV. */
#define DIVIDER_RATIO 2.0f

static adc_oneshot_unit_handle_t s_adc;
static adc_channel_t s_chan;
static bool s_ok;

static adc_unit_t unit_for_gpio(int gpio, adc_channel_t *chan)
{
    adc_unit_t unit;
    if (adc_oneshot_io_to_channel(gpio, &unit, chan) != ESP_OK) {
        return ADC_UNIT_1;
    }
    return unit;
}

esp_err_t tank_battery_init(void)
{
    s_ok = false;
    adc_channel_t chan;
    adc_unit_t unit = unit_for_gpio(CONFIG_TANK_BAT_ADC_GPIO, &chan);
    s_chan = chan;

    adc_oneshot_unit_init_cfg_t ucfg = {
        .unit_id = unit,
    };
    esp_err_t err = adc_oneshot_new_unit(&ucfg, &s_adc);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "adc unit: %s", esp_err_to_name(err));
        return err;
    }
    adc_oneshot_chan_cfg_t ccfg = {
        .bitwidth = ADC_BITWIDTH_DEFAULT,
        .atten = ADC_ATTEN_DB_12,
    };
    err = adc_oneshot_config_channel(s_adc, s_chan, &ccfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "adc chan: %s", esp_err_to_name(err));
        return err;
    }
    s_ok = true;
    ESP_LOGI(TAG, "ADC GPIO%d ready", CONFIG_TANK_BAT_ADC_GPIO);
    return ESP_OK;
}

static uint8_t pct_from_mv(int vbat_mv)
{
    /* Crude LiPo curve: 3.30V=0%, 3.60V~20%, 3.90V~60%, 4.20V=100%. */
    if (vbat_mv <= 3300) {
        return 0;
    }
    if (vbat_mv >= 4200) {
        return 100;
    }
    if (vbat_mv < 3600) {
        return (uint8_t)((vbat_mv - 3300) * 20 / 300);
    }
    if (vbat_mv < 3900) {
        return (uint8_t)(20 + (vbat_mv - 3600) * 40 / 300);
    }
    return (uint8_t)(60 + (vbat_mv - 3900) * 40 / 300);
}

uint8_t tank_battery_percent(void)
{
    if (!s_ok) {
        return 0;
    }
    int raw = 0;
    int sum = 0;
    int n = 0;
    for (int i = 0; i < 8; i++) {
        if (adc_oneshot_read(s_adc, s_chan, &raw) == ESP_OK) {
            sum += raw;
            n++;
        }
    }
    if (n == 0) {
        return 0;
    }
    /* Approximate mV at pin: raw full-scale ~4095 ≈ 3100 mV @ DB11/12. */
    int pin_mv = (sum / n) * 3100 / 4095;
    int vbat_mv = (int)(pin_mv * DIVIDER_RATIO);
    uint8_t pct = pct_from_mv(vbat_mv);
    ESP_LOGI(TAG, "vbat~%dmV pct=%u", vbat_mv, pct);
    return pct;
}
