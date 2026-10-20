/*
 * HA AI Panel - settings overlay (header button + live sub-menus).
 *
 * Adds a "设置" button on the right of the panel header. Tapping it opens a
 * full-screen overlay with a menu that leads to three on-device controls:
 *
 *   - 音量:   slider -> NVS app_config.voice_volume (persisted) + live codec
 *             output volume, and re-published to ha_voice_runtime.json so the
 *             voice Lua TTS plays the next reply at the new volume.
 *   - 亮度:   slider -> LEDC backlight duty, persisted in app_config.
 *   - 网络:   Wi-Fi status + SSID/password editor (on-screen keyboard) with an
 *             AP scan picker. Saving writes app_config.wifi_ssid/wifi_password
 *             to NVS and applies the STA config live via wifi_manager, so the
 *             change takes effect without a reboot.
 *   - 系统负载: CPU usage / idle / RAM / PSRAM / task count sampled from
 *             FreeRTOS run-time stats + heap_caps.
 *
 * The overlay is a child of the panel screen, so the panel's deferred CJK font
 * pass covers it automatically (no font plumbing needed here).
 *
 * Locking contract: attach/poll run on the panel task with the LVGL lock held;
 * the slider callbacks also run there (inside lv_timer_handler). Only
 * ha_panel_settings_commit_pending() writes NVS and must be called with the
 * lock released.
 */
#pragma once

#include <stdbool.h>

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Build the header settings button and the (hidden) settings overlay.
 *
 * @param header  Panel header bar (the button is aligned to its right edge).
 * @param screen  Panel root screen (the overlay covers it and paints on top).
 *
 * Call once, after the main UI exists; also restores the persisted brightness.
 */
void ha_panel_settings_attach(lv_obj_t *header, lv_obj_t *screen);

/**
 * @brief Refresh live settings content (system load). No-op unless the load
 *        sub-menu is open. Call with the LVGL lock held; internally throttled.
 */
void ha_panel_settings_poll(void);

/**
 * @brief Persist pending volume/brightness slider changes to NVS.
 *
 * MUST be called with the LVGL lock RELEASED (NVS/flash I/O). Returns true when
 * voice_volume changed, i.e. the caller must republish the runtime config JSON.
 */
bool ha_panel_settings_commit_pending(void);

/**
 * @brief Turn the LCD backlight on (restore the current brightness) or off,
 *        for the standby toggle.
 *
 * Only touches the LEDC duty; the persisted brightness and the "亮度" slider
 * value are left untouched, so waking restores the level the user had set.
 * Safe to call without the LVGL lock (plain LEDC write, like the restore in
 * ha_panel_settings_attach()).
 */
void ha_panel_settings_set_backlight_enabled(bool enabled);

/**
 * @brief Run deferred, blocking network work requested from the "网络" sub-menu
 *        (Wi-Fi scan / STA apply + NVS save).
 *
 * MUST be called with the LVGL lock RELEASED: the scan/ap-connect calls block
 * for seconds and must not stall lv_timer_handler. Results are published into
 * module state and rendered by ha_panel_settings_poll() on a later lock-held
 * tick.
 */
void ha_panel_settings_service(void);

#ifdef __cplusplus
}
#endif
