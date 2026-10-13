/*
 * HA AI Panel - application-layer LVGL panel.
 *
 * The panel is the on-device UI of the solution and lives inside the esp-claw
 * application layer (it does not replace it). It takes the board display over
 * through the display_arbiter and renders a three-page menu (Home Assistant /
 * voice / device info) navigated by a bottom touch tab bar:
 *
 *   - Panel page: Home Assistant link state (configured / not configured and
 *     the base URL). Entity cards replace this once the HA WebSocket client
 *     exists; there is no mock data.
 *   - Voice page: wake status + last transcript + last agent reply, mirrored
 *     from the files the voice Lua skills write.
 *   - Info page: ESP-Claw system status grouped as network / LLM / IM / voice
 *     state, read from the same NVS-backed app_config the Web UI writes plus
 *     the live WiFi status polled from wifi_manager.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize the LVGL panel and start rendering the menu pages.
 *
 * Must be called after esp_board_manager_init() (display + touch devices are
 * taken from the board manager). The display is acquired as
 * DISPLAY_ARBITER_OWNER_LUA, which silences the emote/expression engine.
 */
esp_err_t ha_panel_start(void);

/**
 * @brief Publish the HA/voice configuration to the writable storage root as
 *        JSON (`ha_voice_runtime.json`) and refresh the device-info page.
 *
 * The voice Lua skills read this file to pick up the ASR/TTS endpoints and the
 * Home Assistant enablement flag. Called by the panel once the filesystem is
 * mounted and again whenever the user saves configuration from the Web UI, so
 * no Lua/C configuration binding is needed (same file-bridge idea as the
 * voice transcript mirror).
 *
 * Safe to call before the panel starts (returns ESP_ERR_INVALID_STATE).
 */
esp_err_t ha_panel_publish_runtime_config(void);

#ifdef __cplusplus
}
#endif
