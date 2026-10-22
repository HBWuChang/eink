#include "ble_server.h"

#include <inttypes.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_att.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "epd.h"

#define EPD_WIDTH       768
#define EPD_HEIGHT      552
#define EPD_ROW_BYTES   (EPD_WIDTH / 4)
#define EPD_IMAGE_BYTES (EPD_ROW_BYTES * EPD_HEIGHT)

#define BLE_DEVICE_NAME "HUAWEI-EPD-A0"
#define INFO_STRING     "A0-EPD 1.0 768x552"

static const char *TAG = "ble_epd";

/* Service: e1d00001-7a3b-4c5d-8e9f-0123456789ab */
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x9f, 0x8e,
                     0x5d, 0x4c, 0x3b, 0x7a, 0x01, 0x00, 0xd0, 0xe1);
/* Control: e1d00002-... */
static const ble_uuid128_t s_ctrl_uuid =
    BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x9f, 0x8e,
                     0x5d, 0x4c, 0x3b, 0x7a, 0x02, 0x00, 0xd0, 0xe1);
/* Status: e1d00003-... */
static const ble_uuid128_t s_status_uuid =
    BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x9f, 0x8e,
                     0x5d, 0x4c, 0x3b, 0x7a, 0x03, 0x00, 0xd0, 0xe1);
/* Info: e1d00004-... */
static const ble_uuid128_t s_info_uuid =
    BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x9f, 0x8e,
                     0x5d, 0x4c, 0x3b, 0x7a, 0x04, 0x00, 0xd0, 0xe1);

enum {
    CMD_START = 0x01,
    CMD_DATA = 0x02,
    CMD_COMMIT = 0x03,
    CMD_ABORT = 0x04,
};

enum {
    ST_IDLE = 0,
    ST_RECEIVING = 1,
    ST_REFRESHING = 2,
    ST_DONE = 3,
    ST_ERROR = 4,
};

enum {
    ERR_NONE = 0,
    ERR_LENGTH = 1,
    ERR_OFFSET = 2,
    ERR_CRC = 3,
    ERR_BUSY = 4,
    ERR_REFRESH = 5,
    ERR_COMMAND = 6,
    ERR_STATE = 7,
};

static uint16_t s_ctrl_handle;
static uint16_t s_status_handle;
static uint16_t s_info_handle;

static uint8_t s_own_addr_type;

static uint8_t s_image[EPD_IMAGE_BYTES];
static volatile uint32_t s_received;
static volatile uint32_t s_expected;
static volatile uint32_t s_expected_crc;
static volatile uint8_t s_state = ST_IDLE;
static volatile uint8_t s_error = ERR_NONE;

static QueueHandle_t s_display_queue;

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg);
static int gap_event(struct ble_gap_event *event, void *arg);
static void advertise(void);

static const struct ble_gatt_svc_def s_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &s_ctrl_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_ctrl_handle,
            },
            {
                .uuid = &s_status_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_READ,
                .val_handle = &s_status_handle,
            },
            {
                .uuid = &s_info_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_READ,
                .val_handle = &s_info_handle,
            },
            {0},
        },
    },
    {0},
};

static uint32_t ble_get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void ble_put_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static uint32_t crc32_ieee(const uint8_t *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i) {
        crc ^= data[i];
        for (int b = 0; b < 8; ++b) {
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(crc & 1));
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

static void fill_status(uint8_t out[10])
{
    out[0] = s_state;
    out[1] = s_error;
    ble_put_le32(&out[2], s_received);
    ble_put_le32(&out[6], s_expected);
}

static void set_error(uint8_t code)
{
    s_state = ST_ERROR;
    s_error = code;
}

static int handle_control(const uint8_t *buf, uint16_t len)
{
    if (len < 1) {
        set_error(ERR_COMMAND);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    switch (buf[0]) {
    case CMD_START: {
        if (len != 9) {
            set_error(ERR_LENGTH);
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (s_state == ST_REFRESHING) {
            set_error(ERR_BUSY);
            return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }

        const uint32_t total = ble_get_le32(&buf[1]);
        const uint32_t crc = ble_get_le32(&buf[5]);
        if (total != EPD_IMAGE_BYTES) {
            set_error(ERR_LENGTH);
            return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }

        s_expected = total;
        s_expected_crc = crc;
        s_received = 0;
        s_error = ERR_NONE;
        s_state = ST_RECEIVING;
        ESP_LOGI(TAG, "START %" PRIu32 " bytes, crc=%08" PRIx32, total, crc);
        return 0;
    }

    case CMD_DATA: {
        if (len < 6) {
            set_error(ERR_LENGTH);
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (s_state != ST_RECEIVING) {
            set_error(ERR_STATE);
            return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }

        const uint32_t offset = ble_get_le32(&buf[1]);
        const uint16_t payload = (uint16_t)(len - 5);
        if (offset != s_received ||
            payload > EPD_IMAGE_BYTES - s_received) {
            set_error(ERR_OFFSET);
            return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }

        memcpy(&s_image[offset], &buf[5], payload);
        s_received += payload;

        return 0;
    }

    case CMD_COMMIT: {
        if (len != 1) {
            set_error(ERR_LENGTH);
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (s_state != ST_RECEIVING || s_received != s_expected) {
            set_error(ERR_LENGTH);
            return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }

        const uint32_t crc = crc32_ieee(s_image, EPD_IMAGE_BYTES);
        if (crc != s_expected_crc) {
            ESP_LOGE(TAG, "CRC mismatch: got %08" PRIx32 ", want %08" PRIx32,
                     crc, s_expected_crc);
            set_error(ERR_CRC);
            return 0;
        }

        s_state = ST_REFRESHING;
        s_error = ERR_NONE;
    
        const uint8_t token = 1;
        if (xQueueSend(s_display_queue, &token, 0) != pdTRUE) {
            set_error(ERR_BUSY);
            return 0;
        }

        ESP_LOGI(TAG, "COMMIT accepted; refresh queued");
        return 0;
    }

    case CMD_ABORT:
        if (s_state == ST_REFRESHING) {
            set_error(ERR_BUSY);
            return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }
        s_received = 0;
        s_expected = 0;
        s_state = ST_IDLE;
        s_error = ERR_NONE;
            ESP_LOGI(TAG, "ABORT");
        return 0;

    default:
        set_error(ERR_COMMAND);
        return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    }
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)arg;

    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
        if (attr_handle == s_status_handle) {
            uint8_t status[10];
            fill_status(status);
            return os_mbuf_append(ctxt->om, status, sizeof(status)) == 0
                       ? 0
                       : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (attr_handle == s_info_handle) {
            return os_mbuf_append(ctxt->om, INFO_STRING,
                                  sizeof(INFO_STRING) - 1) == 0
                       ? 0
                       : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        return BLE_ATT_ERR_READ_NOT_PERMITTED;

    case BLE_GATT_ACCESS_OP_WRITE_CHR:
        if (attr_handle != s_ctrl_handle) {
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        } else {
            uint8_t buf[512];
            uint16_t len = 0;
            int rc = ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len);
            if (rc != 0) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            return handle_control(buf, len);
        }

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

static int gatt_init(void)
{
    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(s_services);
    if (rc != 0) {
        return rc;
    }
    rc = ble_gatts_add_svcs(s_services);
    if (rc != 0) {
        return rc;
    }
    return 0;
}

static void advertise(void)
{
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    const char *name = ble_svc_gap_device_name();
    fields.name = (uint8_t *)name;
    fields.name_len = (uint8_t)strlen(name);
    fields.name_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv fields failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields rsp = {0};
    rsp.uuids128 = (ble_uuid128_t[]){s_svc_uuid};
    rsp.num_uuids128 = 1;
    rsp.uuids128_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        ESP_LOGW(TAG, "scan response fields failed: %d", rc);
    }

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_FAST_INTERVAL1_MIN;
    params.itvl_max = BLE_GAP_ADV_FAST_INTERVAL1_MIN;

    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER,
                           &params, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "advertise failed: %d", rc);
    }
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            ESP_LOGI(TAG, "connected, handle=%d", event->connect.conn_handle);
        } else {
            ESP_LOGW(TAG, "connect failed: %d", event->connect.status);
            advertise();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnected, reason=%d", event->disconnect.reason);
        if (s_state == ST_RECEIVING) {
            s_state = ST_IDLE;
            s_received = 0;
            s_expected = 0;
            s_error = ERR_NONE;
        }
        advertise();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        return 0;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU=%d", event->mtu.value);
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "subscribe attr=%d notify=%d",
                 event->subscribe.attr_handle,
                 event->subscribe.cur_notify);
        return 0;

    default:
        return 0;
    }
}

static void host_task(void *param)
{
    (void)param;
    ESP_LOGI(TAG, "NimBLE host task start");
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static void ble_on_reset(int reason)
{
    ESP_LOGE(TAG, "NimBLE reset: %d", reason);
}

static void ble_on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ensure_addr failed: %d", rc);
        return;
    }

    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "infer addr failed: %d", rc);
        return;
    }

    advertise();
}

static void display_task(void *arg)
{
    (void)arg;
    uint8_t token;

    for (;;) {
        if (xQueueReceive(s_display_queue, &token, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        ESP_LOGI(TAG, "EPD refresh start");
        const bool ok = epd_display(s_image);

        s_state = ok ? ST_DONE : ST_ERROR;
        s_error = ok ? ERR_NONE : ERR_REFRESH;
    
        if (ok) {
            ESP_LOGI(TAG, "EPD refresh done");
        } else {
            ESP_LOGE(TAG, "EPD refresh failed");
        }
    }
}

/* From NimBLE's store/config component. */
void ble_store_config_init(void);

void ble_server_start(void)
{
    s_display_queue = xQueueCreate(1, sizeof(uint8_t));
    if (s_display_queue == NULL) {
        ESP_LOGE(TAG, "queue create failed");
        return;
    }

    xTaskCreate(display_task, "epd_task", 6144, NULL, 5, NULL);

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(err));
        return;
    }

    ble_hs_cfg.reset_cb = ble_on_reset;
    ble_hs_cfg.sync_cb = ble_on_sync;

    ble_svc_gap_device_name_set(BLE_DEVICE_NAME);

    if (gatt_init() != 0) {
        ESP_LOGE(TAG, "GATT init failed");
        return;
    }

    ble_store_config_init();
    nimble_port_freertos_init(host_task);
}
