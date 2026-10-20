/*
 * HA AI Panel - application-layer LVGL panel (M1 phase 1).
 *
 * The panel is the on-device UI of the solution and lives inside the esp-claw
 * application layer (it does not replace it). It renders a three-page menu
 * navigated by a bottom touch tab bar:
 *
 *   - Panel page: Home Assistant link state (configured / not configured and
 *     the base URL). Entity cards appear here once the HA WebSocket client is
 *     wired up; there is no mock data.
 *   - Voice page: machine-readable status code + a scrollable conversation
 *     history (mirrored from the files the voice Lua skills write).
 *   - Info page: ESP-Claw system status grouped as network / LLM / IM / voice
 *     state, all read from the same NVS-backed app_config the Web UI writes,
 *     plus the live WiFi status polled from wifi_manager.
 *
 * Screen ownership:
 *   The board display is arbitrated by display_arbiter. Its default owner is
 *   DISPLAY_ARBITER_OWNER_EMOTE, i.e. the emote/expression engine is drawing
 *   at boot. This module acquires DISPLAY_ARBITER_OWNER_LUA, which makes the
 *   emote flush callback stop writing to the panel, and gates its own flush
 *   callback on the same ownership check. LUA is reused (instead of adding a
 *   new enum value) to keep the upstream display_arbiter untouched: the
 *   arbiter only accepts LUA/EMOTE and LUA reference-counts via lua_depth,
 *   so a single acquire held for the process lifetime pins the owner to LUA.
 *
 * Buffer/endianness:
 *   The panel is a SPI ST7796 whose board config sets data_endian = BIG, so
 *   the LVGL RGB565 framebuffer must be byte-swapped before draw_bitmap, and
 *   the draw buffer must live in DMA-capable internal RAM.
 */
#include "ha_panel.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "app_config.h"
#include "claw_paths.h"
#include "widget/gfx_font_lvgl.h"
#include "display_arbiter.h"
#include "esp_board_manager_includes.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_touch.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "ha_voice_wake.h"
#include "ha_panel_settings.h"
#include "ha_panel_power.h"
#include "lvgl.h"
#include "wifi_manager.h"

static const char *TAG = "ha_panel";

#define HA_PANEL_BUF_LINES           40
#define HA_PANEL_TICK_MS             5
#define HA_PANEL_TASK_PERIOD_MS      10
#define HA_PANEL_TASK_STACK          8192
#define HA_PANEL_TASK_PRIO           4
#define HA_PANEL_LOCK_TIMEOUT_MS     1000

/* Voice bridge: the voice Lua skills (via the shared voice_common.lua) write
 * these files under the writable storage root (CLAW_PATH_DATA, physically
 * /fatfs) and the panel polls them to mirror the conversation on screen. No
 * Lua->C display capability needed.
 *
 *   voice_status.txt  "<code>|<detail>"
 *       `code` is a machine-readable token mapped here to a CJK label + busy
 *       flag (HA_VOICE_STATUS_MAP); `detail` is optional自由 text (a failure
 *       reason). Keeping the code and the wording apart means changing the
 *       label never silently breaks the busy badge.
 *   voice_log.txt     "<role>\x1f<text>\x1e" per record, role U(user)/A(agent)
 *       Rendered as a scrollable bubble list. Buffers live in PSRAM to spare
 *       the tight internal RAM. */
#define HA_VOICE_STATUS_FILE         "voice_status.txt"
#define HA_VOICE_LOG_FILE            "voice_log.txt"
#define HA_VOICE_TEXT_MAX            4096  /* max bytes per log record */
#define HA_VOICE_LOG_MAX             8     /* bubbles rendered (matches Lua trim) */
#define HA_VOICE_LOG_BYTES           (40 * 1024)  /* PSRAM read buffer / snapshot */
#define HA_VOICE_STATUS_MAX          96
#define HA_VOICE_POLL_CYCLES         20   /* every 20 * 10ms = 200ms */

/* Record separators used by voice_common.lua (US between role/text, RS between
 * records). LLM output never contains these control chars, so no escaping. */
#define HA_VOICE_FIELD_SEP           '\x1f'
#define HA_VOICE_RECORD_SEP          '\x1e'

/* Runtime config bridge: the panel serialises the NVS-backed app_config to a
 * JSON file the voice Lua skills read. Same file-bridge idea as the transcript
 * mirror, so no Lua<->C configuration binding is needed. */
#define HA_RUNTIME_CONFIG_FILE       "ha_voice_runtime.json"

/* Full-coverage CJK font baked into the read-only system partition (the LVGL
 * default Montserrat has no CJK, and the linked font_puhui_basic_20_4 only
 * carries ~199 curated glyphs, not enough for arbitrary LLM replies). */
#define HA_PANEL_CJK_FONT_PATH       "/system/font/font_puhui_common_14_1.bin"
/* /system is mounted after ha_panel_start(); retry before giving up. */
#define HA_PANEL_FONT_MAX_ATTEMPTS   50   /* 50 * HA_VOICE_POLL_CYCLES * 10ms = 10s */

/* Home Assistant-ish dark palette */
#define HA_COLOR_BG                  0x111418
#define HA_COLOR_HEADER              0x1F6FEB
#define HA_COLOR_CARD                0x1E2329
#define HA_COLOR_SECTION             0x60A5FA
#define HA_COLOR_TABBAR              0x181C21
#define HA_COLOR_TAB_ACTIVE          0x1F6FEB
#define HA_COLOR_TEXT                0xF5F5F5
#define HA_COLOR_TEXT_DIM            0x9CA3AF
#define HA_COLOR_ON                  0x4ADE80
#define HA_COLOR_OFF                 0x9CA3AF

typedef enum {
    HA_PAGE_PANEL = 0,
    HA_PAGE_VOICE,
    HA_PAGE_INFO,
    HA_PAGE_COUNT,
} ha_page_t;

static bool s_started;
static SemaphoreHandle_t s_mutex;
static lv_display_t *s_display;
static esp_lcd_panel_handle_t s_panel;
static esp_lcd_touch_handle_t s_touch;

/* Three-page menu. s_pages[] holds the per-page containers; only s_page (the
 * current index) is visible. Pages/tabs are hidden at runtime when their
 * backing feature is disabled in the Web config (s_page_enabled[]). */
static lv_obj_t *s_pages[HA_PAGE_COUNT];
static lv_obj_t *s_tab_btns[HA_PAGE_COUNT];
static lv_obj_t *s_voice_badge;      /* tab-bar dot shown while recording/thinking */
static ha_page_t s_page = HA_PAGE_PANEL;
static bool s_page_enabled[HA_PAGE_COUNT] = { true, true, true };

/* Set by the wake listener on wake-word detection; the panel task (which owns
 * the LVGL lock) consumes it and jumps to the voice page. */
static volatile bool s_wake_jump_pending;

/* Standby (screen off) state, toggled by a PWR button click. While set, the
 * panel task stops rendering - which also drops touch input - and the backlight
 * is dimmed to 0; the rest of the system (Wi-Fi, voice, wake word) keeps
 * running. Owned by the panel task. */
static bool s_standby;

/* Voice mirror UI + last-rendered text, so a poll only touches LVGL on change. */
static lv_font_t *s_cjk_font;
static int s_font_attempts;
static lv_obj_t *s_title_label;   /* static CJK labels that exist before font load */
static lv_obj_t *s_hint_label;
static lv_obj_t *s_status_label;
static lv_obj_t *s_voice_log;     /* scrollable conversation bubble list */
static char s_status_raw[HA_VOICE_STATUS_MAX];   /* last "<code>|<detail>" */

/* Reply-mode toggle shown on the voice page: switches the next voice turn
 * between agent mode (tools + memory) and direct mode (single LLM round-trip).
 * Persisted to app_config.voice_reply_mode and mirrored to the runtime JSON for
 * the Lua skills; see docs/adr/0001-voice-reply-mode.md. */
static lv_obj_t *s_reply_mode_label;
static bool s_reply_mode_direct;
static volatile bool s_reply_mode_dirty;

static void ha_panel_reply_mode_set_label(bool direct);

/* Conversation bridge buffers. They live in PSRAM: 40 KB read + snapshot would
 * not fit the tight internal RAM and the render path never needs DMA memory.
 * Allocation is best-effort; when NULL the poll degrades to a no-op. */
static char *s_voice_log_buf;     /* raw bytes read back from voice_log.txt */
static char *s_voice_log_snap;    /* last-rendered snapshot, compared to skip */
static char *s_voice_line;        /* scratch for one rendered bubble line */

/* Panel page: Home Assistant link state (no mock entities). */
static lv_obj_t *s_panel_ha_state_label;
static lv_obj_t *s_panel_ha_url_label;

/* Device-info page labels (refreshed from app_config + wifi_manager).
 * Grouped as network / LLM / IM / voice system status. */
static lv_obj_t *s_info_net_name_label;
static lv_obj_t *s_info_net_state_label;
static lv_obj_t *s_info_net_ip_label;
static lv_obj_t *s_info_net_ap_label;
static lv_obj_t *s_info_llm_state_label;
static lv_obj_t *s_info_llm_model_label;
static lv_obj_t *s_info_im_state_label;
static lv_obj_t *s_info_im_channel1_label;
static lv_obj_t *s_info_im_channel2_label;
static lv_obj_t *s_info_wake_label;
static lv_obj_t *s_info_asr_label;
static lv_obj_t *s_info_tts_label;

/* Cached text per label so the poll only touches LVGL when the string changes. */
static char s_panel_ha_state_text[64];
static char s_panel_ha_url_text[APP_CONFIG_STR_LEN + 16];
static char s_info_net_name_text[APP_CONFIG_STR_LEN + 16];
static char s_info_net_state_text[64];
static char s_info_net_ip_text[64];
static char s_info_net_ap_text[96];
static char s_info_llm_state_text[64];
static char s_info_llm_model_text[APP_CONFIG_STR_LEN + 16];
static char s_info_im_state_text[64];
static char s_info_im_channel1_text[64];
static char s_info_im_channel2_text[64];
static char s_info_wake_text[64];
static char s_info_asr_text[64];
static char s_info_tts_text[64];

/* Configured WiFi SSID, cached from the last app_config load; the live
 * connection state (connected / IP) is polled from wifi_manager separately. */
static char s_info_wifi_ssid[APP_CONFIG_STR_LEN];

/* ------------------------------------------------------------------ */
/* Locking                                                            */
/* ------------------------------------------------------------------ */

/* NOTE: returns bool, never an esp_err_t (see AGENTS.md white-screen lesson:
 * bsp_display_lock-style helpers return bool and must not be checked as
 * esp_err_t). */
static bool ha_panel_lock(void)
{
    return s_mutex && xSemaphoreTake(s_mutex, pdMS_TO_TICKS(HA_PANEL_LOCK_TIMEOUT_MS)) == pdTRUE;
}

static void ha_panel_unlock(void)
{
    if (s_mutex) {
        xSemaphoreGive(s_mutex);
    }
}

/* ------------------------------------------------------------------ */
/* CJK font                                                           */
/* ------------------------------------------------------------------ */

static void ha_panel_apply_font(lv_obj_t *obj);

/* One-shot self-check that the binary font's glyph metrics decode correctly
 * (the emote asset fonts are LV_FONT_FMT_TXT_LARGE-format: 16-byte glyph dsc). */
static void ha_panel_log_glyph(lv_font_t *font, uint32_t letter)
{
    lv_font_glyph_dsc_t gd;
    lv_memzero(&gd, sizeof(gd));
    bool found = lv_font_get_glyph_dsc(font, &gd, letter, 0);
    ESP_LOGI(TAG, "glyph U+%04X found=%d box=%ux%u adv=%u ofs=(%d,%d)",
             (unsigned)letter, (int)found, (unsigned)gd.box_w, (unsigned)gd.box_h,
             (unsigned)gd.adv_w, (int)gd.ofs_x, (int)gd.ofs_y);
}

/* Load the baked LVGL binary font into PSRAM and hand it to
 * gfx_font_lv_load_from_binary(), which fixups the offset-based dsc pointers
 * (the same path the emote engine uses for its asset fonts). The buffer must
 * outlive the font, so it is intentionally never freed. */
static lv_font_t *ha_panel_load_cjk_font(void)
{
    FILE *file = fopen(HA_PANEL_CJK_FONT_PATH, "rb");
    if (!file) {
        return NULL;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }

    uint8_t *buf = heap_caps_malloc((size_t)size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!buf) {
        fclose(file);
        return NULL;
    }
    size_t got = fread(buf, 1, (size_t)size, file);
    fclose(file);
    if (got != (size_t)size) {
        free(buf);
        return NULL;
    }

    lv_font_t *font = gfx_font_lv_load_from_binary(buf);
    if (!font) {
        free(buf);
        return NULL;
    }

    return font;
}

/* Apply the CJK font to a label; falls back to the LVGL default when the font
 * could not be loaded (ASCII still renders, CJK would not). */
static void ha_panel_apply_font(lv_obj_t *obj)
{
    if (s_cjk_font && obj) {
        lv_obj_set_style_text_font(obj, s_cjk_font, 0);
    }
}

/* Apply the font to a container and all of its descendants (used once, after
 * the deferred font load, so every already-built label picks it up). */
static void ha_panel_apply_font_tree(lv_obj_t *obj)
{
    if (!obj) {
        return;
    }
    ha_panel_apply_font(obj);
    uint32_t child_count = lv_obj_get_child_count(obj);
    for (uint32_t i = 0; i < child_count; i++) {
        ha_panel_apply_font_tree(lv_obj_get_child(obj, i));
    }
}

/* ha_panel_start() runs before app_fs_init() mounts /system, so the font file
 * is not readable yet on the first attempt. Retry on the panel task until it
 * loads (or the budget runs out), then apply it to the whole widget tree. */
static void ha_panel_ensure_font(void)
{
    if (s_cjk_font || s_font_attempts >= HA_PANEL_FONT_MAX_ATTEMPTS) {
        return;
    }
    s_font_attempts++;

    lv_font_t *font = ha_panel_load_cjk_font();
    if (!font) {
        if (s_font_attempts >= HA_PANEL_FONT_MAX_ATTEMPTS) {
            ESP_LOGW(TAG, "CJK font unavailable: %s", HA_PANEL_CJK_FONT_PATH);
        }
        return;
    }

    s_cjk_font = font;
    ha_panel_apply_font_tree(lv_screen_active());
    lv_obj_invalidate(lv_screen_active());
    ESP_LOGI(TAG, "CJK font loaded: %s (line_height=%d base_line=%d)",
             HA_PANEL_CJK_FONT_PATH, (int)font->line_height, (int)font->base_line);
    ha_panel_log_glyph(font, 'A');
    ha_panel_log_glyph(font, 0x4F60);   /* 你 */
    ha_panel_log_glyph(font, 0x597D);   /* 好 */
}

/* ------------------------------------------------------------------ */
/* LVGL display plumbing                                              */
/* ------------------------------------------------------------------ */

static bool IRAM_ATTR ha_panel_flush_done_cb(esp_lcd_panel_io_handle_t io,
                                             esp_lcd_panel_io_event_data_t *edata,
                                             void *user_ctx)
{
    (void)io;
    (void)edata;
    (void)user_ctx;

    if (s_display) {
        lv_display_flush_ready(s_display);
    }
    return false;
}

static void ha_panel_flush_cb(lv_display_t *display, const lv_area_t *area, uint8_t *px_map)
{
    if (!s_panel || !display_arbiter_is_owner(DISPLAY_ARBITER_OWNER_LUA)) {
        /* Another owner holds the panel; drop the frame but keep LVGL going. */
        lv_display_flush_ready(display);
        return;
    }

    const size_t pixel_count = (size_t)(area->x2 - area->x1 + 1) * (size_t)(area->y2 - area->y1 + 1);
    uint16_t *pixels = (uint16_t *)px_map;
    for (size_t i = 0; i < pixel_count; i++) {
        pixels[i] = __builtin_bswap16(pixels[i]);
    }

    esp_err_t err = esp_lcd_panel_draw_bitmap(s_panel, area->x1, area->y1,
                                              area->x2 + 1, area->y2 + 1, px_map);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "draw_bitmap failed: %s", esp_err_to_name(err));
        lv_display_flush_ready(display);
    }
}

static void ha_panel_tick_cb(void *arg)
{
    (void)arg;
    lv_tick_inc(HA_PANEL_TICK_MS);
}

/* ------------------------------------------------------------------ */
/* Storage bridge helpers                                             */
/* ------------------------------------------------------------------ */

/* Resolve a file name under the writable data root. Fails until app_fs_init()
 * has mounted the partition and claw_paths_set(CLAW_PATH_DATA, ...) ran, so
 * callers must tolerate an early ESP_ERR_INVALID_STATE. */
static bool ha_panel_data_path(const char *name, char *out, size_t out_size)
{
    return claw_paths_join(CLAW_PATH_DATA, name, out, out_size) == ESP_OK;
}

/* Read a text file under the data root into out (NUL-terminated, trailing
 * CR/LF stripped). Returns false when the file does not exist yet. */
static bool ha_panel_read_text(const char *name, char *out, size_t out_size)
{
    char path[128];
    if (!ha_panel_data_path(name, path, sizeof(path))) {
        return false;
    }
    FILE *file = fopen(path, "rb");
    if (!file) {
        return false;
    }
    size_t n = fread(out, 1, out_size - 1, file);
    fclose(file);
    out[n] = '\0';
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) {
        out[--n] = '\0';
    }
    return true;
}

/* Binary-safe read of a file under the data root: NUL-terminated, but CR/LF and
 * the \x1f/\x1e record separators are preserved (the conversation log encodes
 * its records with control chars). Returns false when the file is missing. */
static bool ha_panel_read_raw(const char *name, char *out, size_t out_size)
{
    char path[128];
    if (!ha_panel_data_path(name, path, sizeof(path))) {
        return false;
    }
    FILE *file = fopen(path, "rb");
    if (!file) {
        return false;
    }
    size_t n = fread(out, 1, out_size - 1, file);
    fclose(file);
    out[n] = '\0';
    return true;
}

/* ------------------------------------------------------------------ */
/* Page navigation                                                    */
/* ------------------------------------------------------------------ */

static void ha_panel_show_page(ha_page_t page)
{
    if (page >= HA_PAGE_COUNT) {
        return;
    }
    s_page = page;
    for (int i = 0; i < HA_PAGE_COUNT; i++) {
        if (!s_pages[i]) {
            continue;
        }
        if (i == (int)page) {
            lv_obj_remove_flag(s_pages[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(s_pages[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
    for (int i = 0; i < HA_PAGE_COUNT; i++) {
        if (!s_tab_btns[i]) {
            continue;
        }
        lv_obj_set_style_bg_color(s_tab_btns[i],
                                  lv_color_hex(i == (int)page ? HA_COLOR_TAB_ACTIVE : HA_COLOR_TABBAR), 0);
    }
}

static void ha_panel_tab_click_cb(lv_event_t *e)
{
    ha_page_t page = (ha_page_t)(intptr_t)lv_event_get_user_data(e);
    ha_panel_show_page(page);
}

/* ------------------------------------------------------------------ */
/* Voice bridge (Lua writes files, panel mirrors them)                 */
/* ------------------------------------------------------------------ */

/* Map a machine-readable status code (written by voice_common.lua) to the CJK
 * label shown on the panel and whether the voice tab badge should light. An
 * unknown code is treated as busy with a "未知" label so a future Lua code
 * never silently freezes the badge. */
typedef struct {
    const char *code;
    const char *label;
    bool busy;
} ha_voice_status_t;

static const ha_voice_status_t s_voice_status_map[] = {
    { "idle",         "空闲",   false },
    { "recording",    "录音中", true  },
    { "recognizing",  "识别中", true  },
    { "confirming",   "待确认", true  },
    { "thinking",     "思考中", true  },
    { "synthesizing", "合成中", true  },
    { "speaking",     "播报中", true  },
    { "error",        "出错",   true  },
};

/* Mirror voice_status.txt ("<code>|<detail>") onto the status label + tab dot. */
static void ha_panel_poll_status(void)
{
    if (!s_status_label) {
        return;
    }
    char raw[HA_VOICE_STATUS_MAX];
    if (!ha_panel_read_text(HA_VOICE_STATUS_FILE, raw, sizeof(raw)) ||
            strcmp(raw, s_status_raw) == 0) {
        return;
    }
    strlcpy(s_status_raw, raw, sizeof(s_status_raw));

    /* Split "<code>|<detail>"; detail is optional free text (failure reason). */
    const char *code = raw;
    const char *detail = strchr(raw, '|');
    char code_buf[32];
    if (detail) {
        size_t n = (size_t)(detail - raw);
        if (n >= sizeof(code_buf)) {
            n = sizeof(code_buf) - 1;
        }
        memcpy(code_buf, raw, n);
        code_buf[n] = '\0';
        code = code_buf;
        detail++;
    }

    const char *label = "未知";
    bool busy = true;   /* unknown code: assume a job is running */
    for (size_t i = 0; i < sizeof(s_voice_status_map) / sizeof(s_voice_status_map[0]); i++) {
        if (strcmp(code, s_voice_status_map[i].code) == 0) {
            label = s_voice_status_map[i].label;
            busy = s_voice_status_map[i].busy;
            break;
        }
    }

    char display[HA_VOICE_STATUS_MAX + 32];
    if (detail && detail[0]) {
        snprintf(display, sizeof(display), "状态: %s · %s", label, detail);
    } else {
        snprintf(display, sizeof(display), "状态: %s", label);
    }
    lv_label_set_text(s_status_label, display);
    ESP_LOGI(TAG, "voice status: code=%s detail=%s", code, (detail && detail[0]) ? detail : "-");

    if (s_voice_badge) {
        if (busy) {
            lv_obj_remove_flag(s_voice_badge, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(s_voice_badge, LV_OBJ_FLAG_HIDDEN);
        }
    }
}

/* Create one conversation bubble. The "你说:"/"AI 说:" prefix + text is built
 * in the PSRAM scratch buffer so a long reply never touches the 8 KB task
 * stack. Returns the created label (callers scroll the last one into view). */
static lv_obj_t *ha_panel_make_bubble(lv_obj_t *parent, char role, const char *text, size_t len)
{
    if (!s_voice_line) {
        return NULL;
    }
    const char *prefix = (role == 'A') ? "AI 说: " : "你说: ";
    size_t plen = strlen(prefix);
    size_t cap = HA_VOICE_TEXT_MAX + 16;
    if (plen >= cap) {
        return NULL;
    }
    memcpy(s_voice_line, prefix, plen);
    size_t copy = len;
    if (plen + copy >= cap) {
        copy = cap - plen - 1;
    }
    memcpy(s_voice_line + plen, text, copy);
    s_voice_line[plen + copy] = '\0';

    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, s_voice_line);
    lv_obj_set_style_text_color(label, lv_color_hex(role == 'A' ? HA_COLOR_ON : HA_COLOR_TEXT), 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(label, LV_PCT(100));
    return label;
}

/* Rebuild the bubble list from s_voice_log_buf ("<role>\x1f<text>\x1e" per
 * record). Parses the freshly-read buffer in place (not the snapshot, which
 * must stay intact for the next strcmp); renders only the newest records. */
static void ha_panel_rebuild_log(void)
{
    if (!s_voice_log || !s_voice_log_buf) {
        return;
    }

    char *recs[HA_VOICE_LOG_MAX * 2];
    size_t rec_len[HA_VOICE_LOG_MAX * 2];
    size_t rec_count = 0;

    char *p = s_voice_log_buf;
    while (*p && rec_count < sizeof(recs) / sizeof(recs[0])) {
        char *rs = strchr(p, HA_VOICE_RECORD_SEP);
        recs[rec_count] = p;
        rec_len[rec_count] = rs ? (size_t)(rs - p) : strlen(p);
        rec_count++;
        if (!rs) {
            break;
        }
        *rs = '\0';
        p = rs + 1;
    }

    size_t start = (rec_count > HA_VOICE_LOG_MAX) ? (rec_count - HA_VOICE_LOG_MAX) : 0;

    lv_obj_clean(s_voice_log);
    lv_obj_t *last = NULL;
    for (size_t i = start; i < rec_count; i++) {
        char *rec = recs[i];
        char role = rec[0];
        char *fs = memchr(rec, HA_VOICE_FIELD_SEP, rec_len[i]);
        const char *text = fs ? fs + 1 : "";
        size_t tlen = fs ? rec_len[i] - (size_t)(fs + 1 - rec) : 0;
        last = ha_panel_make_bubble(s_voice_log, role, text, tlen);
    }
    if (last) {
        lv_obj_scroll_to_view(last, LV_ANIM_OFF);
    }
    ESP_LOGI(TAG, "voice log rebuilt: %u record(s)", (unsigned)rec_count);
}

/* Mirror voice_log.txt onto the scrollable bubble list, only when it changed. */
static void ha_panel_poll_voice_log(void)
{
    if (!s_voice_log || !s_voice_log_buf || !s_voice_log_snap) {
        return;
    }
    if (!ha_panel_read_raw(HA_VOICE_LOG_FILE, s_voice_log_buf, HA_VOICE_LOG_BYTES) ||
            strcmp(s_voice_log_buf, s_voice_log_snap) == 0) {
        return;
    }
    strlcpy(s_voice_log_snap, s_voice_log_buf, HA_VOICE_LOG_BYTES);
    ha_panel_rebuild_log();
}

static void ha_panel_poll_voice(void)
{
    ha_panel_ensure_font();
    ha_panel_poll_status();
    ha_panel_poll_voice_log();
}

/* The screen can be taken back from the panel at runtime (e.g. the Lua
 * `display` module released the arbiter on script exit). Re-assert ownership
 * from the render loop, and force a full-screen redraw on recovery: the other
 * owner may have painted over the framebuffer, and LVGL only repaints
 * invalidated areas, so stale pixels would otherwise stay on screen. */
static void ha_panel_claim_display(void)
{
    if (display_arbiter_is_owner(DISPLAY_ARBITER_OWNER_LUA)) {
        return;
    }
    (void)display_arbiter_acquire(DISPLAY_ARBITER_OWNER_LUA);
    lv_obj_invalidate(lv_screen_active());
}

/* ------------------------------------------------------------------ */
/* Runtime config bridge (C writes JSON, Lua reads it)                 */
/* ------------------------------------------------------------------ */

static void ha_panel_json_escape(const char *src, char *dst, size_t dst_size)
{
    size_t j = 0;
    if (!dst || dst_size == 0) {
        return;
    }
    for (size_t i = 0; src && src[i] && j + 1 < dst_size; i++) {
        unsigned char c = (unsigned char)src[i];
        const char *rep = NULL;
        char buf[8];
        switch (c) {
            case '"':  rep = "\\\""; break;
            case '\\': rep = "\\\\"; break;
            case '\n': rep = "\\n";  break;
            case '\r': rep = "\\r";  break;
            case '\t': rep = "\\t";  break;
            default:
                if (c < 0x20) {
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    rep = buf;
                }
                break;
        }
        if (rep) {
            size_t rl = strlen(rep);
            if (j + rl >= dst_size) {
                break;
            }
            memcpy(dst + j, rep, rl);
            j += rl;
        } else {
            dst[j++] = (char)c;
        }
    }
    dst[j] = '\0';
}

static void ha_panel_write_json_field(FILE *f, const char *key, const char *value, bool last)
{
    char *esc = heap_caps_malloc(APP_CONFIG_STR_LEN * 6 + 1, MALLOC_CAP_SPIRAM);
    if (!esc) {
        return;
    }
    ha_panel_json_escape(value ? value : "", esc, APP_CONFIG_STR_LEN * 6 + 1);
    fprintf(f, "  \"%s\": \"%s\"%s\n", key, esc, last ? "" : ",");
    free(esc);
}

static bool ha_panel_str_is_on(const char *value)
{
    return value && (strcmp(value, "true") == 0 || strcmp(value, "1") == 0);
}

/* A page is available only when its backing feature is enabled in the Web
 * config; the device-info page is always available. */
static bool ha_panel_page_enabled(ha_page_t page, const app_config_t *cfg)
{
    switch (page) {
    case HA_PAGE_PANEL:
        return ha_panel_str_is_on(cfg->ha_enabled);
    case HA_PAGE_VOICE:
        return ha_panel_str_is_on(cfg->voice_enabled);
    case HA_PAGE_INFO:
    default:
        return true;
    }
}

/* Show/hide each page container and its tab button to match the enable flags,
 * then keep the current page pointing at an enabled page. Holds the LVGL lock
 * (called from the publish path). */
static void ha_panel_apply_gating(const app_config_t *cfg)
{
    int first_enabled = -1;
    for (int i = 0; i < HA_PAGE_COUNT; i++) {
        bool enabled = ha_panel_page_enabled((ha_page_t)i, cfg);
        s_page_enabled[i] = enabled;
        if (enabled && first_enabled < 0) {
            first_enabled = i;
        }
        if (s_tab_btns[i]) {
            if (enabled) {
                lv_obj_remove_flag(s_tab_btns[i], LV_OBJ_FLAG_HIDDEN);
            } else {
                lv_obj_add_flag(s_tab_btns[i], LV_OBJ_FLAG_HIDDEN);
            }
        }
    }

    if (first_enabled < 0) {
        return;   /* every page disabled: leave the screen as-is */
    }
    if (!ha_panel_page_enabled(s_page, cfg)) {
        s_page = (ha_page_t)first_enabled;
    }
    ha_panel_show_page(s_page);
}

/* Wake listener callback: runs in the listener task, so only flag the jump. */
static void ha_panel_on_wake_event(void)
{
    s_wake_jump_pending = true;
}

/* Set a label's text (and colour) only when the cached string changed, so a
 * 200ms poll does not force a redraw of unchanged rows. */
static void ha_panel_set_label(lv_obj_t *label, char *cache, size_t cache_size,
                               const char *text, lv_color_t color)
{
    if (!label || !cache || cache_size == 0) {
        return;
    }
    if (strcmp(cache, text) == 0) {
        return;
    }
    strlcpy(cache, text, cache_size);
    lv_label_set_text(label, cache);
    lv_obj_set_style_text_color(label, color, 0);
}

/* Panel page: HA link state. The page is only reachable when HA is enabled;
 * "已配置" means a base URL is set. Entity cards replace this once the HA
 * WebSocket client is wired up. */
static void ha_panel_refresh_panel(const app_config_t *cfg)
{
    bool configured = cfg->ha_base_url[0] != '\0';

    char state[64];
    snprintf(state, sizeof(state), "状态: %s", configured ? "已配置 · 未接入" : "未配置");
    ha_panel_set_label(s_panel_ha_state_label, s_panel_ha_state_text, sizeof(s_panel_ha_state_text),
                       state, lv_color_hex(configured ? HA_COLOR_TEXT : HA_COLOR_OFF));

    char url[APP_CONFIG_STR_LEN + 16];
    snprintf(url, sizeof(url), "地址: %s", configured ? cfg->ha_base_url : "(未配置)");
    ha_panel_set_label(s_panel_ha_url_label, s_panel_ha_url_text, sizeof(s_panel_ha_url_text),
                       url, lv_color_hex(HA_COLOR_TEXT_DIM));
}

/* Device page, network group: configured SSID + live connection state + IP +
 * AP hotspot (name/IP). wifi_manager keeps sta_ip/ap_ip as static strings
 * (never NULL; "0.0.0.0" when unset), so the IP rows only show a value once it
 * is meaningful. */
static void ha_panel_refresh_network(void)
{
    wifi_manager_status_t st;
    memset(&st, 0, sizeof(st));
    wifi_manager_get_status(&st);

    const char *name = s_info_wifi_ssid[0] ? s_info_wifi_ssid :
                       (st.ap_ssid && st.ap_ssid[0] ? st.ap_ssid : NULL);
    char name_line[APP_CONFIG_STR_LEN + 16];
    snprintf(name_line, sizeof(name_line), "网络: %s", name ? name : "(未设置)");
    ha_panel_set_label(s_info_net_name_label, s_info_net_name_text, sizeof(s_info_net_name_text),
                       name_line, lv_color_hex(HA_COLOR_TEXT));

    const char *state_text;
    lv_color_t state_color;
    const char *ip;
    if (st.sta_connected) {
        state_text = "已连接";
        state_color = lv_color_hex(HA_COLOR_ON);
        ip = st.sta_ip;
    } else if (st.ap_active) {
        state_text = "AP 模式";
        state_color = lv_color_hex(HA_COLOR_TEXT_DIM);
        ip = st.ap_ip;
    } else if (st.sta_configured) {
        state_text = "未连接";
        state_color = lv_color_hex(HA_COLOR_OFF);
        ip = st.sta_ip;
    } else {
        state_text = "未设置";
        state_color = lv_color_hex(HA_COLOR_OFF);
        ip = NULL;
    }

    char state_line[64];
    snprintf(state_line, sizeof(state_line), "连接: %s", state_text);
    ha_panel_set_label(s_info_net_state_label, s_info_net_state_text, sizeof(s_info_net_state_text),
                       state_line, state_color);

    char ip_line[64];
    snprintf(ip_line, sizeof(ip_line), "IP 地址: %s",
             (ip && ip[0] && strcmp(ip, "0.0.0.0") != 0) ? ip : "-");
    ha_panel_set_label(s_info_net_ip_label, s_info_net_ip_text, sizeof(s_info_net_ip_text),
                       ip_line, lv_color_hex(HA_COLOR_TEXT_DIM));

    /* AP hotspot: name + gateway IP so the provisioning AP is identifiable even
     * when a STA SSID is also configured (name row would show the STA one). */
    char ap_line[96];
    if (st.ap_active) {
        const char *ap_ssid = (st.ap_ssid && st.ap_ssid[0]) ? st.ap_ssid : "-";
        const char *ap_ip = (st.ap_ip && st.ap_ip[0] && strcmp(st.ap_ip, "0.0.0.0") != 0)
                                ? st.ap_ip : "-";
        snprintf(ap_line, sizeof(ap_line), "AP 热点: %s · %s", ap_ssid, ap_ip);
    } else {
        snprintf(ap_line, sizeof(ap_line), "AP 热点: 未开启");
    }
    ha_panel_set_label(s_info_net_ap_label, s_info_net_ap_text, sizeof(s_info_net_ap_text),
                       ap_line, lv_color_hex(st.ap_active ? HA_COLOR_ON : HA_COLOR_OFF));
}

static void ha_panel_refresh_info(const app_config_t *cfg)
{
    /* LLM: configured when an API key or a custom base URL is present; the
     * model row mirrors the configured model (falling back to "-"). */
    bool llm_set = cfg->llm_api_key[0] != '\0' || cfg->llm_base_url[0] != '\0';
    char llm_state[64];
    snprintf(llm_state, sizeof(llm_state), "状态: %s", llm_set ? "已设置" : "未设置");
    ha_panel_set_label(s_info_llm_state_label, s_info_llm_state_text, sizeof(s_info_llm_state_text),
                       llm_state, lv_color_hex(llm_set ? HA_COLOR_ON : HA_COLOR_OFF));

    char llm_model[APP_CONFIG_STR_LEN + 16];
    snprintf(llm_model, sizeof(llm_model), "模型: %s",
             (llm_set && cfg->llm_model[0]) ? cfg->llm_model : "-");
    ha_panel_set_label(s_info_llm_model_label, s_info_llm_model_text, sizeof(s_info_llm_model_text),
                       llm_model, lv_color_hex(HA_COLOR_TEXT_DIM));

    /* IM: per-channel credential presence. A channel counts as "已设" when its
     * identifying field is non-empty; no fabricated "connected" state. */
    bool im_wechat = cfg->wechat_token[0] != '\0';
    bool im_feishu = cfg->feishu_app_id[0] != '\0';
    bool im_qq = cfg->qq_app_id[0] != '\0';
    bool im_tg = cfg->tg_bot_token[0] != '\0';
    int im_count = (int)im_wechat + (int)im_feishu + (int)im_qq + (int)im_tg;

    char im_state[64];
    snprintf(im_state, sizeof(im_state), "已设置: %d/4", im_count);
    ha_panel_set_label(s_info_im_state_label, s_info_im_state_text, sizeof(s_info_im_state_text),
                       im_state, lv_color_hex(im_count > 0 ? HA_COLOR_ON : HA_COLOR_OFF));

    char im_line1[64];
    snprintf(im_line1, sizeof(im_line1), "微信 %s    飞书 %s",
             im_wechat ? "已设" : "未设", im_feishu ? "已设" : "未设");
    ha_panel_set_label(s_info_im_channel1_label, s_info_im_channel1_text, sizeof(s_info_im_channel1_text),
                       im_line1, lv_color_hex(HA_COLOR_TEXT_DIM));

    char im_line2[64];
    snprintf(im_line2, sizeof(im_line2), "QQ %s    电报 %s",
             im_qq ? "已设" : "未设", im_tg ? "已设" : "未设");
    ha_panel_set_label(s_info_im_channel2_label, s_info_im_channel2_text, sizeof(s_info_im_channel2_text),
                       im_line2, lv_color_hex(HA_COLOR_TEXT_DIM));

    /* Voice: wake gate + ASR/TTS endpoint configuration. */
    bool wake = ha_panel_str_is_on(cfg->voice_wake_enabled);
    char wake_text[64];
    snprintf(wake_text, sizeof(wake_text), "语音唤醒: %s", wake ? "已启用" : "已关闭");
    ha_panel_set_label(s_info_wake_label, s_info_wake_text, sizeof(s_info_wake_text),
                       wake_text, lv_color_hex(wake ? HA_COLOR_ON : HA_COLOR_OFF));

    char asr_text[64];
    snprintf(asr_text, sizeof(asr_text), "ASR: %s", cfg->voice_asr_url[0] ? "已配置" : "未配置");
    ha_panel_set_label(s_info_asr_label, s_info_asr_text, sizeof(s_info_asr_text),
                       asr_text, lv_color_hex(HA_COLOR_TEXT_DIM));

    char tts_text[64];
    snprintf(tts_text, sizeof(tts_text), "TTS: %s", cfg->voice_tts_url[0] ? "已配置" : "未配置");
    ha_panel_set_label(s_info_tts_label, s_info_tts_text, sizeof(s_info_tts_text),
                       tts_text, lv_color_hex(HA_COLOR_TEXT_DIM));

    /* Reply-mode toggle: resync from the persisted value so the on-device button
     * also reflects changes written from the Web UI. */
    s_reply_mode_direct = (strcmp(cfg->voice_reply_mode, "direct") == 0);
    ha_panel_reply_mode_set_label(s_reply_mode_direct);

    /* Cache the configured SSID, then refresh the live network rows and the
     * panel-page HA link state from the same freshly-loaded config. */
    strlcpy(s_info_wifi_ssid, cfg->wifi_ssid, sizeof(s_info_wifi_ssid));
    ha_panel_refresh_network();
    ha_panel_refresh_panel(cfg);
}

esp_err_t ha_panel_publish_runtime_config(void)
{
    char path[128];
    if (!ha_panel_data_path(HA_RUNTIME_CONFIG_FILE, path, sizeof(path))) {
        /* Filesystem/claw_paths not ready yet; the panel task retries. */
        return ESP_ERR_INVALID_STATE;
    }

    app_config_t *cfg = heap_caps_calloc(1, sizeof(*cfg), MALLOC_CAP_SPIRAM);
    if (!cfg) {
        return ESP_ERR_NO_MEM;
    }
    esp_err_t err = app_config_load(cfg);
    if (err != ESP_OK) {
        free(cfg);
        ESP_LOGW(TAG, "runtime config: app_config_load failed: %s", esp_err_to_name(err));
        return err;
    }

    FILE *f = fopen(path, "w");
    if (!f) {
        free(cfg);
        ESP_LOGW(TAG, "runtime config: cannot open %s", path);
        return ESP_FAIL;
    }
    fprintf(f, "{\n");
    ha_panel_write_json_field(f, "ha_enabled", cfg->ha_enabled, false);
    ha_panel_write_json_field(f, "ha_base_url", cfg->ha_base_url, false);
    ha_panel_write_json_field(f, "ha_token", cfg->ha_token, false);
    ha_panel_write_json_field(f, "voice_enabled", cfg->voice_enabled, false);
    ha_panel_write_json_field(f, "voice_wake_enabled", cfg->voice_wake_enabled, false);
    ha_panel_write_json_field(f, "voice_asr_url", cfg->voice_asr_url, false);
    ha_panel_write_json_field(f, "voice_asr_api_key", cfg->voice_asr_api_key, false);
    ha_panel_write_json_field(f, "voice_asr_provider", cfg->voice_asr_provider, false);
    ha_panel_write_json_field(f, "voice_asr_resource_id", cfg->voice_asr_resource_id, false);
    ha_panel_write_json_field(f, "voice_tts_url", cfg->voice_tts_url, false);
    ha_panel_write_json_field(f, "voice_tts_provider", cfg->voice_tts_provider, false);
    ha_panel_write_json_field(f, "voice_tts_resource_id", cfg->voice_tts_resource_id, false);
    ha_panel_write_json_field(f, "voice_tts_speaker", cfg->voice_tts_speaker, false);
    ha_panel_write_json_field(f, "voice_volume", cfg->voice_volume, false);
    ha_panel_write_json_field(f, "voice_reply_mode", cfg->voice_reply_mode, false);
    ha_panel_write_json_field(f, "voice_send_mode", cfg->voice_send_mode, false);
    ha_panel_write_json_field(f, "voice_tts_stream", cfg->voice_tts_stream, false);
    ha_panel_write_json_field(f, "voice_tts_api_key", cfg->voice_tts_api_key, true);
    fprintf(f, "}\n");
    fclose(f);

    if (ha_panel_lock()) {
        ha_panel_refresh_info(cfg);
        ha_panel_apply_gating(cfg);
        ha_panel_unlock();
    }

    ESP_LOGI(TAG, "runtime config published: %s (ha_enabled=%s voice_enabled=%s wake_enabled=%s)",
             path, cfg->ha_enabled, cfg->voice_enabled, cfg->voice_wake_enabled);
    free(cfg);
    return ESP_OK;
}

/* Persist a pending reply-mode toggle to NVS. Called from the panel task
 * outside the LVGL lock (NVS I/O); returns true when a write happened so the
 * caller can re-publish the runtime JSON for the Lua skills. */
static bool ha_panel_commit_reply_mode(void)
{
    if (!s_reply_mode_dirty) {
        return false;
    }
    s_reply_mode_dirty = false;

    app_config_t *cfg = heap_caps_calloc(1, sizeof(*cfg), MALLOC_CAP_SPIRAM);
    if (!cfg) {
        return false;
    }
    if (app_config_load(cfg) == ESP_OK) {
        strlcpy(cfg->voice_reply_mode, s_reply_mode_direct ? "direct" : "agent",
                sizeof(cfg->voice_reply_mode));
        if (app_config_save(cfg) != ESP_OK) {
            ESP_LOGW(TAG, "failed to persist voice_reply_mode");
        }
    }
    free(cfg);
    return true;
}

/* ------------------------------------------------------------------ */
/* Render task                                                        */
/* ------------------------------------------------------------------ */

/* Enter/leave standby: the panel task stops calling lv_timer_handler() while
 * s_standby is set (which freezes the UI and ignores touch, since the indev is
 * only read from there) and the backlight is dimmed. Only the backlight is
 * touched, so the persisted brightness survives; the LCD keeps the last frame
 * and shows it again as soon as the backlight comes back on. */
static void ha_panel_set_standby(bool on)
{
    if (s_standby == on) {
        return;
    }
    s_standby = on;
    ha_panel_settings_set_backlight_enabled(!on);
    ESP_LOGI(TAG, "%s (PWR click)", on ? "standby: screen off" : "resumed: screen on");
}

static void ha_panel_task(void *arg)
{
    (void)arg;
    uint32_t tick = 0;
    bool runtime_published = false;
    while (1) {
        const bool poll_cycle = (tick % HA_VOICE_POLL_CYCLES) == 0;
        bool wake_jump = false;

        /* PWR button: a single click toggles standby; a long press is ignored
         * here (the AXP2101's PWRON turns the board off by itself). Polled with
         * the LVGL lock released - the backlight write does not need it - so the
         * toggle also works while the screen is off and rendering is skipped. */
        if (ha_panel_power_poll_press()) {
            ha_panel_set_standby(!s_standby);
        }

        /* A wake-word hit always returns to the running mode first, so the reply
         * is visible even if the panel was in standby. */
        if (s_wake_jump_pending) {
            s_wake_jump_pending = false;
            wake_jump = true;
            ha_panel_set_standby(false);
        }

        /* Publish outside the LVGL lock: it does NVS + file I/O and only takes
         * the lock internally to refresh the info labels (never re-entered). */
        if (poll_cycle && !runtime_published && ha_panel_publish_runtime_config() == ESP_OK) {
            runtime_published = true;   /* publish once the FS is ready */
        }

        /* Settings sliders persist to NVS here (outside the LVGL lock); a
         * volume change also has to be re-published so the voice Lua TTS plays
         * the next reply at the new level. */
        if (ha_panel_settings_commit_pending()) {
            (void)ha_panel_publish_runtime_config();
        }

        /* Deferred "网络" work (Wi-Fi scan / STA apply + NVS save) blocks for
         * seconds, so it runs here with the LVGL lock released; results are
         * rendered by ha_panel_settings_poll() on a later locked tick. */
        ha_panel_settings_service();

        /* Voice-page reply-mode toggle persists here too, and needs the runtime
         * JSON re-published so the Lua skills pick the new chat id (≤1s). */
        if (ha_panel_commit_reply_mode()) {
            (void)ha_panel_publish_runtime_config();
        }

        if (ha_panel_lock()) {
            ha_panel_claim_display();
            /* In standby the screen is off: skipping lv_timer_handler() freezes
             * the UI and with it touch handling, and the periodic timers simply
             * catch up (they are not queued) on the first tick after resume. */
            if (!s_standby) {
                /* Live settings content (system load); internally throttled. */
                ha_panel_settings_poll();
                /* On a wake-word hit, bring the voice page to front (only when
                 * voice is enabled, i.e. the page exists). */
                if (wake_jump && s_page_enabled[HA_PAGE_VOICE] && s_page != HA_PAGE_VOICE) {
                    ha_panel_show_page(HA_PAGE_VOICE);
                    ESP_LOGI(TAG, "wake detected -> jumped to voice page");
                }
                if (poll_cycle) {
                    ha_panel_poll_voice();
                    /* WiFi state changes without a config write, so poll it live. */
                    ha_panel_refresh_network();
                }
                lv_timer_handler();
            }
            ha_panel_unlock();
        }
        tick++;
        vTaskDelay(pdMS_TO_TICKS(HA_PANEL_TASK_PERIOD_MS));
    }
}

static void ha_panel_touch_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    esp_lcd_touch_handle_t tp = (esp_lcd_touch_handle_t)lv_indev_get_user_data(indev);
    esp_lcd_touch_point_data_t point = {0};
    uint8_t point_count = 0;

    if (!tp) {
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }

    /* Best-effort polling read; a single I2C glitch must not stall the indev. */
    (void)esp_lcd_touch_read_data(tp);
    if (esp_lcd_touch_get_data(tp, &point, &point_count, 1) == ESP_OK && point_count > 0) {
        data->point.x = (int32_t)point.x;
        data->point.y = (int32_t)point.y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

/* ------------------------------------------------------------------ */
/* Page widgets                                                       */
/* ------------------------------------------------------------------ */

/* A standard page container: full size, dark card background, column flex. */
static lv_obj_t *ha_panel_make_page(lv_obj_t *parent)
{
    lv_obj_t *page = lv_obj_create(parent);
    lv_obj_set_size(page, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(page, lv_color_hex(HA_COLOR_BG), 0);
    lv_obj_set_style_border_width(page, 0, 0);
    lv_obj_set_style_radius(page, 10, 0);
    lv_obj_set_style_pad_all(page, 8, 0);
    lv_obj_set_style_pad_row(page, 8, 0);
    lv_obj_set_flex_flow(page, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(page, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
    lv_obj_clear_flag(page, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(page, LV_OBJ_FLAG_HIDDEN);
    return page;
}

static lv_obj_t *ha_panel_make_info_label(lv_obj_t *page, lv_color_t color)
{
    lv_obj_t *label = lv_label_create(page);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(label, LV_PCT(100));
    lv_obj_set_style_text_color(label, color, 0);
    return label;
}

/* A titled section card for the device page; the caller adds the value rows
 * inside it with ha_panel_make_info_label(). Height tracks content so the
 * page can scroll when several cards are stacked. */
static lv_obj_t *ha_panel_make_info_card(lv_obj_t *page, const char *title)
{
    lv_obj_t *card = lv_obj_create(page);
    lv_obj_set_width(card, LV_PCT(100));
    lv_obj_set_height(card, LV_SIZE_CONTENT);
    lv_obj_set_style_bg_color(card, lv_color_hex(HA_COLOR_CARD), 0);
    lv_obj_set_style_border_width(card, 0, 0);
    lv_obj_set_style_radius(card, 10, 0);
    lv_obj_set_style_pad_all(card, 10, 0);
    lv_obj_set_style_pad_row(card, 4, 0);
    lv_obj_set_flex_flow(card, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(card, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *title_label = lv_label_create(card);
    lv_label_set_text(title_label, title);
    lv_obj_set_style_text_color(title_label, lv_color_hex(HA_COLOR_SECTION), 0);
    return card;
}

static void ha_panel_build_panel_page(lv_obj_t *page)
{
    /* HA link-state card; entity cards are added here once the HA WebSocket
     * client exists, so there is no placeholder/mock data. */
    lv_obj_t *card = ha_panel_make_info_card(page, "Home Assistant");
    s_panel_ha_state_label = ha_panel_make_info_label(card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_panel_ha_state_label, "状态: 未配置");
    s_panel_ha_url_label = ha_panel_make_info_label(card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_panel_ha_url_label, "地址: (未配置)");

    lv_obj_t *note = ha_panel_make_info_label(page, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(note, "接入 Home Assistant 后,\n此页显示实体与场景。");
}

static void ha_panel_reply_mode_set_label(bool direct)
{
    if (!s_reply_mode_label) {
        return;
    }
    lv_label_set_text_fmt(s_reply_mode_label, "模式: %s", direct ? "直答" : "智能体");
    lv_obj_set_style_text_color(s_reply_mode_label,
                                lv_color_hex(direct ? HA_COLOR_ON : HA_COLOR_TEXT_DIM), 0);
}

static void ha_panel_reply_mode_cb(lv_event_t *e)
{
    (void)e;
    s_reply_mode_direct = !s_reply_mode_direct;
    ha_panel_reply_mode_set_label(s_reply_mode_direct);
    /* The panel task persists to NVS and re-publishes the runtime JSON outside
     * the LVGL lock (same deferred pattern as the settings sliders). */
    s_reply_mode_dirty = true;
}

static void ha_panel_build_voice_page(lv_obj_t *page)
{
    lv_obj_t *voice = lv_obj_create(page);
    lv_obj_set_width(voice, LV_PCT(100));
    lv_obj_set_height(voice, LV_PCT(100));
    lv_obj_set_style_bg_color(voice, lv_color_hex(HA_COLOR_CARD), 0);
    lv_obj_set_style_border_width(voice, 0, 0);
    lv_obj_set_style_radius(voice, 10, 0);
    lv_obj_set_style_pad_all(voice, 8, 0);
    lv_obj_set_style_pad_row(voice, 6, 0);
    lv_obj_set_flex_flow(voice, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(voice, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_clear_flag(voice, LV_OBJ_FLAG_SCROLLABLE);

    /* Top row: pipeline status (left) + reply-mode toggle (right). */
    lv_obj_t *top = lv_obj_create(voice);
    lv_obj_set_width(top, LV_PCT(100));
    lv_obj_set_height(top, LV_SIZE_CONTENT);
    lv_obj_set_style_bg_opa(top, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(top, 0, 0);
    lv_obj_set_style_pad_all(top, 0, 0);
    lv_obj_clear_flag(top, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(top, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(top, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

    s_status_label = lv_label_create(top);
    lv_label_set_text(s_status_label, "状态: 空闲");
    lv_obj_set_style_text_color(s_status_label, lv_color_hex(HA_COLOR_TEXT_DIM), 0);

    lv_obj_t *mode_btn = lv_button_create(top);
    lv_obj_set_height(mode_btn, 34);
    lv_obj_set_style_bg_color(mode_btn, lv_color_hex(HA_COLOR_TABBAR), 0);
    lv_obj_set_style_shadow_width(mode_btn, 0, 0);
    lv_obj_set_style_pad_hor(mode_btn, 10, 0);
    lv_obj_add_event_cb(mode_btn, ha_panel_reply_mode_cb, LV_EVENT_CLICKED, NULL);
    s_reply_mode_label = lv_label_create(mode_btn);
    ha_panel_reply_mode_set_label(s_reply_mode_direct);
    lv_obj_center(s_reply_mode_label);

    /* Scrollable conversation history: one bubble per record, newest at the
     * bottom. Transparent container so only the bubbles show against the card;
     * the status line above stays pinned while the log scrolls. */
    lv_obj_t *log = lv_obj_create(voice);
    lv_obj_set_width(log, LV_PCT(100));
    lv_obj_set_flex_grow(log, 1);
    lv_obj_set_style_bg_opa(log, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(log, 0, 0);
    lv_obj_set_style_pad_all(log, 0, 0);
    lv_obj_set_style_pad_row(log, 6, 0);
    lv_obj_set_flex_flow(log, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(log, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_add_flag(log, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scroll_dir(log, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(log, LV_SCROLLBAR_MODE_AUTO);
    s_voice_log = log;
}

static void ha_panel_build_info_page(lv_obj_t *page)
{
    /* Four status cards exceed one screen, so allow vertical scrolling. */
    lv_obj_add_flag(page, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scroll_dir(page, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(page, LV_SCROLLBAR_MODE_AUTO);

    /* Network: configured SSID + live connection state + IP. */
    lv_obj_t *net_card = ha_panel_make_info_card(page, "网络");
    s_info_net_name_label = ha_panel_make_info_label(net_card, lv_color_hex(HA_COLOR_TEXT));
    lv_label_set_text(s_info_net_name_label, "网络: (未设置)");
    s_info_net_state_label = ha_panel_make_info_label(net_card, lv_color_hex(HA_COLOR_OFF));
    lv_label_set_text(s_info_net_state_label, "连接: 未设置");
    s_info_net_ip_label = ha_panel_make_info_label(net_card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_info_net_ip_label, "IP 地址: -");
    s_info_net_ap_label = ha_panel_make_info_label(net_card, lv_color_hex(HA_COLOR_OFF));
    lv_label_set_text(s_info_net_ap_label, "AP 热点: 未开启");

    /* LLM: configured flag + configured model. */
    lv_obj_t *llm_card = ha_panel_make_info_card(page, "LLM");
    s_info_llm_state_label = ha_panel_make_info_label(llm_card, lv_color_hex(HA_COLOR_OFF));
    lv_label_set_text(s_info_llm_state_label, "状态: 未设置");
    s_info_llm_model_label = ha_panel_make_info_label(llm_card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_info_llm_model_label, "模型: -");

    /* IM: how many channels are configured + per-channel markers. */
    lv_obj_t *im_card = ha_panel_make_info_card(page, "IM");
    s_info_im_state_label = ha_panel_make_info_label(im_card, lv_color_hex(HA_COLOR_OFF));
    lv_label_set_text(s_info_im_state_label, "已设置: 0/4");
    s_info_im_channel1_label = ha_panel_make_info_label(im_card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_info_im_channel1_label, "微信 未设    飞书 未设");
    s_info_im_channel2_label = ha_panel_make_info_label(im_card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_info_im_channel2_label, "QQ 未设    电报 未设");

    /* Voice: wake gate + ASR/TTS endpoint configuration. */
    lv_obj_t *voice_card = ha_panel_make_info_card(page, "语音");
    s_info_wake_label = ha_panel_make_info_label(voice_card, lv_color_hex(HA_COLOR_OFF));
    lv_label_set_text(s_info_wake_label, "语音唤醒: 已关闭");
    s_info_asr_label = ha_panel_make_info_label(voice_card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_info_asr_label, "ASR: 未配置");
    s_info_tts_label = ha_panel_make_info_label(voice_card, lv_color_hex(HA_COLOR_TEXT_DIM));
    lv_label_set_text(s_info_tts_label, "TTS: 未配置");

    lv_obj_t *hint = lv_label_create(page);
    lv_label_set_text(hint, "配置请在 ESP-Claw 网页端修改");
    lv_obj_set_style_text_color(hint, lv_color_hex(HA_COLOR_TEXT_DIM), 0);
    lv_label_set_long_mode(hint, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(hint, LV_PCT(100));
    s_hint_label = hint;   /* pick up the deferred CJK font */
}

static void ha_panel_build_tabbar(lv_obj_t *parent)
{
    static const char *titles[HA_PAGE_COUNT] = { "面板", "语音", "设备" };

    lv_obj_t *bar = lv_obj_create(parent);
    lv_obj_set_width(bar, LV_PCT(100));
    lv_obj_set_height(bar, 44);
    lv_obj_set_style_bg_color(bar, lv_color_hex(HA_COLOR_TABBAR), 0);
    lv_obj_set_style_border_width(bar, 0, 0);
    lv_obj_set_style_radius(bar, 10, 0);
    lv_obj_set_style_pad_all(bar, 4, 0);
    lv_obj_set_style_pad_column(bar, 6, 0);
    lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW);
    lv_obj_clear_flag(bar, LV_OBJ_FLAG_SCROLLABLE);

    for (int i = 0; i < HA_PAGE_COUNT; i++) {
        lv_obj_t *btn = lv_button_create(bar);
        lv_obj_set_height(btn, LV_PCT(100));
        lv_obj_set_flex_grow(btn, 1);
        lv_obj_set_style_bg_color(btn, lv_color_hex(i == 0 ? HA_COLOR_TAB_ACTIVE : HA_COLOR_TABBAR), 0);
        lv_obj_set_style_shadow_width(btn, 0, 0);
        lv_obj_add_event_cb(btn, ha_panel_tab_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);

        lv_obj_t *label = lv_label_create(btn);
        lv_label_set_text(label, titles[i]);
        lv_obj_center(label);

        s_tab_btns[i] = btn;

        if (i == HA_PAGE_VOICE) {
            /* Small dot on the voice tab while recording/thinking. */
            s_voice_badge = lv_obj_create(btn);
            lv_obj_set_size(s_voice_badge, 10, 10);
            lv_obj_set_style_radius(s_voice_badge, LV_RADIUS_CIRCLE, 0);
            lv_obj_set_style_bg_color(s_voice_badge, lv_color_hex(HA_COLOR_ON), 0);
            lv_obj_set_style_border_width(s_voice_badge, 0, 0);
            lv_obj_set_style_pad_all(s_voice_badge, 0, 0);
            lv_obj_align(s_voice_badge, LV_ALIGN_TOP_RIGHT, -6, 6);
            lv_obj_clear_flag(s_voice_badge, LV_OBJ_FLAG_SCROLLABLE);
            lv_obj_add_flag(s_voice_badge, LV_OBJ_FLAG_HIDDEN);
        }
    }
}

static void ha_panel_build_ui(void)
{
    lv_obj_t *screen = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(screen, lv_color_hex(HA_COLOR_BG), 0);
    lv_obj_set_style_pad_all(screen, 8, 0);
    lv_obj_set_style_pad_row(screen, 8, 0);
    lv_obj_set_flex_flow(screen, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(screen, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
    lv_obj_clear_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *header = lv_obj_create(screen);
    lv_obj_set_width(header, LV_PCT(100));
    lv_obj_set_height(header, 40);
    lv_obj_set_style_bg_color(header, lv_color_hex(HA_COLOR_HEADER), 0);
    lv_obj_set_style_border_width(header, 0, 0);
    lv_obj_set_style_radius(header, 10, 0);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *title = lv_label_create(header);
    lv_label_set_text(title, "嗨小欧");
    ha_panel_apply_font(title);
    s_title_label = title;
    lv_obj_set_style_text_color(title, lv_color_hex(HA_COLOR_TEXT), 0);
    lv_obj_align(title, LV_ALIGN_LEFT_MID, 4, 0);

    /* Body holds the three pages; only the current one is visible. The pages
     * are full-size siblings inside a plain (non-flex) container. */
    lv_obj_t *body = lv_obj_create(screen);
    lv_obj_set_width(body, LV_PCT(100));
    lv_obj_set_flex_grow(body, 1);
    lv_obj_set_style_bg_opa(body, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(body, 0, 0);
    lv_obj_set_style_pad_all(body, 0, 0);
    lv_obj_clear_flag(body, LV_OBJ_FLAG_SCROLLABLE);

    for (int i = 0; i < HA_PAGE_COUNT; i++) {
        s_pages[i] = ha_panel_make_page(body);
    }
    ha_panel_build_panel_page(s_pages[HA_PAGE_PANEL]);
    ha_panel_build_voice_page(s_pages[HA_PAGE_VOICE]);
    ha_panel_build_info_page(s_pages[HA_PAGE_INFO]);

    ha_panel_build_tabbar(screen);

    /* Settings overlay (header button + volume/brightness/system-load menus).
     * Built last so it paints on top of the tab bar and pages. */
    ha_panel_settings_attach(header, screen);

    lv_screen_load(screen);
    ha_panel_show_page(HA_PAGE_PANEL);
}

/* ------------------------------------------------------------------ */
/* Board manager glue                                                 */
/* ------------------------------------------------------------------ */

static esp_err_t ha_panel_load_board(void)
{
    void *lcd_handle = NULL;
    void *lcd_config = NULL;

    ESP_RETURN_ON_ERROR(esp_board_manager_get_device_handle(ESP_BOARD_DEVICE_NAME_DISPLAY_LCD, &lcd_handle),
                        TAG, "display_lcd handle unavailable");
    ESP_RETURN_ON_ERROR(esp_board_manager_get_device_config(ESP_BOARD_DEVICE_NAME_DISPLAY_LCD, &lcd_config),
                        TAG, "display_lcd config unavailable");

    dev_display_lcd_handles_t *handles = (dev_display_lcd_handles_t *)lcd_handle;
    dev_display_lcd_config_t *cfg = (dev_display_lcd_config_t *)lcd_config;
    ESP_RETURN_ON_FALSE(handles && handles->panel_handle && handles->io_handle && cfg,
                        ESP_ERR_INVALID_STATE, TAG, "display_lcd handle/config is NULL");

    s_panel = handles->panel_handle;

    void *touch_handle = NULL;
    esp_err_t err = esp_board_manager_get_device_handle("lcd_touch", &touch_handle);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "lcd_touch handle unavailable (%s); running without touch", esp_err_to_name(err));
        return ESP_OK;
    }
    dev_lcd_touch_handles_t *touch = (dev_lcd_touch_handles_t *)touch_handle;
    ESP_RETURN_ON_FALSE(touch && touch->touch_handle, ESP_ERR_INVALID_STATE, TAG, "lcd_touch handle is NULL");

    const esp_lcd_panel_io_callbacks_t io_cbs = {
        .on_color_trans_done = ha_panel_flush_done_cb,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_panel_io_register_event_callbacks(handles->io_handle, &io_cbs, NULL),
                        TAG, "register panel io callbacks failed");

    s_touch = touch->touch_handle;
    return ESP_OK;
}

/* ------------------------------------------------------------------ */
/* Voice wake listener                                                */
/* ------------------------------------------------------------------ */
/* Hands the microphone to the WakeNet front-end ("嗨小欧" / wn9 model in
 * the `model` partition). On a wake it writes a trigger file that the voice
 * Lua skill polls to start recording automatically. Non-fatal: if the model
 * partition or the codec is missing the panel still boots. The enable/disable
 * gate lives in voice_ptt.lua (it reads voice_wake_enabled from the runtime
 * config), so toggling the setting takes effect without a reboot. */

esp_err_t ha_panel_start(void)
{
    if (s_started) {
        return ESP_OK;
    }

    s_mutex = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_mutex, ESP_ERR_NO_MEM, TAG, "create mutex failed");

    ESP_RETURN_ON_ERROR(ha_panel_load_board(), TAG, "board display/touch init failed");

    int width = 0;
    int height = 0;
    {
        void *lcd_config = NULL;
        ESP_RETURN_ON_ERROR(esp_board_manager_get_device_config(ESP_BOARD_DEVICE_NAME_DISPLAY_LCD, &lcd_config),
                            TAG, "display_lcd config unavailable");
        dev_display_lcd_config_t *cfg = (dev_display_lcd_config_t *)lcd_config;
        width = cfg->lcd_width;
        height = cfg->lcd_height;
    }
    ESP_RETURN_ON_FALSE(width > 0 && height > 0, ESP_ERR_INVALID_STATE, TAG, "invalid panel size");

    ESP_RETURN_ON_ERROR(display_arbiter_acquire(DISPLAY_ARBITER_OWNER_LUA), TAG, "acquire display failed");

    const size_t draw_buf_size = (size_t)width * HA_PANEL_BUF_LINES * sizeof(lv_color_t);
    void *draw_buf = heap_caps_malloc(draw_buf_size, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
    if (!draw_buf) {
        (void)display_arbiter_release(DISPLAY_ARBITER_OWNER_LUA);
        ESP_LOGE(TAG, "draw buffer allocation failed (%u bytes)", (unsigned)draw_buf_size);
        return ESP_ERR_NO_MEM;
    }

    lv_init();

    lv_display_t *display = lv_display_create(width, height);
    ESP_RETURN_ON_FALSE(display, ESP_ERR_NO_MEM, TAG, "lv_display_create failed");
    s_display = display;

    lv_display_set_buffers(display, draw_buf, NULL, (uint32_t)draw_buf_size, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display, ha_panel_flush_cb);

    if (s_touch) {
        lv_indev_t *indev = lv_indev_create();
        ESP_RETURN_ON_FALSE(indev, ESP_ERR_NO_MEM, TAG, "lv_indev_create failed");
        lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
        lv_indev_set_read_cb(indev, ha_panel_touch_read_cb);
        lv_indev_set_user_data(indev, s_touch);
        lv_indev_set_display(indev, display);
    }

    /* Conversation bridge buffers (40 KB read buffer + 40 KB snapshot + the
     * bubble line scratch) go to PSRAM: internal RAM is too tight and these are
     * never touched by DMA. Best-effort; on failure the poll degrades to a
     * no-op rather than aborting the panel. */
    s_voice_log_buf = heap_caps_calloc(1, HA_VOICE_LOG_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_voice_log_snap = heap_caps_calloc(1, HA_VOICE_LOG_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_voice_line = heap_caps_malloc(HA_VOICE_TEXT_MAX + 16, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_voice_log_buf || !s_voice_log_snap || !s_voice_line) {
        ESP_LOGW(TAG, "voice bridge PSRAM buffers unavailable; conversation mirror disabled");
    }

    ha_panel_build_ui();

    const esp_timer_create_args_t timer_args = {
        .callback = ha_panel_tick_cb,
        .name = "ha_panel_tick",
    };
    esp_timer_handle_t tick_timer = NULL;
    ESP_RETURN_ON_ERROR(esp_timer_create(&timer_args, &tick_timer), TAG, "create tick timer failed");
    ESP_RETURN_ON_ERROR(esp_timer_start_periodic(tick_timer, (uint64_t)HA_PANEL_TICK_MS * 1000ULL),
                        TAG, "start tick timer failed");

    BaseType_t ok = xTaskCreate(ha_panel_task, "ha_panel", HA_PANEL_TASK_STACK, NULL,
                                HA_PANEL_TASK_PRIO, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "create panel task failed");

    /* PWR button standby toggle. Non-fatal: without it the panel just never
     * enters standby. */
    esp_err_t pwr_err = ha_panel_power_init();
    if (pwr_err != ESP_OK) {
        ESP_LOGW(TAG, "PWR key init failed: %s", esp_err_to_name(pwr_err));
    }

    /* Jump to the voice page whenever the wake word fires (wake only, not PTT). */
    ha_voice_wake_set_callback(ha_panel_on_wake_event);
    ha_voice_wake_start();

    s_started = true;
    ESP_LOGI(TAG, "HA panel started: %dx%d, buf=%u bytes, touch=%s (CJK font loads after FS mount)",
             width, height, (unsigned)draw_buf_size, s_touch ? "yes" : "no");
    return ESP_OK;
}
