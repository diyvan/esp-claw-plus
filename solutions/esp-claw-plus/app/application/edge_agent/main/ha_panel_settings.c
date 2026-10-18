/*
 * HA AI Panel - settings overlay implementation. See ha_panel_settings.h.
 */
#include "ha_panel_settings.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_config.h"
#include "esp_board_manager_includes.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "wifi_manager.h"

static const char *TAG = "ha_settings";

/* Palette kept in sync with ha_panel.c (the overlay covers the panel). */
#define SET_COLOR_BG        0x111418
#define SET_COLOR_HEADER    0x1F6FEB
#define SET_COLOR_BTN       0x1857C0
#define SET_COLOR_CARD      0x1E2329
#define SET_COLOR_ACCENT    0x60A5FA
#define SET_COLOR_TEXT      0xF5F5F5
#define SET_COLOR_TEXT_DIM  0x9CA3AF
#define SET_COLOR_ON        0x4ADE80

#define SET_VOL_DEFAULT     80
#define SET_BRIGHT_DEFAULT  100

/* System-load sampling: refresh at most every N panel poll ticks (10ms each). */
#define SET_LOAD_REFRESH_TICKS  50
#define SET_MAX_TASKS           48

/* Network sub-menu: limits mirror wifi_manager/app_config validation
 * (SSID 1..31 chars, WPA2 passphrase empty or 8..63 chars). */
#define SET_NET_SSID_MAX        32
#define SET_NET_PASS_MAX        63
#define SET_NET_SCAN_MAX        12
#define SET_NET_KB_HEIGHT       190

typedef enum {
    SET_VIEW_MENU = 0,
    SET_VIEW_VOLUME,
    SET_VIEW_BRIGHTNESS,
    SET_VIEW_LOAD,
    SET_VIEW_NETWORK,
    SET_VIEW_COUNT,
} set_view_t;

static const char *const SET_VIEW_TITLES[SET_VIEW_COUNT] = {
    "设置", "音量", "亮度", "系统负载", "网络",
};

static bool s_built;
static lv_obj_t *s_overlay;
static lv_obj_t *s_view_title;
static lv_obj_t *s_views[SET_VIEW_COUNT];
static set_view_t s_view = SET_VIEW_MENU;

/* Slider value labels. */
static lv_obj_t *s_vol_value;
static lv_obj_t *s_bright_value;

/* System-load labels. */
static lv_obj_t *s_load_cpu_value;
static lv_obj_t *s_load_idle_value;
static lv_obj_t *s_load_ram_value;
static lv_obj_t *s_load_psram_value;
static lv_obj_t *s_load_tasks_value;

/* Pending slider values, consumed by ha_panel_settings_commit_pending().
 * s_*_dirty are only touched on the panel task (slider cb + commit), so no
 * cross-task race despite the lock being released around the NVS write. */
static int s_volume_pending;
static int s_brightness_pending;
static volatile bool s_volume_dirty;
static volatile bool s_brightness_dirty;

/* Run-time-stat difference method state. */
static uint32_t s_load_prev_total;
static uint32_t s_load_prev_idle;
static bool s_load_prev_valid;
static uint32_t s_load_ticks;

/* ---- Network view ------------------------------------------------- */
static lv_obj_t *s_net_status_label;
static lv_obj_t *s_net_ssid_ta;
static lv_obj_t *s_net_pass_ta;
static lv_obj_t *s_net_hint_label;
static lv_obj_t *s_net_scan_list;
static lv_obj_t *s_keyboard;
static char s_net_status_cache[80];

/* Deferred network work. Every field below is touched only on the panel task:
 * the UI callbacks run inside lv_timer_handler (lock held) and
 * ha_panel_settings_service() runs after the lock is released, so a plain
 * flag is enough (no cross-task racing beyond the volatile hand-off). */
typedef enum {
    SET_NET_OP_NONE = 0,
    SET_NET_OP_SCAN,
    SET_NET_OP_SAVE,
} set_net_op_t;

static volatile set_net_op_t s_net_op;
static volatile bool s_net_scanning;
static char s_net_ssid_pending[SET_NET_SSID_MAX + 1];
static char s_net_pass_pending[SET_NET_PASS_MAX + 1];

/* Scan results published by the service, consumed by the poll. The generation
 * counter tells the poll when a fresh result set is ready to render. */
static wifi_manager_scan_record_t s_net_scan_records[SET_NET_SCAN_MAX];
static volatile int s_net_scan_count;
static volatile uint32_t s_net_scan_gen;
static uint32_t s_net_scan_shown_gen;

/* One-line result/hint message, same producer/consumer split as the scan. */
static char s_net_msg[64];
static volatile uint32_t s_net_msg_gen;
static uint32_t s_net_msg_shown_gen;

static void settings_net_hide_keyboard(void);
static void settings_net_refresh_status(void);
static void settings_net_refresh_msg(void);
static void settings_net_refresh_list(void);

/* ------------------------------------------------------------------ */
/* Hardware apply                                                     */
/* ------------------------------------------------------------------ */

/* Best-effort live codec volume. The ES8311 is only settable while the shared
 * codec is open (a TTS/PTT playback holds it); when idle the call returns
 * WRONG_STATE and the persisted value simply takes effect on the next open. */
static void settings_apply_volume(int volume)
{
    void *handle = NULL;
    if (esp_board_manager_get_device_handle(ESP_BOARD_DEVICE_NAME_AUDIO_DAC, &handle) != ESP_OK || !handle) {
        return;
    }
    dev_audio_codec_handles_t *dac = (dev_audio_codec_handles_t *)handle;
    if (!dac->codec_dev) {
        return;
    }
    (void)esp_codec_dev_set_out_vol(dac->codec_dev, volume);
}

/* LEDC backlight duty, mirroring the board manager's own brightness path. */
static void settings_apply_brightness(int percent)
{
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }

    periph_ledc_handle_t *handle = NULL;
    dev_ledc_ctrl_config_t *dev_cfg = NULL;
    periph_ledc_config_t *ledc_cfg = NULL;

    if (esp_board_manager_get_device_handle(ESP_BOARD_DEVICE_NAME_LCD_BRIGHTNESS, (void **)&handle) != ESP_OK ||
        !handle) {
        return;
    }
    if (esp_board_manager_get_device_config(ESP_BOARD_DEVICE_NAME_LCD_BRIGHTNESS, (void **)&dev_cfg) != ESP_OK ||
        !dev_cfg || !dev_cfg->ledc_name) {
        return;
    }
    if (esp_board_periph_get_config(dev_cfg->ledc_name, (void **)&ledc_cfg) != ESP_OK || !ledc_cfg) {
        return;
    }

    uint32_t max_duty = ((uint32_t)1 << ledc_cfg->duty_resolution) - 1;
    uint32_t duty = (uint32_t)percent * max_duty / 100u;
    ledc_set_duty(handle->speed_mode, handle->channel, duty);
    ledc_update_duty(handle->speed_mode, handle->channel);
}

/* ------------------------------------------------------------------ */
/* System load                                                        */
/* ------------------------------------------------------------------ */

static void settings_load_set(lv_obj_t *value_label, const char *fmt, ...)
{
    if (!value_label) {
        return;
    }
    char buf[64];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    lv_label_set_text(value_label, buf);
}

static void settings_refresh_load(void)
{
    int cpu_pct = 0;
    int idle_pct = 0;

#if CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS
    static TaskStatus_t s_tasks[SET_MAX_TASKS];
    uint32_t total = 0;
    UBaseType_t got = uxTaskGetSystemState(s_tasks, SET_MAX_TASKS, &total);

    uint32_t idle = 0;
    for (UBaseType_t i = 0; i < got; i++) {
        if (s_tasks[i].pcTaskName && strncmp(s_tasks[i].pcTaskName, "IDLE", 4) == 0) {
            idle += (uint32_t)s_tasks[i].ulRunTimeCounter;
        }
    }

    if (s_load_prev_valid) {
        uint32_t d_total = total - s_load_prev_total;
        uint32_t d_idle = idle - s_load_prev_idle;
        if (d_total > 0 && d_idle <= d_total) {
            idle_pct = (int)((uint64_t)d_idle * 100u / d_total);
            cpu_pct = 100 - idle_pct;
        }
    }
    s_load_prev_total = total;
    s_load_prev_idle = idle;
    s_load_prev_valid = true;
#endif

    settings_load_set(s_load_cpu_value, "CPU: %d%%", cpu_pct);
    settings_load_set(s_load_idle_value, "空闲: %d%%", idle_pct);

    size_t ram_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    size_t ram_total = heap_caps_get_total_size(MALLOC_CAP_INTERNAL);
    settings_load_set(s_load_ram_value, "%u / %u KB", (unsigned)(ram_free / 1024), (unsigned)(ram_total / 1024));

    size_t ps_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    size_t ps_total = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    settings_load_set(s_load_psram_value, "%u / %u KB", (unsigned)(ps_free / 1024), (unsigned)(ps_total / 1024));

    settings_load_set(s_load_tasks_value, "%u", (unsigned)uxTaskGetNumberOfTasks());
}

/* ------------------------------------------------------------------ */
/* Overlay navigation                                                 */
/* ------------------------------------------------------------------ */

static void settings_show_view(set_view_t view)
{
    s_view = view;
    for (int i = 0; i < SET_VIEW_COUNT; i++) {
        if (!s_views[i]) {
            continue;
        }
        if (i == (int)view) {
            lv_obj_remove_flag(s_views[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(s_views[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
    if (s_view_title) {
        lv_label_set_text(s_view_title, SET_VIEW_TITLES[view]);
    }
    if (view != SET_VIEW_NETWORK) {
        settings_net_hide_keyboard();
    }
    if (view == SET_VIEW_LOAD) {
        s_load_prev_valid = false;   /* discard stale deltas from a previous open */
        s_load_ticks = SET_LOAD_REFRESH_TICKS;
    }
    if (view == SET_VIEW_NETWORK) {
        s_net_status_cache[0] = '\0';   /* force a repaint of the status line */
        settings_net_refresh_status();
    }
}

static void settings_close(void)
{
    if (s_overlay) {
        lv_obj_add_flag(s_overlay, LV_OBJ_FLAG_HIDDEN);
    }
    settings_show_view(SET_VIEW_MENU);   /* reset for the next open */
}

/* ------------------------------------------------------------------ */
/* Event callbacks                                                    */
/* ------------------------------------------------------------------ */

static void settings_open_cb(lv_event_t *e)
{
    (void)e;
    if (!s_overlay) {
        return;
    }
    lv_obj_remove_flag(s_overlay, LV_OBJ_FLAG_HIDDEN);
    settings_show_view(SET_VIEW_MENU);
}

static void settings_back_cb(lv_event_t *e)
{
    (void)e;
    if (s_view == SET_VIEW_MENU) {
        settings_close();
    } else {
        settings_show_view(SET_VIEW_MENU);
    }
}

static void settings_menu_item_cb(lv_event_t *e)
{
    set_view_t view = (set_view_t)(intptr_t)lv_event_get_user_data(e);
    settings_show_view(view);
}

static void settings_volume_cb(lv_event_t *e)
{
    int value = (int)lv_slider_get_value(lv_event_get_target(e));
    if (s_vol_value) {
        lv_label_set_text_fmt(s_vol_value, "%d%%", value);
    }
    settings_apply_volume(value);
    s_volume_pending = value;
    s_volume_dirty = true;
}

static void settings_brightness_cb(lv_event_t *e)
{
    int value = (int)lv_slider_get_value(lv_event_get_target(e));
    if (s_bright_value) {
        lv_label_set_text_fmt(s_bright_value, "%d%%", value);
    }
    settings_apply_brightness(value);
    s_brightness_pending = value;
    s_brightness_dirty = true;
}

/* ------------------------------------------------------------------ */
/* UI construction                                                    */
/* ------------------------------------------------------------------ */

static void settings_style_view(lv_obj_t *view)
{
    lv_obj_set_size(view, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_opa(view, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(view, 0, 0);
    lv_obj_set_style_pad_all(view, 4, 0);
    lv_obj_set_style_pad_row(view, 12, 0);
    lv_obj_set_flex_flow(view, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(view, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_clear_flag(view, LV_OBJ_FLAG_SCROLLABLE);
}

/* A "name ............ value" row (transparent, space-between). */
static lv_obj_t *settings_make_row(lv_obj_t *parent)
{
    lv_obj_t *row = lv_obj_create(parent);
    lv_obj_set_width(row, LV_PCT(100));
    lv_obj_set_height(row, LV_SIZE_CONTENT);
    lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_pad_all(row, 0, 0);
    lv_obj_clear_flag(row, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    return row;
}

static lv_obj_t *settings_make_label(lv_obj_t *parent, const char *text, uint32_t color)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_color(label, lv_color_hex(color), 0);
    return label;
}

/* A flat card-coloured button with a centered label (used by the network view). */
static lv_obj_t *settings_make_button(lv_obj_t *parent, const char *text, lv_event_cb_t cb)
{
    lv_obj_t *btn = lv_button_create(parent);
    lv_obj_set_height(btn, 40);
    lv_obj_set_flex_grow(btn, 1);
    lv_obj_set_style_bg_color(btn, lv_color_hex(SET_COLOR_CARD), 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);
    if (cb) {
        lv_obj_add_event_cb(btn, cb, LV_EVENT_CLICKED, NULL);
    }
    lv_obj_t *label = settings_make_label(btn, text, SET_COLOR_TEXT);
    lv_obj_center(label);
    return btn;
}

static void settings_build_menu(lv_obj_t *view)
{
    static const struct {
        const char *text;
        set_view_t view;
    } items[] = {
        { "网络", SET_VIEW_NETWORK },
        { "音量", SET_VIEW_VOLUME },
        { "亮度", SET_VIEW_BRIGHTNESS },
        { "系统负载", SET_VIEW_LOAD },
    };

    for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        lv_obj_t *btn = lv_button_create(view);
        lv_obj_set_width(btn, LV_PCT(100));
        lv_obj_set_height(btn, 46);
        lv_obj_set_style_bg_color(btn, lv_color_hex(SET_COLOR_CARD), 0);
        lv_obj_set_style_shadow_width(btn, 0, 0);
        lv_obj_add_event_cb(btn, settings_menu_item_cb, LV_EVENT_CLICKED, (void *)(intptr_t)items[i].view);

        lv_obj_t *label = settings_make_label(btn, items[i].text, SET_COLOR_TEXT);
        lv_obj_align(label, LV_ALIGN_LEFT_MID, 8, 0);
    }
}

static void settings_build_slider_view(lv_obj_t *view, const char *name, int value,
                                       lv_obj_t **out_value, lv_event_cb_t cb)
{
    lv_obj_t *row = settings_make_row(view);
    settings_make_label(row, name, SET_COLOR_TEXT);
    lv_obj_t *value_label = settings_make_label(row, "", SET_COLOR_ACCENT);
    lv_label_set_text_fmt(value_label, "%d%%", value);

    lv_obj_t *slider = lv_slider_create(view);
    lv_obj_set_width(slider, LV_PCT(100));
    lv_slider_set_range(slider, 0, 100);
    lv_slider_set_value(slider, value, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(slider, lv_color_hex(SET_COLOR_CARD), LV_PART_MAIN);
    lv_obj_set_style_bg_color(slider, lv_color_hex(SET_COLOR_ACCENT), LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(slider, lv_color_hex(SET_COLOR_TEXT), LV_PART_KNOB);
    lv_obj_add_event_cb(slider, cb, LV_EVENT_VALUE_CHANGED, NULL);

    *out_value = value_label;
}

static void settings_build_load_view(lv_obj_t *view)
{
    static const struct {
        const char *name;
        lv_obj_t **value;
    } rows[] = {
        { "CPU 占用", &s_load_cpu_value },
        { "空闲",     &s_load_idle_value },
        { "内部 RAM", &s_load_ram_value },
        { "PSRAM",    &s_load_psram_value },
        { "任务数",   &s_load_tasks_value },
    };

    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        lv_obj_t *row = settings_make_row(view);
        settings_make_label(row, rows[i].name, SET_COLOR_TEXT_DIM);
        lv_obj_t *value = settings_make_label(row, "--", SET_COLOR_TEXT);
        *rows[i].value = value;
    }
}

/* ------------------------------------------------------------------ */
/* Network view                                                       */
/* ------------------------------------------------------------------ */
/* The Wi-Fi scan and the apply call block for seconds and must run with the
 * LVGL lock released, so the buttons only set a request flag; the blocking work
 * happens in ha_panel_settings_service() and its results (message + scan list)
 * are rendered by the next lock-held poll. */

static void settings_net_post(const char *msg)
{
    strlcpy(s_net_msg, msg, sizeof(s_net_msg));
    s_net_msg_gen++;
}

static void settings_net_hide_keyboard(void)
{
    if (s_keyboard) {
        lv_obj_add_flag(s_keyboard, LV_OBJ_FLAG_HIDDEN);
    }
}

static void settings_net_refresh_status(void)
{
    if (!s_net_status_label) {
        return;
    }
    wifi_manager_status_t st;
    memset(&st, 0, sizeof(st));
    wifi_manager_get_status(&st);

    char line[80];
    bool online = false;
    if (st.sta_connected) {
        online = true;
        snprintf(line, sizeof(line), "状态: 已连接 · %s",
                 (st.sta_ip && st.sta_ip[0]) ? st.sta_ip : "-");
    } else if (st.ap_active) {
        snprintf(line, sizeof(line), "状态: AP 模式 · %s",
                 st.sta_configured ? "配网中" : "等待配置");
    } else if (st.sta_configured) {
        snprintf(line, sizeof(line), "状态: 未连接");
    } else {
        snprintf(line, sizeof(line), "状态: 未设置");
    }

    if (strcmp(line, s_net_status_cache) != 0) {
        strlcpy(s_net_status_cache, line, sizeof(s_net_status_cache));
        lv_label_set_text(s_net_status_label, s_net_status_cache);
        lv_obj_set_style_text_color(s_net_status_label,
                                    lv_color_hex(online ? SET_COLOR_ON : SET_COLOR_TEXT_DIM), 0);
    }
}

static void settings_net_refresh_msg(void)
{
    if (!s_net_hint_label) {
        return;
    }
    if (s_net_scanning) {
        lv_label_set_text(s_net_hint_label, "正在扫描...");
        return;
    }
    if (s_net_msg_gen != s_net_msg_shown_gen) {
        s_net_msg_shown_gen = s_net_msg_gen;
        lv_label_set_text(s_net_hint_label, s_net_msg);
    }
}

/* Tapping a scan result fills the SSID field (user_data points at the record's
 * SSID inside s_net_scan_records, which stays valid until the next scan). */
static void settings_net_ap_cb(lv_event_t *e)
{
    const char *ssid = (const char *)lv_event_get_user_data(e);
    if (s_net_ssid_ta && ssid) {
        lv_textarea_set_text(s_net_ssid_ta, ssid);
    }
    settings_net_hide_keyboard();
}

static void settings_net_refresh_list(void)
{
    if (!s_net_scan_list || s_net_scan_gen == s_net_scan_shown_gen) {
        return;
    }
    s_net_scan_shown_gen = s_net_scan_gen;

    lv_obj_clean(s_net_scan_list);
    int count = s_net_scan_count;
    if (count > SET_NET_SCAN_MAX) {
        count = SET_NET_SCAN_MAX;
    }
    for (int i = 0; i < count; i++) {
        lv_obj_t *btn = lv_button_create(s_net_scan_list);
        lv_obj_set_width(btn, LV_PCT(100));
        lv_obj_set_height(btn, 38);
        lv_obj_set_style_bg_color(btn, lv_color_hex(SET_COLOR_CARD), 0);
        lv_obj_set_style_shadow_width(btn, 0, 0);
        lv_obj_add_event_cb(btn, settings_net_ap_cb, LV_EVENT_CLICKED, s_net_scan_records[i].ssid);

        lv_obj_t *label = settings_make_label(btn, "", SET_COLOR_TEXT);
        lv_label_set_text_fmt(label, "%s  (%d dBm)",
                              s_net_scan_records[i].ssid[0] ? s_net_scan_records[i].ssid : "(隐藏)",
                              (int)s_net_scan_records[i].rssi);
        lv_obj_align(label, LV_ALIGN_LEFT_MID, 6, 0);
    }
}

/* Focus a text area -> raise the shared on-screen keyboard for it. */
static void settings_net_ta_focus_cb(lv_event_t *e)
{
    if (!s_keyboard) {
        return;
    }
    lv_keyboard_set_textarea(s_keyboard, lv_event_get_target(e));
    lv_obj_remove_flag(s_keyboard, LV_OBJ_FLAG_HIDDEN);
}

static void settings_net_kb_cb(lv_event_t *e)
{
    (void)e;
    settings_net_hide_keyboard();
}

static void settings_net_scan_cb(lv_event_t *e)
{
    (void)e;
    settings_net_hide_keyboard();
    s_net_scanning = true;
    s_net_op = SET_NET_OP_SCAN;
    /* Paint the "scanning" hint now: the scan blocks the panel task for a few
     * seconds, during which lv_timer_handler does not run again. */
    if (s_net_hint_label) {
        lv_label_set_text(s_net_hint_label, "正在扫描...");
        lv_refr_now(NULL);
    }
}

static void settings_net_save_cb(lv_event_t *e)
{
    (void)e;
    settings_net_hide_keyboard();
    /* Copy the text area text now (valid only with the lock held); the blocking
     * save + apply runs later in ha_panel_settings_service(). */
    if (s_net_ssid_ta) {
        strlcpy(s_net_ssid_pending, lv_textarea_get_text(s_net_ssid_ta), sizeof(s_net_ssid_pending));
    }
    if (s_net_pass_ta) {
        strlcpy(s_net_pass_pending, lv_textarea_get_text(s_net_pass_ta), sizeof(s_net_pass_pending));
    }
    s_net_op = SET_NET_OP_SAVE;
}

/* Persist SSID/password to NVS and apply the STA config live. Runs with the
 * LVGL lock released (called from ha_panel_settings_service()). */
static void settings_network_save(void)
{
    app_config_t *cfg = heap_caps_calloc(1, sizeof(*cfg), MALLOC_CAP_SPIRAM);
    if (!cfg) {
        settings_net_post("保存失败: 内存不足");
        return;
    }
    if (app_config_load(cfg) != ESP_OK) {
        free(cfg);
        settings_net_post("保存失败: 读取配置错误");
        return;
    }

    strlcpy(cfg->wifi_ssid, s_net_ssid_pending, sizeof(cfg->wifi_ssid));
    strlcpy(cfg->wifi_password, s_net_pass_pending, sizeof(cfg->wifi_password));

    const char *message = NULL;
    esp_err_t err = app_config_validate_wifi(cfg, &message);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "network save rejected: %s", message ? message : "invalid");
        settings_net_post("参数无效: 名称 1-31, 密码 8-63");
        free(cfg);
        return;
    }

    err = app_config_save(cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "network save failed: %s", esp_err_to_name(err));
        settings_net_post("保存失败: 写入配置错误");
        free(cfg);
        return;
    }

    /* Mirror the boot path / cmd_wifi --apply: hand the saved credentials to
     * wifi_manager so the new network is joined without a reboot. */
    wifi_manager_config_t wcfg = {
        .sta_ssid = cfg->wifi_ssid,
        .sta_password = cfg->wifi_password,
        .ap_ssid = cfg->ap_ssid[0] ? cfg->ap_ssid : NULL,
        .ap_password = cfg->ap_password[0] ? cfg->ap_password : NULL,
        .ap_behavior = cfg->ap_behavior,
    };
    err = wifi_manager_apply_sta_config(&wcfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "network apply failed: %s", esp_err_to_name(err));
        settings_net_post("已保存, 应用失败");
    } else {
        settings_net_post("已保存, 正在连接...");
    }
    free(cfg);
}

static void settings_build_network_view(lv_obj_t *view)
{
    s_net_status_label = settings_make_label(view, "状态: -", SET_COLOR_TEXT_DIM);
    lv_obj_set_width(s_net_status_label, LV_PCT(100));

    settings_make_label(view, "WiFi 名称", SET_COLOR_TEXT);
    s_net_ssid_ta = lv_textarea_create(view);
    lv_obj_set_width(s_net_ssid_ta, LV_PCT(100));
    lv_obj_set_height(s_net_ssid_ta, 42);
    lv_textarea_set_one_line(s_net_ssid_ta, true);
    lv_textarea_set_max_length(s_net_ssid_ta, SET_NET_SSID_MAX);
    lv_textarea_set_text(s_net_ssid_ta, s_net_ssid_pending);
    lv_obj_add_event_cb(s_net_ssid_ta, settings_net_ta_focus_cb, LV_EVENT_FOCUSED, NULL);

    settings_make_label(view, "密码", SET_COLOR_TEXT);
    s_net_pass_ta = lv_textarea_create(view);
    lv_obj_set_width(s_net_pass_ta, LV_PCT(100));
    lv_obj_set_height(s_net_pass_ta, 42);
    lv_textarea_set_one_line(s_net_pass_ta, true);
    lv_textarea_set_password_mode(s_net_pass_ta, true);
    lv_textarea_set_max_length(s_net_pass_ta, SET_NET_PASS_MAX);
    lv_textarea_set_text(s_net_pass_ta, s_net_pass_pending);
    lv_obj_add_event_cb(s_net_pass_ta, settings_net_ta_focus_cb, LV_EVENT_FOCUSED, NULL);

    /* Scan + save buttons, side by side. */
    lv_obj_t *btn_row = lv_obj_create(view);
    lv_obj_set_width(btn_row, LV_PCT(100));
    lv_obj_set_height(btn_row, LV_SIZE_CONTENT);
    lv_obj_set_style_bg_opa(btn_row, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(btn_row, 0, 0);
    lv_obj_set_style_pad_all(btn_row, 0, 0);
    lv_obj_set_style_pad_column(btn_row, 12, 0);
    lv_obj_clear_flag(btn_row, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(btn_row, LV_FLEX_FLOW_ROW);
    settings_make_button(btn_row, "扫描", settings_net_scan_cb);
    settings_make_button(btn_row, "保存", settings_net_save_cb);

    s_net_hint_label = settings_make_label(view, "点击『扫描』选择网络, 或直接输入", SET_COLOR_ACCENT);
    lv_obj_set_width(s_net_hint_label, LV_PCT(100));
    lv_label_set_long_mode(s_net_hint_label, LV_LABEL_LONG_WRAP);

    /* Scrollable scan-result list; tapping a row fills the SSID field. */
    s_net_scan_list = lv_obj_create(view);
    lv_obj_set_width(s_net_scan_list, LV_PCT(100));
    lv_obj_set_flex_grow(s_net_scan_list, 1);
    lv_obj_set_style_bg_opa(s_net_scan_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_net_scan_list, 0, 0);
    lv_obj_set_style_pad_all(s_net_scan_list, 0, 0);
    lv_obj_set_style_pad_row(s_net_scan_list, 4, 0);
    lv_obj_set_flex_flow(s_net_scan_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_net_scan_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_add_flag(s_net_scan_list, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scroll_dir(s_net_scan_list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_net_scan_list, LV_SCROLLBAR_MODE_AUTO);
}

static void settings_build_overlay(lv_obj_t *screen)
{
    s_overlay = lv_obj_create(screen);
    /* Cover the whole screen: the panel screen has padding, so size the overlay
     * to the screen's own size and ignore the parent flex layout. */
    lv_obj_set_size(s_overlay, lv_obj_get_width(screen), lv_obj_get_height(screen));
    lv_obj_add_flag(s_overlay, LV_OBJ_FLAG_IGNORE_LAYOUT);
    lv_obj_add_flag(s_overlay, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(s_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(s_overlay, lv_color_hex(SET_COLOR_BG), 0);
    lv_obj_set_style_border_width(s_overlay, 0, 0);
    lv_obj_set_style_radius(s_overlay, 0, 0);
    lv_obj_set_style_pad_all(s_overlay, 8, 0);
    lv_obj_set_style_pad_row(s_overlay, 8, 0);
    lv_obj_set_flex_flow(s_overlay, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_overlay, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
    lv_obj_center(s_overlay);

    /* Top bar: back button (left) + title (centered). */
    lv_obj_t *topbar = lv_obj_create(s_overlay);
    lv_obj_set_width(topbar, LV_PCT(100));
    lv_obj_set_height(topbar, 40);
    lv_obj_set_style_bg_color(topbar, lv_color_hex(SET_COLOR_HEADER), 0);
    lv_obj_set_style_border_width(topbar, 0, 0);
    lv_obj_set_style_radius(topbar, 10, 0);
    lv_obj_clear_flag(topbar, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *back = lv_button_create(topbar);
    lv_obj_set_size(back, 60, 30);
    lv_obj_set_style_bg_color(back, lv_color_hex(SET_COLOR_BTN), 0);
    lv_obj_set_style_shadow_width(back, 0, 0);
    lv_obj_align(back, LV_ALIGN_LEFT_MID, 0, 0);
    lv_obj_add_event_cb(back, settings_back_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *back_label = settings_make_label(back, "返回", SET_COLOR_TEXT);
    lv_obj_center(back_label);

    s_view_title = settings_make_label(topbar, SET_VIEW_TITLES[SET_VIEW_MENU], SET_COLOR_TEXT);
    lv_obj_center(s_view_title);

    /* Body: one full-size sibling per view; only the active one is visible. */
    lv_obj_t *body = lv_obj_create(s_overlay);
    lv_obj_set_width(body, LV_PCT(100));
    lv_obj_set_flex_grow(body, 1);
    lv_obj_set_style_bg_opa(body, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(body, 0, 0);
    lv_obj_set_style_pad_all(body, 0, 0);
    lv_obj_clear_flag(body, LV_OBJ_FLAG_SCROLLABLE);

    for (int i = 0; i < SET_VIEW_COUNT; i++) {
        lv_obj_t *view = lv_obj_create(body);
        settings_style_view(view);
        s_views[i] = view;
    }
    settings_build_menu(s_views[SET_VIEW_MENU]);
    settings_build_slider_view(s_views[SET_VIEW_VOLUME], "音量", s_volume_pending,
                               &s_vol_value, settings_volume_cb);
    settings_build_slider_view(s_views[SET_VIEW_BRIGHTNESS], "亮度", s_brightness_pending,
                               &s_bright_value, settings_brightness_cb);
    settings_build_load_view(s_views[SET_VIEW_LOAD]);
    settings_build_network_view(s_views[SET_VIEW_NETWORK]);

    /* Shared on-screen keyboard: raised under the focused text area by the
     * network view, kept outside the flex flow and hidden by default. */
    s_keyboard = lv_keyboard_create(s_overlay);
    lv_obj_set_size(s_keyboard, LV_PCT(100), SET_NET_KB_HEIGHT);
    lv_obj_add_flag(s_keyboard, LV_OBJ_FLAG_IGNORE_LAYOUT);
    lv_obj_add_flag(s_keyboard, LV_OBJ_FLAG_HIDDEN);
    lv_obj_align(s_keyboard, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_add_event_cb(s_keyboard, settings_net_kb_cb, LV_EVENT_READY, NULL);
    lv_obj_add_event_cb(s_keyboard, settings_net_kb_cb, LV_EVENT_CANCEL, NULL);

    settings_show_view(SET_VIEW_MENU);
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

void ha_panel_settings_attach(lv_obj_t *header, lv_obj_t *screen)
{
    if (s_built || !header || !screen) {
        return;
    }

    int volume = SET_VOL_DEFAULT;
    int brightness = SET_BRIGHT_DEFAULT;

    app_config_t *cfg = heap_caps_calloc(1, sizeof(*cfg), MALLOC_CAP_SPIRAM);
    if (cfg) {
        if (app_config_load(cfg) == ESP_OK) {
            if (cfg->voice_volume[0]) {
                volume = atoi(cfg->voice_volume);
            }
            if (cfg->lcd_brightness[0]) {
                brightness = atoi(cfg->lcd_brightness);
            }
            strlcpy(s_net_ssid_pending, cfg->wifi_ssid, sizeof(s_net_ssid_pending));
            strlcpy(s_net_pass_pending, cfg->wifi_password, sizeof(s_net_pass_pending));
        }
        free(cfg);
    }
    if (volume < 0 || volume > 100) {
        volume = SET_VOL_DEFAULT;
    }
    if (brightness < 0 || brightness > 100) {
        brightness = SET_BRIGHT_DEFAULT;
    }
    s_volume_pending = volume;
    s_brightness_pending = brightness;

    /* Header gear/"设置" button, right-aligned. */
    lv_obj_t *btn = lv_button_create(header);
    lv_obj_set_size(btn, 60, 28);
    lv_obj_set_style_bg_color(btn, lv_color_hex(SET_COLOR_BTN), 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);
    lv_obj_align(btn, LV_ALIGN_RIGHT_MID, -2, 0);
    lv_obj_add_event_cb(btn, settings_open_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *btn_label = settings_make_label(btn, "设置", SET_COLOR_TEXT);
    lv_obj_center(btn_label);

    settings_build_overlay(screen);

    s_built = true;

    /* Restore the persisted backlight level now that the board is up. */
    settings_apply_brightness(brightness);
    ESP_LOGI(TAG, "settings ready (volume=%d brightness=%d)", volume, brightness);
}

void ha_panel_settings_poll(void)
{
    if (!s_built || !s_overlay) {
        return;
    }
    if (lv_obj_has_flag(s_overlay, LV_OBJ_FLAG_HIDDEN)) {
        return;
    }

    if (s_view == SET_VIEW_NETWORK) {
        settings_net_refresh_status();
        settings_net_refresh_msg();
        settings_net_refresh_list();
        return;
    }

    if (s_view != SET_VIEW_LOAD) {
        return;
    }
    if (++s_load_ticks < SET_LOAD_REFRESH_TICKS) {
        return;
    }
    s_load_ticks = 0;
    settings_refresh_load();
}

void ha_panel_settings_service(void)
{
    set_net_op_t op = s_net_op;
    if (op == SET_NET_OP_NONE) {
        return;
    }
    s_net_op = SET_NET_OP_NONE;

    if (op == SET_NET_OP_SCAN) {
        uint16_t count = 0;
        esp_err_t err = wifi_manager_scan_aps(s_net_scan_records, SET_NET_SCAN_MAX, &count);
        s_net_scan_count = (int)count;
        s_net_scan_gen++;
        s_net_scanning = false;
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "network scan failed: %s", esp_err_to_name(err));
            settings_net_post("扫描失败, 请重试");
        } else if (count == 0) {
            settings_net_post("未找到网络");
        } else {
            settings_net_post("扫描完成, 点击选择或手动输入");
        }
        return;
    }

    if (op == SET_NET_OP_SAVE) {
        settings_network_save();
    }
}

bool ha_panel_settings_commit_pending(void)
{
    bool volume_changed = s_volume_dirty;
    if (!s_volume_dirty && !s_brightness_dirty) {
        return false;
    }

    int volume = s_volume_pending;
    int brightness = s_brightness_pending;
    s_volume_dirty = false;
    s_brightness_dirty = false;

    app_config_t *cfg = heap_caps_calloc(1, sizeof(*cfg), MALLOC_CAP_SPIRAM);
    if (!cfg) {
        return volume_changed;
    }
    if (app_config_load(cfg) == ESP_OK) {
        if (volume_changed) {
            snprintf(cfg->voice_volume, sizeof(cfg->voice_volume), "%d", volume);
        }
        snprintf(cfg->lcd_brightness, sizeof(cfg->lcd_brightness), "%d", brightness);
        if (app_config_save(cfg) != ESP_OK) {
            ESP_LOGW(TAG, "failed to persist volume/brightness");
        }
    }
    free(cfg);

    return volume_changed;
}
