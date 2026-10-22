#include "esp_err.h"
#include "esp_log.h"
#include "nvs_flash.h"

#include "ble_server.h"
#include "epd.h"

static const char *TAG = "main";

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    /*
     * The EPD SPI bus is initialized here, but the panel is refreshed only
     * after a complete image has been received over BLE.
     * Wi-Fi is not initialized.
     */
    epd_driver_init();
    ble_server_start();

    ESP_LOGI(TAG, "ready; BLE name=%s", "HUAWEI-EPD-A0");
}
