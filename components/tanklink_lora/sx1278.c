#include "sx1278.h"

#include <string.h>

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TAG "SX1278"

#define REG_FIFO 0x00
#define REG_OP_MODE 0x01
#define REG_FRF_MSB 0x06
#define REG_FRF_MID 0x07
#define REG_FRF_LSB 0x08
#define REG_PA_CONFIG 0x09
#define REG_LNA 0x0C
#define REG_FIFO_ADDR_PTR 0x0D
#define REG_FIFO_TX_BASE_ADDR 0x0E
#define REG_FIFO_RX_BASE_ADDR 0x0F
#define REG_FIFO_RX_CURRENT_ADDR 0x10
#define REG_IRQ_FLAGS 0x12
#define REG_RX_NB_BYTES 0x13
#define REG_PKT_SNR_VALUE 0x19
#define REG_PKT_RSSI_VALUE 0x1A
#define REG_MODEM_CONFIG_1 0x1D
#define REG_MODEM_CONFIG_2 0x1E
#define REG_PREAMBLE_MSB 0x20
#define REG_PREAMBLE_LSB 0x21
#define REG_PAYLOAD_LENGTH 0x22
#define REG_MODEM_CONFIG_3 0x26
#define REG_DIO_MAPPING_1 0x40
#define REG_VERSION 0x42
#define REG_PA_DAC 0x4D

#define MODE_LONG_RANGE_BIT 0x80
#define MODE_SLEEP 0x00
#define MODE_STDBY 0x01
#define MODE_TX 0x03
#define MODE_RX_CONTINUOUS 0x05

#define IRQ_TX_DONE 0x08
#define IRQ_RX_DONE 0x40
#define IRQ_PAYLOAD_CRC_ERROR 0x20

static spi_device_handle_t s_spi;
static bool s_ok;
static uint32_t s_freq_hz;

static esp_err_t write_reg(uint8_t reg, uint8_t val)
{
    uint8_t tx[2] = {(uint8_t)(reg | 0x80), val};
    spi_transaction_t t = {
        .length = 16,
        .tx_buffer = tx,
    };
    return spi_device_transmit(s_spi, &t);
}

static esp_err_t read_reg(uint8_t reg, uint8_t *val)
{
    uint8_t tx[2] = {(uint8_t)(reg & 0x7f), 0x00};
    uint8_t rx[2] = {0};
    spi_transaction_t t = {
        .length = 16,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    esp_err_t err = spi_device_transmit(s_spi, &t);
    if (err == ESP_OK) {
        *val = rx[1];
    }
    return err;
}

static esp_err_t write_fifo(const uint8_t *data, size_t len)
{
    if (len == 0 || len > 255) {
        return ESP_ERR_INVALID_SIZE;
    }
    uint8_t buf[256];
    buf[0] = REG_FIFO | 0x80;
    memcpy(&buf[1], data, len);
    spi_transaction_t t = {
        .length = (size_t)((len + 1) * 8),
        .tx_buffer = buf,
    };
    return spi_device_transmit(s_spi, &t);
}

static esp_err_t read_fifo(uint8_t *data, size_t len)
{
    if (len == 0 || len > 255) {
        return ESP_ERR_INVALID_SIZE;
    }
    uint8_t tx[256] = {0};
    uint8_t rx[256] = {0};
    tx[0] = REG_FIFO & 0x7f;
    spi_transaction_t t = {
        .length = (size_t)((len + 1) * 8),
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    esp_err_t err = spi_device_transmit(s_spi, &t);
    if (err == ESP_OK) {
        memcpy(data, &rx[1], len);
    }
    return err;
}

static esp_err_t set_mode(uint8_t mode)
{
    return write_reg(REG_OP_MODE, (uint8_t)(MODE_LONG_RANGE_BIT | mode));
}

static void set_frequency(uint32_t freq_hz)
{
    /* FRF = freq / FSTEP, FSTEP = 32e6 / 2^19 */
    uint64_t frf = ((uint64_t)freq_hz << 19) / 32000000ULL;
    write_reg(REG_FRF_MSB, (uint8_t)((frf >> 16) & 0xff));
    write_reg(REG_FRF_MID, (uint8_t)((frf >> 8) & 0xff));
    write_reg(REG_FRF_LSB, (uint8_t)(frf & 0xff));
}

uint8_t sx1278_read_version(void)
{
    uint8_t v = 0;
    if (s_ok) {
        (void)read_reg(REG_VERSION, &v);
    }
    return v;
}

esp_err_t sx1278_init(const sx1278_config_t *cfg)
{
    if (!cfg) {
        return ESP_ERR_INVALID_ARG;
    }
    s_ok = false;

    gpio_config_t io = {
        .pin_bit_mask = 1ULL << cfg->pin_rst,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io));
    gpio_set_level(cfg->pin_rst, 0);
    esp_rom_delay_us(1000);
    gpio_set_level(cfg->pin_rst, 1);
    vTaskDelay(pdMS_TO_TICKS(10));

    spi_bus_config_t bus = {
        .mosi_io_num = cfg->pin_mosi,
        .miso_io_num = cfg->pin_miso,
        .sclk_io_num = cfg->pin_sck,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 256,
    };
    esp_err_t err = spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "spi_bus_initialize: %s", esp_err_to_name(err));
        return err;
    }

    spi_device_interface_config_t dev = {
        .clock_speed_hz = 8 * 1000 * 1000,
        .mode = 0,
        .spics_io_num = cfg->pin_cs,
        .queue_size = 1,
        .flags = 0,
    };
    err = spi_bus_add_device(SPI2_HOST, &dev, &s_spi);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "spi_bus_add_device: %s", esp_err_to_name(err));
        return err;
    }

    set_mode(MODE_SLEEP);
    vTaskDelay(pdMS_TO_TICKS(10));
    set_mode(MODE_SLEEP); /* enter LoRa sleep */

    uint8_t ver = 0;
    err = read_reg(REG_VERSION, &ver);
    if (err != ESP_OK || ver == 0x00 || ver == 0xff) {
        ESP_LOGE(TAG, "SX1278 not detected (ver=0x%02x)", ver);
        return ESP_ERR_NOT_FOUND;
    }
    s_freq_hz = cfg->freq_hz ? cfg->freq_hz : 433000000UL;
    ESP_LOGI(TAG, "SX1278 version 0x%02x freq=%lu", ver, (unsigned long)s_freq_hz);

    set_mode(MODE_STDBY);
    set_frequency(s_freq_hz);

    /* PA boost, ~14 dBm starting point */
    write_reg(REG_PA_CONFIG, 0x8F);
    write_reg(REG_PA_DAC, 0x84);
    write_reg(REG_LNA, 0x23);

    /* BW 125 kHz, CR 4/5, explicit header */
    write_reg(REG_MODEM_CONFIG_1, 0x72);
    /* SF7, CRC on */
    write_reg(REG_MODEM_CONFIG_2, 0x74);
    write_reg(REG_MODEM_CONFIG_3, 0x04);
    write_reg(REG_PREAMBLE_MSB, 0x00);
    write_reg(REG_PREAMBLE_LSB, 0x08);
    write_reg(REG_FIFO_TX_BASE_ADDR, 0x00);
    write_reg(REG_FIFO_RX_BASE_ADDR, 0x00);
    write_reg(REG_IRQ_FLAGS, 0xFF);

    s_ok = true;
    return ESP_OK;
}

void sx1278_sleep(void)
{
    if (!s_ok) {
        return;
    }
    set_mode(MODE_SLEEP);
}

esp_err_t sx1278_send(const uint8_t *data, size_t len, uint32_t timeout_ms)
{
    if (!s_ok || !data || len == 0 || len > 255) {
        return ESP_ERR_INVALID_ARG;
    }
    set_mode(MODE_STDBY);
    write_reg(REG_FIFO_ADDR_PTR, 0x00);
    write_fifo(data, len);
    write_reg(REG_PAYLOAD_LENGTH, (uint8_t)len);
    write_reg(REG_IRQ_FLAGS, 0xFF);
    set_mode(MODE_TX);

    const TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(timeout_ms);
    while (xTaskGetTickCount() < deadline) {
        uint8_t flags = 0;
        if (read_reg(REG_IRQ_FLAGS, &flags) == ESP_OK && (flags & IRQ_TX_DONE)) {
            write_reg(REG_IRQ_FLAGS, 0xFF);
            set_mode(MODE_STDBY);
            return ESP_OK;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    set_mode(MODE_STDBY);
    return ESP_ERR_TIMEOUT;
}

esp_err_t sx1278_start_rx(void)
{
    if (!s_ok) {
        return ESP_ERR_INVALID_STATE;
    }
    set_mode(MODE_STDBY);
    write_reg(REG_FIFO_ADDR_PTR, 0x00);
    write_reg(REG_IRQ_FLAGS, 0xFF);
    /* DIO0 = RxDone */
    write_reg(REG_DIO_MAPPING_1, 0x00);
    return set_mode(MODE_RX_CONTINUOUS);
}

esp_err_t sx1278_poll_recv_ex(uint8_t *buf, size_t buf_len, size_t *out_len,
                              int16_t *rssi_dbm, int8_t *snr_db)
{
    if (!s_ok || !buf || !out_len) {
        return ESP_ERR_INVALID_ARG;
    }
    *out_len = 0;
    uint8_t flags = 0;
    if (read_reg(REG_IRQ_FLAGS, &flags) != ESP_OK) {
        return ESP_FAIL;
    }
    if (!(flags & IRQ_RX_DONE)) {
        return ESP_ERR_NOT_FOUND;
    }
    if (flags & IRQ_PAYLOAD_CRC_ERROR) {
        write_reg(REG_IRQ_FLAGS, 0xFF);
        return ESP_ERR_INVALID_CRC;
    }
    uint8_t cur = 0;
    uint8_t n = 0;
    read_reg(REG_FIFO_RX_CURRENT_ADDR, &cur);
    read_reg(REG_RX_NB_BYTES, &n);
    write_reg(REG_FIFO_ADDR_PTR, cur);
    if (n == 0) {
        write_reg(REG_IRQ_FLAGS, 0xFF);
        return ESP_ERR_NOT_FOUND;
    }
    if (n > buf_len) {
        write_reg(REG_IRQ_FLAGS, 0xFF);
        return ESP_ERR_INVALID_SIZE;
    }

    /* Snapshot link quality before clearing IRQ / reading FIFO. */
    uint8_t pkt_rssi = 0;
    uint8_t pkt_snr = 0;
    (void)read_reg(REG_PKT_RSSI_VALUE, &pkt_rssi);
    (void)read_reg(REG_PKT_SNR_VALUE, &pkt_snr);

    esp_err_t err = read_fifo(buf, n);
    write_reg(REG_IRQ_FLAGS, 0xFF);
    if (err == ESP_OK) {
        *out_len = n;
        if (rssi_dbm) {
            /* Semtech: HF (≥862 MHz) offset −157; LF (433/470) offset −164. */
            const int offset = (s_freq_hz >= 862000000UL) ? -157 : -164;
            *rssi_dbm = (int16_t)(offset + (int)pkt_rssi);
        }
        if (snr_db) {
            /* Signed SNR in 0.25 dB units → dB. */
            int8_t snr_raw = (int8_t)pkt_snr;
            *snr_db = (int8_t)(snr_raw / 4);
        }
    }
    return err;
}

esp_err_t sx1278_poll_recv(uint8_t *buf, size_t buf_len, size_t *out_len)
{
    return sx1278_poll_recv_ex(buf, buf_len, out_len, NULL, NULL);
}
