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
