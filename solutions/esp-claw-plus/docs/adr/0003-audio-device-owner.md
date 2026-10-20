# 音频设备所有权归 C 层 `ha_voice_arbiter`（MIC/SPK 双方向）+ 48k 采集不变量

状态：accepted

## Context

板载麦克风与扬声器是**同一颗 ES8311、同一个 I2S port 0**；`board_devices.yaml` 里的 `audio_adc` / `audio_dac` 只是两个 handle，背后共用一份采样时钟与一份 codec 句柄。由此产生三类故障：

1. 播放中发起录音时，录音以 16kHz 打开 codec，**就地把共享 I2S 时钟从 48kHz 改成 16kHz**，播放侧仍在写 → 设备重启；
2. **跨 owner use-after-close**：多个 `audio.new_output` 复用同一 `codec_dev` 指针，一方 `close()` 把该句柄 `esp_codec_dev_close` 置 NULL，另一方仍在写；
3. `voice_ptt.lua` 的 `wait_step()` 内 player 重建/关闭竞态。

播放 owner 本来就有两个（`voice_ptt.lua` 的逐句流水线、`voice_reply.lua` 的整段播放），Lua 侧无法全局协调，因此所有权必须下沉到 C。

## Decision

1. **扩展现有 `ha_voice_arbiter` 为设备级 owner**（不新建 `ha_audio_owner`）：加"方向"概念，`MIC` 方向独占，`SPK` 方向可多 writer 共存；接口为 `ha_voice_arbiter_acquire(timeout_ms)` / `_release()`（MIC，语义原样保留）与新增的 `_spk_acquire()` / `_spk_release()` / `_spk_revoked()`。设备级 refcount 由 `portMUX` 保护。
2. **采集撤销 SPK 并等待排空**：MIC `acquire` 成功后置 `revoked`，循环等 SPK 计数归零（上限 500ms，超时打警告后放行）。
3. **停止播放走协作式撤销**：`audio_player_out_cb` 与 write 路径先查 `spk_revoked`，命中即返回失败 → `esp_audio_simple_player` 自然停机 → Lua 侧 `poll()` 收尾并释放输出。不用强杀线程，避免在 ESP-IDF 内部状态上做外科手术。
4. **录音恒定 48kHz 打开 codec**（不重配共享时钟），交付 ASR 的 16kHz 单声道由 C 侧降采样产生：Lua 传入 `asr_rate` / `asr_channels`，C 侧复用 AFE 已有的下混+抽取逻辑（泛化成 `ha_voice_pcm_downmix_decimate` 共享 helper），`info()` 报告降采样后的格式。对齐 `ha_voice_wake.c` 既有做法。
5. **codec 引用计数**（按句柄计）：只有首个引用才 `esp_codec_dev_open`、末个引用才 `esp_codec_dev_close`，消除跨 owner 关句柄。

## Considered Options

- **新建独立 `ha_audio_owner` 组件**：被否——与 `ha_voice_arbiter` 的职责（同一份 codec 的互斥）重叠，会成为第二个 owner。
- **录音时按 ASR 需求重配 codec 采样率**：被否——共享时钟，重配必然打断 DAC；且要处理"播放中"特例。
- **强杀播放线程 / 冲掉 I2S 队列**：被否——跨线程取消在 ESP-IDF 组件内部不安全。
- **Lua 侧自行约定先后顺序**（先 stop 播放再录音）：被否——两个播放 owner 跨脚本，文件信道协调既慢又易漏。

## Consequences

- 改动落在**上游组件**（`components/common/ha_voice_arbiter`、`components/lua_modules/lua_module_audio`），需以 `patches/esp-claw-audio-owner.patch` 交付并接入 `setup_esp_claw.sh`（放在 `esp-claw-voice-wake.patch` 之后，后者创建这些文件）。
- `ha_voice_wake.c` 改用共享 helper，删除本地副本（overlay `main/`，无补丁）。
- `voice_ptt.lua` 不再请求 16kHz，改传 `asr_rate` / `asr_channels`。
- 因"录音恒定 48k"，不可再通过 Lua 请求任意采样率；若将来需要更高的交付采样率，应扩 `asr_*` 的语义而非放开 codec 重配。
