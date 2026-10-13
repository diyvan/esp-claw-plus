/*
 * HA AI Panel - WakeNet wake-word listener (see ha_voice_wake.h).
 *
 * The board wires the ADC and the DAC to the same I2S port, so the codec is
 * kept at its native 48 kHz / 2 ch / 16-bit format and the 16 kHz mono feed
 * the AFE wants is produced in software (downmix + 3:1 box decimation). This
 * avoids any I2S clock reconfiguration that could disturb the DAC path.
 */
#include "ha_voice_wake.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "claw_paths.h"
#include "esp_afe_sr_iface.h"
#include "esp_afe_sr_models.h"
#include "esp_board_manager_includes.h"
#include "esp_check.h"
#include "esp_codec_dev.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "ha_voice_arbiter.h"
#include "model_path.h"

static const char *TAG = "ha_voice_wake";

/* Board ADC runs at the shared I2S clock: 48 kHz / 2 ch / 16-bit. */
#define MIC_SAMPLE_RATE    48000
#define MIC_CHANNELS       2
#define MIC_BITS           16
/* Mirrors the Lua audio default (volume 80 = 80% of 30 dB max gain) so wake
 * detection sees the same microphone level as the PTT recorder. */
#define MIC_INPUT_GAIN_DB  24.0f

/* AFE needs 16 kHz mono. */
#define AFE_TARGET_RATE    16000
#define DECIM_FACTOR       (MIC_SAMPLE_RATE / AFE_TARGET_RATE)

#define WAKE_TASK_STACK       8192
#define WAKE_TASK_PRIO        5
#define AFE_ACQUIRE_TIMEOUT_MS 1000
#define ARBITER_RETRY_MS      20
#define CODEC_RETRY_MS        500

#define WAKE_TRIGGER_FILE     "wake_trigger"

static bool s_started;
static TaskHandle_t s_task;
/* srmodels must outlive the AFE instance, so it lives for the process. */
static srmodel_list_t *s_models;
/* Optional wake-event sink (the panel registers it to jump to the voice page). */
static ha_voice_wake_event_cb_t s_event_cb;

/* Downmix stereo -> mono, then box-decimate by DECIM_FACTOR (48k -> 16k). */
static void mic_downmix_decimate(const int16_t *raw, int out_samples, int16_t *out)
{
    for (int i = 0; i < out_samples; i++) {
        int32_t acc = 0;
        for (int k = 0; k < DECIM_FACTOR; k++) {
            const int16_t *frame = &raw[(i * DECIM_FACTOR + k) * MIC_CHANNELS];
            acc += ((int32_t)frame[0] + (int32_t)frame[1]) / MIC_CHANNELS;
        }
        out[i] = (int16_t)(acc / DECIM_FACTOR);
    }
}

static void ha_voice_wake_publish_trigger(void)
{
    char path[128];
    esp_err_t err = claw_paths_join(CLAW_PATH_DATA, WAKE_TRIGGER_FILE, path, sizeof(path));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "cannot resolve wake trigger path: %s", esp_err_to_name(err));
        return;
    }
    FILE *f = fopen(path, "w");
    if (!f) {
        ESP_LOGW(TAG, "cannot create wake trigger file %s", path);
        return;
    }
    fputs("wake\n", f);
    fclose(f);
    ESP_LOGI(TAG, "wake trigger written: %s", path);
}

static esp_err_t ha_voice_wake_afe_open(esp_afe_sr_data_t **out_afe,
                                        const esp_afe_sr_iface_t **out_iface,
                                        int *out_feed_samples)
{
    s_models = esp_srmodel_init("model");
    if (!s_models) {
        ESP_LOGE(TAG, "esp_srmodel_init(\"model\") returned NULL");
        return ESP_ERR_NOT_FOUND;
    }
    ESP_LOGI(TAG, "%d model(s) loaded from \"model\" partition", s_models->num);
    for (int i = 0; i < s_models->num; i++) {
        ESP_LOGI(TAG, "  [%d] %s", i, s_models->model_name[i]);
    }

    afe_config_t *cfg = afe_config_init("M", s_models, AFE_TYPE_SR, AFE_MODE_LOW_COST);
    if (!cfg) {
        ESP_LOGE(TAG, "afe_config_init returned NULL");
        return ESP_FAIL;
    }
    /* WakeNet only: no far-end reference available (single mic, no loopback). */
    cfg->aec_init = false;
    cfg->se_init = false;
    cfg->ns_init = false;
    cfg->agc_init = false;
    cfg->vad_init = false;
    cfg->wakenet_init = true;
    /* Leave wakenet_mode as chosen by afe_config_init for this model. */

    const esp_afe_sr_iface_t *iface = esp_afe_handle_from_config(cfg);
    if (!iface) {
        ESP_LOGE(TAG, "esp_afe_handle_from_config returned NULL");
        return ESP_FAIL;
    }
    esp_afe_sr_data_t *afe = iface->create_from_config(cfg);
    if (!afe) {
        ESP_LOGE(TAG, "AFE create_from_config failed");
        return ESP_FAIL;
    }

    iface->print_pipeline(afe);
    int feed = iface->get_feed_chunksize(afe);
    int fetch = iface->get_fetch_chunksize(afe);
    ESP_LOGI(TAG, "AFE ready: feed=%d fetch=%d samples, channels=%d, rate=%d",
             feed, fetch, iface->get_feed_channel_num(afe), iface->get_samp_rate(afe));
    if (feed <= 0 || iface->get_samp_rate(afe) != AFE_TARGET_RATE) {
        ESP_LOGE(TAG, "unexpected AFE format (feed=%d rate=%d)", feed, iface->get_samp_rate(afe));
        return ESP_ERR_INVALID_STATE;
    }

    *out_afe = afe;
    *out_iface = iface;
    *out_feed_samples = feed;
    return ESP_OK;
}

static void ha_voice_wake_task(void *arg)
{
    (void)arg;

    esp_afe_sr_data_t *afe = NULL;
    const esp_afe_sr_iface_t *iface = NULL;
    int feed = 0;
    if (ha_voice_wake_afe_open(&afe, &iface, &feed) != ESP_OK) {
        ESP_LOGE(TAG, "AFE init failed; wake listener disabled");
        vTaskDelete(NULL);
        return;
    }

    int16_t *raw = heap_caps_malloc((size_t)feed * DECIM_FACTOR * MIC_CHANNELS * sizeof(int16_t),
                                    MALLOC_CAP_INTERNAL);
    int16_t *mono = heap_caps_malloc((size_t)feed * sizeof(int16_t), MALLOC_CAP_INTERNAL);
    if (!raw || !mono) {
        ESP_LOGE(TAG, "scratch buffer allocation failed");
        vTaskDelete(NULL);
        return;
    }

    esp_codec_dev_handle_t codec = NULL;
    {
        void *handle = NULL;
        if (esp_board_manager_get_device_handle("audio_adc", &handle) != ESP_OK || !handle) {
            ESP_LOGE(TAG, "audio_adc handle unavailable");
            vTaskDelete(NULL);
            return;
        }
        codec = ((dev_audio_codec_handles_t *)handle)->codec_dev;
        if (!codec) {
            ESP_LOGE(TAG, "audio_adc codec_dev is NULL");
            vTaskDelete(NULL);
            return;
        }
    }

    esp_codec_dev_sample_info_t fs = {
        .sample_rate = MIC_SAMPLE_RATE,
        .channel = MIC_CHANNELS,
        .bits_per_sample = MIC_BITS,
    };
    const int read_bytes = feed * DECIM_FACTOR * MIC_CHANNELS * (MIC_BITS / 8);

    ESP_LOGI(TAG, "wake listener running: feed=%d samples (%d bytes/cycle @ %d Hz)",
             feed, read_bytes, MIC_SAMPLE_RATE);

    while (true) {
        if (!ha_voice_arbiter_afe_acquire(AFE_ACQUIRE_TIMEOUT_MS)) {
            vTaskDelay(pdMS_TO_TICKS(ARBITER_RETRY_MS));
            continue;
        }

        if (esp_codec_dev_open(codec, &fs) != ESP_CODEC_DEV_OK) {
            ESP_LOGE(TAG, "codec open failed");
            ha_voice_arbiter_afe_release();
            vTaskDelay(pdMS_TO_TICKS(CODEC_RETRY_MS));
            continue;
        }
        (void)esp_codec_dev_set_in_gain(codec, MIC_INPUT_GAIN_DB);
        iface->reset_buffer(afe);

        bool woke = false;
        int dbg_feeds = 0;
        int dbg_peak = 0;
        while (!ha_voice_arbiter_yield_requested()) {
            if (esp_codec_dev_read(codec, raw, read_bytes) != ESP_CODEC_DEV_OK) {
                ESP_LOGW(TAG, "codec read failed");
                break;
            }
            mic_downmix_decimate(raw, feed, mono);
            /* TEMP DEBUG: mic liveness / level probe. */
            for (int i = 0; i < feed; i++) {
                int v = mono[i];
                if (v < 0) {
                    v = -v;
                }
                if (v > dbg_peak) {
                    dbg_peak = v;
                }
            }
            dbg_feeds++;
            iface->feed(afe, mono);

            afe_fetch_result_t *res = iface->fetch(afe);
            if (!res) {
                ESP_LOGW(TAG, "afe fetch returned NULL");
                continue;
            }
            if (dbg_feeds >= 60) {
                ESP_LOGI(TAG, "dbg: mic peak=%d over %d feeds; wakeup_state=%d",
                         dbg_peak, dbg_feeds, res->wakeup_state);
                dbg_feeds = 0;
                dbg_peak = 0;
            }
            if (res->wakeup_state == WAKENET_DETECTED) {
                ESP_LOGI(TAG, "wake word detected: idx=%d model=%d",
                         res->wake_word_index, res->wakenet_model_index);
                woke = true;
                break;
            }
        }

        esp_codec_dev_close(codec);

        if (woke) {
            /* Keep the listener off the mic until the capture session ends. */
            ha_voice_arbiter_hold_for_capture();
            ha_voice_wake_publish_trigger();
            if (s_event_cb) {
                s_event_cb();
            }
        }
        ha_voice_arbiter_afe_release();
    }
}

void ha_voice_wake_set_callback(ha_voice_wake_event_cb_t cb)
{
    s_event_cb = cb;
}

esp_err_t ha_voice_wake_start(void)
{
    if (s_started) {
        return ESP_OK;
    }

    esp_err_t err = ha_voice_arbiter_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "arbiter init failed (%s); running without mic arbitration", esp_err_to_name(err));
    }

    if (xTaskCreate(ha_voice_wake_task, "ha_voice_wake", WAKE_TASK_STACK, NULL,
                    WAKE_TASK_PRIO, &s_task) != pdPASS) {
        ESP_LOGE(TAG, "create wake listener task failed");
        return ESP_ERR_NO_MEM;
    }

    s_started = true;
    ESP_LOGI(TAG, "wake listener started");
    return ESP_OK;
}
