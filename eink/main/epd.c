#include "epd.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define PIN_MOSI 11
#define PIN_SCK  12
#define PIN_CS   10
#define PIN_DC    9
#define PIN_RST   8
#define PIN_BUSY 13

#define PANEL_WIDTH   768
#define PANEL_HEIGHT  552
#define ROW_BYTES     (PANEL_WIDTH / 4)

static const char *TAG = "epd";
static spi_device_handle_t s_spi;

static void epd_send(uint8_t value, bool is_data)
{
    gpio_set_level(PIN_DC, is_data ? 1 : 0);
    gpio_set_level(PIN_CS, 0);

    spi_transaction_t t = {0};
    t.flags = SPI_TRANS_USE_TXDATA;
    t.length = 8;
    t.tx_data[0] = value;
    ESP_ERROR_CHECK(spi_device_polling_transmit(s_spi, &t));

    gpio_set_level(PIN_CS, 1);
}

static void epd_cmd(uint8_t value) { epd_send(value, false); }
static void epd_data(uint8_t value) { epd_send(value, true); }

static bool wait_ready(uint32_t timeout_ms)
{
    const int64_t start = esp_timer_get_time();
    while (gpio_get_level(PIN_BUSY) == 0) {
        if ((esp_timer_get_time() - start) / 1000 > timeout_ms) {
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    return true;
}

static bool wait_busy_cycle(uint32_t timeout_ms)
{
    const int64_t start = esp_timer_get_time();
    while (gpio_get_level(PIN_BUSY) == 1) {
        if ((esp_timer_get_time() - start) / 1000 > 2000) {
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    return wait_ready(timeout_ms);
}

static void epd_window(uint16_t y0, uint16_t y1)
{
    epd_cmd(0x83);
    epd_data(0x00);
    epd_data(0x00);
    epd_data(0x02);
    epd_data(0xFF);
    epd_data((uint8_t)(y0 >> 8));
    epd_data((uint8_t)(y0 & 0xFF));
    epd_data((uint8_t)(y1 >> 8));
    epd_data((uint8_t)(y1 & 0xFF));
    epd_data(0x01);
}

static bool epd_reset(void)
{
    gpio_set_level(PIN_CS, 1);
    gpio_set_level(PIN_RST, 1);
    vTaskDelay(pdMS_TO_TICKS(20));

    gpio_set_level(PIN_RST, 0);
    vTaskDelay(pdMS_TO_TICKS(40));

    gpio_set_level(PIN_RST, 1);
    vTaskDelay(pdMS_TO_TICKS(50));

    if (!wait_ready(10000)) {
        return false;
    }

    vTaskDelay(pdMS_TO_TICKS(30));
    return true;
}

static bool epd_init_panel(void)
{
    if (!epd_reset()) {
        ESP_LOGE(TAG, "reset timeout");
        return false;
    }

    epd_cmd(0x00);
    epd_data(0x0B);

    epd_cmd(0x61);
    epd_data(0x03);
    epd_data(0x00);
    epd_data(0x02);
    epd_data(0x28);
    return true;
}

static bool epd_refresh(void)
{
    epd_window(0, PANEL_HEIGHT - 1);

    ESP_LOGI(TAG, "power on");
    epd_cmd(0x04);
    if (!wait_busy_cycle(60000)) {
        ESP_LOGE(TAG, "power-on BUSY timeout");
        return false;
    }

    ESP_LOGI(TAG, "refresh");
    epd_cmd(0x12);
    epd_data(0x00);
    if (!wait_busy_cycle(180000)) {
        ESP_LOGE(TAG, "refresh BUSY timeout");
        return false;
    }

    ESP_LOGI(TAG, "power off");
    epd_cmd(0x02);
    epd_data(0x00);
    if (!wait_busy_cycle(60000)) {
        ESP_LOGE(TAG, "power-off BUSY timeout");
        return false;
    }

    epd_cmd(0x07);
    epd_data(0xA5);
    vTaskDelay(pdMS_TO_TICKS(200));
    return true;
}

static void gpio_init(void)
{
    gpio_config_t out = {
        .pin_bit_mask = (1ULL << PIN_CS) |
                        (1ULL << PIN_DC) |
                        (1ULL << PIN_RST),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&out));

    gpio_set_level(PIN_CS, 1);
    gpio_set_level(PIN_DC, 0);
    gpio_set_level(PIN_RST, 1);

    gpio_config_t in = {
        .pin_bit_mask = 1ULL << PIN_BUSY,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&in));
}

static void spi_init(void)
{
    spi_bus_config_t bus = {
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = -1,
        .sclk_io_num = PIN_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4,
    };
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_DISABLED));

    spi_device_interface_config_t dev = {
        .clock_speed_hz = 1000 * 1000,
        .mode = 0,
        .spics_io_num = -1,
        .queue_size = 1,
    };
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &dev, &s_spi));
}

void epd_driver_init(void)
{
    gpio_init();
    spi_init();
}

bool epd_display(const uint8_t *image)
{
    if (image == NULL) {
        return false;
    }
    if (!epd_init_panel()) {
        return false;
    }

    for (uint16_t y = 0; y < PANEL_HEIGHT; ++y) {
        const uint16_t physical = (y < 276)
                                      ? (uint16_t)(y * 2)
                                      : (uint16_t)(551 - 2 * (y - 276));
        epd_window(physical, physical);
        epd_cmd(0x10);

        const uint8_t *row = image + (size_t)y * ROW_BYTES;
        for (uint16_t i = 0; i < ROW_BYTES; ++i) {
            epd_data(row[i]);
        }

        if ((y & 7) == 7) {
            vTaskDelay(pdMS_TO_TICKS(1));
        }
    }

    return epd_refresh();
}
