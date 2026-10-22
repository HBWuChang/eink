#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void epd_driver_init(void);

/*
 * image: 768 x 552, 2 bits/pixel, 4 pixels/byte, MSB first.
 *        color: 0=black, 1=white, 2=yellow, 3=red.
 *        size: 105984 bytes.
 *
 * Blocking. Call from a dedicated task, not from the BLE host task.
 */
bool epd_display(const uint8_t *image);

#ifdef __cplusplus
}
#endif
