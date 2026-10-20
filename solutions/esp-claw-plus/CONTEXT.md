# esp-claw-plus 语音

esp-claw-plus 在 ESP32-P4 开发板上把「本地唤醒 + 云端 ASR/LLM/TTS」接入 esp-claw 的渠道层与 Agent Loop。本文件只记录该方案的领域词汇。

## 语音链路

**回复模式 (Reply Mode)**:
一轮语音回复选择哪条处理路径，取值 `agent` 或 `direct`。可在设备语音面板随时切换，持久化于 NVS。
_Avoid_: claw/llm 模式、route mode

**agent 模式**:
语音文本进入 claw_core Agent Loop 的完整形态——带工具、技能与多轮记忆，可执行 Home Assistant 等动作。
_Avoid_: claw 模式

**direct 模式（直答）**:
语音文本进入 Agent Loop 的**最小化形态**——不发工具、不建上下文、不持久化，只做单轮问答。
_Avoid_: llm 模式、直连模式

**voice 渠道**:
语音专用的内部事件渠道（`channel=voice`）。claw 轮次用 `chat_id=voice`，直答轮次用 `chat_id=voice_llm`；`chat_id` 是回复模式在事件上的载体。
_Avoid_: 语音频道

**流式回复桥 (stream sink)**:
C 侧把 LLM 的增量文本写入 `/fatfs/voice_stream.txt`、供常驻 Lua 逐句消费的文件信道。
_Avoid_: 流桥

**逐句流水线 (sentence pipeline)**:
Lua 从流式回复桥按标点切句、逐句做 TTS 边收边播的流水线。
_Avoid_: 分段播报

**voice_stream 模块**:
消费「流式回复桥」的 Lua 模块（`skills/voice/scripts/voice_stream.lua`），是文件名 / 结束哨兵 / 整读差分 / 按标点切句这套约定的唯一 owner。对外暴露 `consumer(...)` 返回的 `:next()`（取一句）与 `:finished()`（读完未），读源可注入以便测试；另有 `on_first_sentence` 首句回调与 `first_sentence_ms` 首句延迟上限（默认 600ms）。C↔Lua 权威契约见 `docs/voice-integration.md` §7.6。
_Avoid_: 流读取器

**唤醒触发 (wake trigger)**:
唤醒词命中后由 C 侧写 `/fatfs/wake_trigger`、常驻语音脚本读取的文件信道。
_Avoid_: 唤醒事件

**发送模式 (Send Mode)**:
一轮语音识别出的文本何时交给 Agent，取值 `auto`（识别即发送）或 `manual`（先挂起、按 BOOT 确认才发送）。与回复模式正交，持久化于 NVS（`voice_send_mode`）。
_Avoid_: 确认模式、manual 模式

**待确认态 (pending)**:
发送模式为 `manual` 时，识别完成到用户确认之间的状态；面板显示为 `confirming`。轻点 BOOT 发送、按住作废并重录、超时自动作废。
_Avoid_: 挂起态

**音频设备所有权 (audio device owner)**:
麦克风与扬声器共享同一颗 ES8311 与同一 I2S port，因此录音与播放共用一份设备所有权。由 C 侧 `ha_voice_arbiter` 承载：`MIC` 方向独占（唤醒监听与 Lua 录音互斥），`SPK` 方向可多 writer 共存；采集请求会撤销并排空所有 SPK writer。
_Avoid_: 麦克风仲裁器、音频互斥锁

**采集 48k 不变量 (48k capture invariant)**:
Lua 录音与唤醒监听都以板级默认 48kHz 打开 codec（不重配与 DAC 共享的 I2S 时钟），交付给 ASR 的 16kHz 单声道由 C 侧降采样产生。
_Avoid_: 采样率重配

**轮次闸门 (round gate)**:
跨脚本的「这是哪一轮对话」身份标记，由 Lua 模块 `voice_round`（`skills/voice/scripts/voice_round.lua`）唯一持有：每次用户开始说话（PTT 按下 / 唤醒）递增轮次号并落盘 `/fatfs/voice_round`；异步回复脚本记下进入时的轮次号，用以判断自己是否已被新一轮取代。
_Avoid_: 状态码比较、标志文件

**播放 owner (playback owner)**:
唯一的播放实现，由 Lua 模块 `voice_playback`（`skills/voice/scripts/voice_playback.lua`）承载：开 DAC 输出、惰性建 player、流式/落盘播放、`poll` 收尾、`stop`/`close`。收敛了「逐句流水线」与「整段回退」两条播放路径的重复代码。
_Avoid_: 播放器封装、audio.player 包装
