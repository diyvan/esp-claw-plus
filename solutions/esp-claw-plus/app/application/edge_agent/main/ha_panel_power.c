/*
 * HA AI Panel - PWR side-button (standby toggle) input. See ha_panel_power.h.
 */
#include "ha_panel_power.h"

#include <stdbool.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "ha_panel_pwr";

/* PWR button, active HIGH (see ha_panel_power.h for the schematic trace). */
#define HA_POWER_KEY_GPIO         49
/* Consecutive stable samples required to accept a level, in 10 ms task ticks.
 * Covers the mechanical bounce plus the level shifter's slow edge. */
#define HA_POWER_DEBOUNCE_TICKS   3
/* Presses shorter than this are single clicks; anything longer is a long press
 * and is ignored here, so it can reach the AXP2101's 6s PWRON power-off. */
#define HA_POWER_LONG_PRESS_MS    1000

static bool s_ready;
static bool s_last_raw;       /* last raw sample, true = pressed */
static bool s_stable;         /* debounced level, true = pressed */
static int  s_stable_ticks;   /* samples s_last_raw has been unchanged */
static bool s_pressed;        /* a debounced press is in progress */
static int64_t s_press_start_us;

esp_err_t ha_panel_power_init(void)
{
    if (s_ready) {
        return ESP_OK;
    }

    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << HA_POWER_KEY_GPIO,
        .mode = GPIO_MODE_INPUT,
        /* The board already pulls PWR_KEY up with 10K; enable the internal
         * pull-up as well so the pin never floats if that resistor is absent. */
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t err = gpio_config(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "gpio_config(%d) failed: %s", HA_POWER_KEY_GPIO, esp_err_to_name(err));
        return err;
    }

    s_last_raw = gpio_get_level(HA_POWER_KEY_GPIO) != 0;
    s_stable = s_last_raw;
    s_stable_ticks = HA_POWER_DEBOUNCE_TICKS;
    s_ready = true;

    ESP_LOGI(TAG, "PWR key on GPIO%d ready (level=%d)", HA_POWER_KEY_GPIO, (int)s_last_raw);
    return ESP_OK;
}

bool ha_panel_power_poll_press(void)
{
    if (!s_ready) {
        return false;
    }

    const bool raw = gpio_get_level(HA_POWER_KEY_GPIO) != 0;

    if (raw != s_last_raw) {
        s_last_raw = raw;
        s_stable_ticks = 0;
        return false;   /* still settling: wait for the debounce window */
    }
    if (s_stable_ticks < HA_POWER_DEBOUNCE_TICKS) {
        s_stable_ticks++;
        return false;
    }
    if (s_stable == raw) {
        return false;   /* level already accepted, no edge */
    }
    s_stable = raw;

    if (raw) {
        /* Press edge: a click is only decided when the key is released, so a
         * long press (PMIC power-off) never reaches the caller. */
        s_pressed = true;
        s_press_start_us = esp_timer_get_time();
        return false;
    }

    /* Release edge. */
    if (!s_pressed) {
        return false;   /* release without a debounced press (boot seed) */
    }
    s_pressed = false;

    const int64_t held_ms = (esp_timer_get_time() - s_press_start_us) / 1000;
    if (held_ms >= HA_POWER_LONG_PRESS_MS) {
        ESP_LOGI(TAG, "long press %lld ms -> ignored, waiting for PWRON result",
                 (long long)held_ms);
        return false;
    }
    ESP_LOGD(TAG, "single click %lld ms", (long long)held_ms);
    return true;
}
