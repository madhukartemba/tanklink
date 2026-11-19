#include "pump_rtc.h"

#include "esp_log.h"
#include "sdkconfig.h"

#define TAG "RTC"

#if !CONFIG_PUMP_ENABLE_RTC

esp_err_t pump_rtc_init(void)
{
    ESP_LOGI(TAG, "disabled");
    return ESP_ERR_NOT_SUPPORTED;
}
bool pump_rtc_present(void)
{
    return false;
}
esp_err_t pump_rtc_read(pump_civil_time_t *out)
{
    (void)out;
    return ESP_ERR_NOT_SUPPORTED;
}
esp_err_t pump_rtc_write(const pump_civil_time_t *t)
{
    (void)t;
    return ESP_ERR_NOT_SUPPORTED;
}

#else

#include "driver/i2c_master.h"

#define DS3231_ADDR 0x68
#define DS3231_REG_TIME 0x00
#define DS3231_REG_CONTROL 0x0E
#define DS3231_REG_STATUS 0x0F
#define DS3231_STATUS_OSF 0x80
#define I2C_TIMEOUT_MS 50

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_dev;
static bool s_present;

static uint8_t bcd_to_bin(uint8_t v)
{
    return (uint8_t)((v >> 4) * 10 + (v & 0x0F));
}

static uint8_t bin_to_bcd(unsigned v)
{
    return (uint8_t)(((v / 10) << 4) | (v % 10));
}

static esp_err_t read_regs(uint8_t reg, uint8_t *buf, size_t len)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, buf, len, I2C_TIMEOUT_MS);
}

static esp_err_t write_regs(uint8_t reg, const uint8_t *buf, size_t len)
{
    uint8_t tx[8];
    if (len + 1 > sizeof(tx)) {
        return ESP_ERR_INVALID_SIZE;
    }
    tx[0] = reg;
    for (size_t i = 0; i < len; i++) {
        tx[1 + i] = buf[i];
    }
    return i2c_master_transmit(s_dev, tx, len + 1, I2C_TIMEOUT_MS);
}

/* Day of week 1..7 (Monday = 1). The DS3231 only counts it; nothing reads it. */
static unsigned weekday_of(int y, unsigned m, unsigned d)
{
    static const unsigned t[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    if (m < 3) {
        y -= 1;
    }
    unsigned w = (unsigned)((y + y / 4 - y / 100 + y / 400 + (int)t[m - 1] + (int)d) % 7);
    return w == 0 ? 7 : w; /* 0 = Sunday → 7 */
}

static esp_err_t new_bus(int sda, int scl, i2c_master_bus_handle_t *out)
{
    i2c_master_bus_config_t bus_cfg = {
        .i2c_port = -1,
        .sda_io_num = sda,
        .scl_io_num = scl,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    return i2c_new_master_bus(&bus_cfg, out);
}

/* Wiring help when the DS3231 does not answer: list whatever does. */
static int scan_bus(i2c_master_bus_handle_t bus, const char *label)
{
    int found = 0;
    for (uint8_t a = 0x08; a < 0x78; a++) {
        if (i2c_master_probe(bus, a, 20) == ESP_OK) {
            ESP_LOGW(TAG, "%s: device at 0x%02x", label, a);
            found++;
        }
    }
    if (found == 0) {
        ESP_LOGW(TAG, "%s: no I2C devices answer", label);
    }
    return found;
}

static void diagnose_wiring(void)
{
    (void)scan_bus(s_bus, "configured pins");
    i2c_del_master_bus(s_bus);
    s_bus = NULL;
    i2c_master_bus_handle_t swapped = NULL;
    if (new_bus(CONFIG_PUMP_RTC_SCL_GPIO, CONFIG_PUMP_RTC_SDA_GPIO, &swapped) != ESP_OK) {
        return;
    }
    if (i2c_master_probe(swapped, DS3231_ADDR, I2C_TIMEOUT_MS) == ESP_OK) {
        ESP_LOGW(TAG, "DS3231 answers with SDA/SCL swapped: SDA is on GPIO%d, SCL on GPIO%d",
                 CONFIG_PUMP_RTC_SCL_GPIO, CONFIG_PUMP_RTC_SDA_GPIO);
    } else {
        (void)scan_bus(swapped, "swapped pins");
    }
    i2c_del_master_bus(swapped);
}

esp_err_t pump_rtc_init(void)
{
    esp_err_t err = new_bus(CONFIG_PUMP_RTC_SDA_GPIO, CONFIG_PUMP_RTC_SCL_GPIO, &s_bus);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "I2C bus init failed: %s", esp_err_to_name(err));
        return err;
    }
    err = i2c_master_probe(s_bus, DS3231_ADDR, I2C_TIMEOUT_MS);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "DS3231 not found on SDA=%d SCL=%d (%s)", CONFIG_PUMP_RTC_SDA_GPIO,
                 CONFIG_PUMP_RTC_SCL_GPIO, esp_err_to_name(err));
        diagnose_wiring();
        return ESP_ERR_NOT_FOUND;
    }
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = DS3231_ADDR,
        .scl_speed_hz = 100000,
    };
    err = i2c_master_bus_add_device(s_bus, &dev_cfg, &s_dev);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "add device failed: %s", esp_err_to_name(err));
        return err;
    }
    /* 0x1C is the reset default: oscillator runs on battery (EOSC=0),
     * INTCN=1 so SQW is idle, both alarms off. */
    uint8_t ctrl = 0x1C;
    (void)write_regs(DS3231_REG_CONTROL, &ctrl, 1);
    s_present = true;
    ESP_LOGI(TAG, "DS3231 found on SDA=%d SCL=%d", CONFIG_PUMP_RTC_SDA_GPIO,
             CONFIG_PUMP_RTC_SCL_GPIO);
    return ESP_OK;
}

bool pump_rtc_present(void)
{
    return s_present;
}

esp_err_t pump_rtc_read(pump_civil_time_t *out)
{
    if (!s_present || !out) {
        return ESP_ERR_INVALID_STATE;
    }
    uint8_t status = 0;
    esp_err_t err = read_regs(DS3231_REG_STATUS, &status, 1);
    if (err != ESP_OK) {
        return err;
    }
    if (status & DS3231_STATUS_OSF) {
        return ESP_ERR_INVALID_STATE;
    }
    uint8_t r[7];
    err = read_regs(DS3231_REG_TIME, r, sizeof(r));
    if (err != ESP_OK) {
        return err;
    }
    out->second = bcd_to_bin(r[0] & 0x7F);
    out->minute = bcd_to_bin(r[1] & 0x7F);
    if (r[2] & 0x40) {
        /* 12-hour mode (we never set it, but a module may ship that way). */
        unsigned h = bcd_to_bin(r[2] & 0x1F);
        const bool pm = (r[2] & 0x20) != 0;
        out->hour = (h % 12) + (pm ? 12 : 0);
    } else {
        out->hour = bcd_to_bin(r[2] & 0x3F);
    }
    out->day = bcd_to_bin(r[4] & 0x3F);
    out->month = bcd_to_bin(r[5] & 0x1F);
    out->year = 2000 + bcd_to_bin(r[6]) + ((r[5] & 0x80) ? 100 : 0);
    return ESP_OK;
}

esp_err_t pump_rtc_write(const pump_civil_time_t *t)
{
    if (!s_present || !t || t->year < 2000 || t->year > 2199) {
        return ESP_ERR_INVALID_STATE;
    }
    const int yy = t->year - 2000;
    uint8_t r[7] = {
        bin_to_bcd(t->second),
        bin_to_bcd(t->minute),
        bin_to_bcd(t->hour), /* bit 6 clear = 24-hour mode */
        (uint8_t)weekday_of(t->year, t->month, t->day),
        bin_to_bcd(t->day),
        (uint8_t)(bin_to_bcd(t->month) | (yy >= 100 ? 0x80 : 0)),
        bin_to_bcd((unsigned)(yy % 100)),
    };
    esp_err_t err = write_regs(DS3231_REG_TIME, r, sizeof(r));
    if (err != ESP_OK) {
        return err;
    }
    uint8_t status = 0;
    err = read_regs(DS3231_REG_STATUS, &status, 1);
    if (err != ESP_OK) {
        return err;
    }
    status &= (uint8_t)~DS3231_STATUS_OSF;
    return write_regs(DS3231_REG_STATUS, &status, 1);
}

#endif /* CONFIG_PUMP_ENABLE_RTC */
