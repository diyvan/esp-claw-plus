/*
 * HA AI Panel - PWR side-button (standby toggle) input.
 *
 * The board's PWR button is not a plain GPIO switch: it drives the AXP2101
 * PWRON pin and, through a BSS138 level shifter (PWR_ON -> T2 -> PWR_KEY),
 * lands on ESP32-P4 GPIO49. The polarity is active HIGH, i.e.
 *
 *   released -> PWR_ON high -> T2 on  -> PWR_KEY pulled to GND -> GPIO49 = 0
 *   pressed  -> PWR_ON low  -> T2 off -> PWR_KEY pulled to 3V3 -> GPIO49 = 1
 *
 * RST is a hardware reset (not a GPIO) and BOOT (GPIO35) is used as the PTT
 * key, so only PWR is available for a standby toggle.
 *
 * Driving it by polling (instead of an ISR) keeps the shared GPIO ISR service
 * untouched and needs no extra component: the panel task already wakes every
 * HA_PANEL_TASK_PERIOD_MS and calls ha_panel_power_poll_press().
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Configure the PWR button GPIO for polling. Idempotent.
 *
 * Seeds the debounce state from the level read at init, so the press that
 * powered the board on (still held while the panel boots) is not reported as a
 * click. Non-fatal: on failure poll_press() stays a no-op.
 */
esp_err_t ha_panel_power_init(void);

/**
 * @brief Poll the PWR button; returns true once per debounced *single click*.
 *
 * Must be called periodically (the panel task tick) from a single task. A click
 * is reported when the key is released after a short press; a long press is
 * deliberately swallowed (it is left to the AXP2101's PWRON logic, which powers
 * the board off after 6s), so holding the key never toggles anything and never
 * repeats.
 */
bool ha_panel_power_poll_press(void);

#ifdef __cplusplus
}
#endif
