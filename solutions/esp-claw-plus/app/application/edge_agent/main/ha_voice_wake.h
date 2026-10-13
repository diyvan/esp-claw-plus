/*
 * HA AI Panel - WakeNet wake-word listener.
 *
 * A single background task owns the microphone for as long as no Lua capture
 * session needs it (see ha_voice_arbiter). It opens the board ADC at the I2S
 * native format (48 kHz / 2 ch / 16-bit), software-resamples it down to the
 * 16 kHz mono stream the AFE requires, and runs a WakeNet-only AFE pipeline.
 * On detection it drops a trigger file under CLAW_PATH_DATA and hands the mic
 * over to the capture side; voice_ptt.lua polls that file to start recording.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Callback fired from the listener task on each wake-word detection
 *  (wake word only; the push-to-talk button does not go through here). */
typedef void (*ha_voice_wake_event_cb_t)(void);

/**
 * @brief Register the wake-word callback. Pass NULL to clear.
 *
 * Call before ha_voice_wake_start() (or accept the benign race afterwards).
 */
void ha_voice_wake_set_callback(ha_voice_wake_event_cb_t cb);

/**
 * @brief Start the wake-word listener task. Idempotent.
 *
 * @return ESP_OK on success, or an error code if the task could not be created.
 */
esp_err_t ha_voice_wake_start(void);

#ifdef __cplusplus
}
#endif
