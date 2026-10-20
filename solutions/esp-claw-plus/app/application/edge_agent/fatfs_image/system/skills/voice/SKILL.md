---
{
  "name": "voice",
  "description": "On-device push-to-talk voice loop for this board: the BOOT key records audio, ASR turns it into text for the agent, and the agent reply is spoken back through TTS.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly"
  }
}
---

# Voice (on-device push-to-talk)

本板 (ESP32-P4 WiFi6 Touch LCD 3.5) 的语音交互技能: 按下 BOOT 键说话, 录音经
ASR 转文本后注入 Agent, Agent 的回复再经 TTS 播放。

## 脚本

- `scripts/voice_ptt.lua` — 常驻的 PTT 循环。监听 GPIO35 (BOOT 键, 低电平有效),
  **按下开始 / 松开结束**: 按下后经 `audio.new_input` 流式读取 PCM, 松手时把
  `MIN_RECORD_MS`~`MAX_RECORD_MS` 之间的音频写成 `/fatfs/voice_ptt.wav`, 转文本后经
  `event_publisher.publish_message` 注入, 渠道 `voice` / 会话 `voice`。
- `scripts/voice_reply.lua` — 回复播报。由路由规则调用, 回复文本在 `args.text`。
  真实 TTS: 把文本 POST 给云 TTS, 响应音频落盘后异步播放 (播放统一走 `voice_playback`);
  播放期间轮询打断标志 `/fatfs/voice_interrupt` 与**轮次闸门** (`voice_round`,
  用户若已发起新一轮录音即自行放弃), 命中即停止 (语音打断 / barge-in)。
- `scripts/voice_common.lua` — 共享模块, 是三个 `/fatfs` 约定的**唯一 owner**: 屏幕桥
  (对话文本上屏)、运行时配置桥、语音打断信道。`voice_ptt.lua` / `voice_reply.lua` /
  `voice_e2e.lua` 都 `require("voice_common")` (与调用方同目录, `package.path` 首位即命中)。
- `scripts/voice_playback.lua` — 共享模块, 是**播放约定的唯一 owner**: 取板级 DAC 参数、开
  输出 (`playback.open(cfg)`)、惰性建 player、流式会话 (`play_stream` / `play_stream_append`
  / `play_stream_finish`)、落盘 `play_file(path)`、`poll()` 推进收尾、`stop()` 打断、`close()`
  释放。`voice_ptt.lua` (逐句流水线) 与 `voice_reply.lua` (整段回退) 都经它播放, 不再各写一份。
- `scripts/voice_round.lua` — 共享模块, 是**轮次闸门 (round gate)** 的唯一 owner: 每次用户
  开始说话 (PTT 按下 / 唤醒) 由 `voice_ptt.lua` 调 `round.begin()` 递增轮次号并落盘
  `/fatfs/voice_round`; 异步回复脚本 `round.id()` 记下进入时的号, 用 `round.is_current(rid)`
  判断自己是否已被新一轮取代 (过期即不起播/停播), 避免插播过期语音。
- `scripts/voice_stream.lua` — 共享模块, 是 `voice_stream.txt` **流式回复桥** (文件名 / 结束
  哨兵 `\1\1END\1\1` / 整读差分 / 按标点切句) 的**唯一 owner**。`voice_ptt.lua` (逐句播报) 与
  `voicetest/voice_e2e.lua` (自测) 都 `require("voice_stream")`: `consumer({root_dir=?, read=?})`
  返回消费者, 循环 `:next()` 取句、`:finished()` 判读完; `read` 可注入合成增量以便离线测试,
  `reset(root_dir)` 清上一轮残留。另有计时/首句延迟: `on_first_sentence(sentence, latency_ms)`
  首句回调、`c.first_latency_ms`、`first_sentence_ms`(默认 600, 0 关闭) 首句无终止符超时强制
  软切; 时钟经 `now` 注入便于测试。
- `scripts/voice_selftest.lua` — 录音+回放自检 (不依赖 BOOT 键), 用于验证麦克风/扬声器
  通路: `lua --run --path /system/skills/voice/scripts/voice_selftest.lua`。
- `scripts/providers/` — 云端服务适配层 (供应商插件)。`util.lua` 提供 base64 编解码 /
  JSON 转义 / UUID / HTTP POST 工具; `asr_volcano.lua` / `tts_volcano.lua` 为火山引擎
  (豆包语音) 适配器。`<script_dir>` 已加入 `package.path`, 故可直接
  `require("providers.asr_volcano")`。ASR 适配器可导出**流式会话** `open(cfg, info)`
  (返回带 `send/poll/finish/abort` 的会话对象) 或**批量** `transcribe(cfg, wav_path, info)`;
  TTS 适配器导出 `synthesize`。新增云端服务只需加一个
  `providers/asr_<name>.lua` / `providers/tts_<name>.lua`, **无需改动 generic 路径**。
  失败时均在第二个返回值给出简短中文原因 (如 `未配置 ASR 密钥` / `ASR HTTP 401` /
  `TTS 无音频返回`), 由调用方写上面板状态行。

## 路由规则 (必须成对存在)

语音链路依赖三条路由规则 (`/fatfs/router_rules/router_rules.json`):

1. `voice_reply_run_script` — 匹配 `source_cap=claw_core`、`event_type=out_message`、
   `chat_id=voice` (agent 回复模式), 动作 `run_script` 调用 `voice_reply.lua`,
   参数 `args.text={{event.text}}`。必须排在默认规则 `agent_out_message_send_message`
   **之前**(`consume_on_match=true`)。本设备通过 `event_router --add-rule-json` 安装,
   新规则会被插入到规则数组最前面。
2. `voice_reply_run_script_direct` — 同上, 但匹配 `chat_id=voice_llm` (direct 回复模式,
   见 `docs/adr/0001-voice-reply-mode.md`)。router 的 `chat_id` 匹配是**精确 strcmp**,
   故 agent / direct 各需一条规则。
3. `startup_voice_ptt` — 匹配 `source_cap=app_claw`、`event_type=startup`、
   `event_key=boot_completed`, 动作 `run_script` (`async: true`) 启动 `voice_ptt.lua` 常驻任务。

规则的完整 JSON 见 `solutions/ha_ai_panel/app/router_rules/voice_rules.json`,
安装脚本为 `solutions/ha_ai_panel/scripts/install_voice_rules.py`。

## 依赖的 Lua 模块

`audio`、`board_manager`、`button`、`capability`、`delay`、`event_publisher`、`json`、
`storage`、`system`。

## 云端 ASR / TTS 契约

供应商分派: `voice_asr_provider` / `voice_tts_provider` **为空或 `"generic"`** 时走下方
generic 契约 (默认, 行为与历史版本完全一致); 否则 `require("providers.<asr|tts>_<provider>")`。
ASR 适配器若导出 `open` 则走**流式会话** (边说边发、增量上屏), 否则回退到 `transcribe`
批量契约; TTS 适配器调用 `synthesize`。目前内置 `volcano` (火山引擎 / 豆包语音)。
`voice_tts_provider == "local"` 是本机引擎 (见下节「本地 TTS」), **不加载适配器**。

### generic 契约 (默认, 端点非空时)

- **ASR** — `voice_ptt.lua` 把录音 WAV 以 base64 放进 JSON POST 给 `voice_asr_url`:

  ```json
  {"format":"wav","sample_rate":48000,"channels":2,"bits":16,"audio_base64":"<...>"}
  ```

  响应为 JSON, 转写文本依次尝试 `text` / `transcript` / `result` / `output_text` /
  `data`(字符串或 `.text`/`.result`) / `choices[1].message.content` (非 JSON 则退化为
  去引号的纯文本)。密钥非空时附 `Authorization: Bearer <voice_asr_api_key>`。
- **TTS** — `voice_reply.lua` POST `{"format":"wav","text":"<回复文本>"}` 给
  `voice_tts_url`; 返回的音频经 `save_path` 二进制落盘到 `/fatfs/voice_reply.wav` 再播放
  (支持 WAV/MP3/AAC/FLAC, 不支持 OPUS/AMR)。密钥同上。

### 火山引擎 (provider = "volcano")

火山云采用**新版控制台鉴权**: 仅需 `X-Api-Key` (即配置项里的 `voice_asr_api_key` /
`voice_tts_api_key`), 无需旧版 `X-Api-App-Key` + `X-Api-Access-Key`。资源 ID / 发音人留空
时由 provider 取默认值。

- **ASR** (`providers/asr_volcano.lua`) — 流式语音识别 2.0 (大模型流式)
  `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` (WebSocket, 火山 sauc
  二进制协议)。会话式: 边说边发 16-bit PCM 分片, 增量返回累计文本; 收尾发末包得最终
  文本, **不再落盘 WAV**。WS 升级 header: `X-Api-Key` / `X-Api-Resource-Id`
  (默认 `volc.seedasr.sauc.duration`) / `X-Api-Connect-Id`; 音频经 C 侧 `asr_stream`
  能力 (cap_asr_stream) 封帧收发。
- **TTS** (`providers/tts_volcano.lua`) — 大模型语音合成 V3 单向流式
  `POST https://openspeech.bytedance.com/api/v3/tts/unidirectional`,
  header: `X-Api-Key` / `X-Api-Resource-Id` (默认 `seed-tts-2.0`) / `X-Api-Request-Id`;
  body `req_params.text` + `speaker` (默认 `zh_female_vv_uranus_bigtts`) +
  `audio_params` (mp3 / 24000Hz)。响应为 chunked 流式 JSON, 音频为 base64 分块——先经
  `save_path` 全量落盘, 再在 Lua 内**逐块解码后拼接字节** (不能直接拼 base64 字符串,
  分块各自补齐会损坏), 写出 `/fatfs/voice_reply.mp3`。

- ⚠️ **TTS 走 `cap_http_request`, 必须先把 TTS 域名加入其主机白名单**
  (NVS `http_allow_ls` / `search_http_allowlist`), 否则会被拒绝。ASR 改走 WebSocket
  (`cap_asr_stream`) **不受该白名单限制**。

### 本地 TTS (provider = "local")

**设备端合成, 无网络往返**——用于压低「LLM 首字 → 首字播放」延迟。esp-sr 自带 esp-tts 中文引擎,
语音数据烧在独立 `voice_data` 分区 (运行时 mmap)。**仅中文、固定音色 (xiaole)、无 speaker 可选**,
且**只支持边收边播** (没有「整段合成 → 落盘 → 播放」路径), 故 `voice_ptt.lua` 的
`stream_enabled()` 对它**恒为开**。

- `voice_tts.stream_request(cfg, text)` 在本地引擎下**不发 HTTP**, 直接返回
  `{ ["local"] = true, text = <文本>, speed = 2 }`; `voice_tts.synthesize()` 在本地引擎下返回
  「本地 TTS 仅支持流式播报」。
- `audio.player:play_stream(req)` 见到 `req.local` 时分派到 `cap_tts_stream_begin_local`
  (`append` 同理), URI 用 `raw://tts/stream.pcm`; 本地模式产出 **16kHz / 单声道 / 16-bit PCM**,
  直接进播放器的 ASRC (16k→48k)。
- 语速 `speed` 取值 1..5 (默认 2), 由 `esp_tts_stream_play` 控制。
- 提示: 本地模式下 `voice_tts_url` / `voice_tts_api_key` / `voice_tts_resource_id` /
  `voice_tts_speaker` 均**不生效**。

## 语音打断 (barge-in)

跨脚本唯一可行的信道是 `/fatfs` 文件 (音频无全局仲裁器), 有两条互补的信道:

- **轮次闸门** (`voice_round`): 用户开始说话时 `voice_ptt.lua` 调 `round.begin()` 递增轮次号;
  `voice_reply.lua` 记下进入时的轮次号, 起播前与播放中都用 `round.is_current()` 判断自己是否
  已被新一轮取代 —— 过期就不起播/停播。这是**语义归属**判定, 不依赖"标志是否被及时清掉"。
- **打断标志** (`voice_interrupt`): 用户按下 BOOT 或唤醒命中时, `voice_ptt.lua` 经
  `voice_common.signal_interrupt()` 写空标志; `voice_reply.lua` 播放中每 20ms 经
  `voice_common.interrupt_requested()` 轮询, 见到标志即 `player:stop()` 并清标志。这是**立即停音**
  的边沿信号。标志文件的读写统一由 `voice_common` 承载。

设备级所有权 (录音到来时如何撤销正在写扬声器的 writer) 由 C 侧 `ha_voice_arbiter` 兜底,
见 `docs/adr/0003-audio-device-owner.md`; 轮次闸门与播放收敛见 `docs/adr/0004-voice-round-and-playback-owner.md`。

## 相关技能

- `ha_control` — HA MCP 控制 (list_tools / call_tool), 受 `ha_enabled` 门控。
- `local_scene` — 离线本地场景联动 (`scene:` 前缀命令 + 启动恢复), 断网可用。

## 运行时配置桥 (网页 -> 语音脚本)

网页「语音助手」页保存的配置, 由 C 侧 `ha_panel.c` 的
`ha_panel_publish_runtime_config()` 写入 `/fatfs/ha_voice_runtime.json`; 两个脚本经
`voice_common.load_runtime_config()` (每次真读) / `voice_common.runtime_config()` (1s 缓存)
读取该 JSON 获取 ASR/TTS 端点与唤醒开关 (与屏幕桥同向, 复用 `/fatfs` 可写分区, 无需新增
Lua<->C 绑定)。字段:

| 字段 | 用途 |
| --- | --- |
| `voice_wake_enabled` | 唤醒词自动录音开关; `false` 时 `voice_ptt.lua` 丢弃唤醒触发, 仅保留 BOOT 键 PTT |
| `voice_asr_provider` | ASR 供应商; 空 / `generic` = 通用契约, `volcano` = 火山引擎 |
| `voice_asr_url` / `voice_asr_api_key` | ASR 端点与密钥 (火山云用新版控制台 `X-Api-Key`) |
| `voice_asr_resource_id` | ASR 资源 ID; 留空用 provider 默认 (`volc.seedasr.sauc.duration`) |
| `voice_tts_provider` | TTS 引擎; 空 / `generic` = 云通用契约, `volcano` = 火山引擎 (云), `local` = **设备端本地 TTS** (esp-tts, 见上节) |
| `voice_tts_url` / `voice_tts_api_key` | TTS 端点与密钥 (本地引擎下不生效) |
| `voice_tts_resource_id` | TTS 资源 ID; 留空用 provider 默认 (`seed-tts-2.0`) |
| `voice_tts_speaker` | TTS 发音人; 留空用 provider 默认 (`zh_female_vv_uranus_bigtts`) |
| `voice_tts_stream` | 边收边播开关; `true` 时每句回复走 TTS 流式 (`player:play_stream`) 边收边播, 不再整句合成落盘; 默认 `false`; **`voice_tts_provider=local` 时恒为开** |
| `voice_send_mode` | 发送方式; `auto` (默认) 识别出文本后立即发送, `manual` 进入 `confirming` 态等 BOOT 键确认 (轻点发送 / 按住作废并重录 / 15s 无操作自动作废) |
| `ha_enabled` / `ha_base_url` / `ha_token` | Home Assistant 开关与接入信息 (M2 意图路由使用) |

配置在网页保存后即时生效, 无需重启 (脚本每 1s 重新读取一次)。

## 发送模式 (voice_send_mode)

`auto` (默认) 与 `manual` 只影响**识别完成后是否立即发送**, 与回复模式 (`voice_reply_mode`)
正交, 流式 / 批量 ASR 两条路径都适用:

- `auto`: 识别出文本即注入 Agent (`set_wait("thinking")` → 起播流水线)。
- `manual`: 识别出文本后**不发送**, 转入 `pending` 状态并写状态码 `confirming`, 等 BOOT 键确认:

| 手势 (pending 态下) | 行为 |
| --- | --- |
| 轻点 (按住未达 `MANUAL_HOLD_MIN_MS` = 500ms 即松开) | 发送本次识别结果 (与 `auto` 同一套注入 + 播报流程) |
| 按住 (≥ 500ms) | 作废本次结果并**立即重新录音** (松手后照常收尾 → 再次进入 `pending`) |
| 无操作 15s (`PENDING_TIMEOUT_MS`) | 自动作废回 `idle`, **不自动发送** |

pending 态下 BOOT 键不再直接起录音: `on_press_down` 只记按下时刻, 由主循环 `pending_step()`
判定"按住 → 重录"、`on_press_up` 判定"轻点 → 发送"; 超时同样由 `pending_step()` 兜底。

## 屏幕桥 (状态码 + 对话上屏)

语音状态与多轮对话会同步显示到 M1 的 LVGL 面板 (`ha_panel.c`)。桥接方式为文件: 脚本经共享
模块 `voice_common` (`/system/skills/voice/scripts/voice_common.lua`) 写 `/fatfs/voice_*.txt`,
面板每 200ms 轮询读取并刷新。`voice_common` 是这些文件的**唯一 owner**——新增任何写入方只需
`require("voice_common")`, 不要再在脚本里自带一份写盘拷贝。

写入接口:

| 接口 | 作用 |
| --- | --- |
| `set_status(code, detail)` | 写状态码 `code` + 可选自由文本 `detail` (失败原因等) |
| `read_status_code()` | 读回当前状态码 (状态机到期 guard 用) |
| `log_user(text)` | 写入/覆盖最后一条用户气泡 (流式 ASR 增量刷新同一气泡) |
| `log_agent(text)` | 追加一条助手气泡 (非流式整段回复) |
| `log_agent_append(delta)` | 追加到最后一个助手气泡 (流式逐句增长; 末条非 A 则新建) |
| `clear_log()` | 清空会话记录 (仅自测脚本用; 正常运行靠裁剪, 不清历史) |

### `voice_status.txt` — 状态码桥

内容为单行 `<code>|<detail>`。`code` 是**机器可读 token**, 由面板查表映射成中文标签 + 忙碌
标志; `detail` 是可选的自由文本 (失败原因 / 火山短消息)。**code 与措辞分离**: 面板改中文标签
不会悄悄破坏忙碌指示灯; 面板对未知 `code` 兜底为「未知」并视为忙碌。

| code | 面板标签 | 忙碌 |
| --- | --- | --- |
| `idle` | 空闲 | 否 |
| `recording` | 录音中 | 是 |
| `recognizing` | 识别中 | 是 |
| `confirming` | 待确认 | 是 |
| `thinking` | 思考中 | 是 |
| `synthesizing` | 合成中 | 是 |
| `speaking` | 播报中 | 是 |
| `error` | 出错 | 是 |

正常流程态 (非 `idle`/`error`) 可带 `detail`; 一切失败统一写 `error|<原因>`, 面板显示
「状态: 出错 · <原因>」。

### `voice_log.txt` — 会话记录桥

内容为多条记录, 每条为 `<role>\x1f<text>\x1e`:

- `role` = `U` (用户) / `A` (助手);
- `\x1f` (US, 十进制 31) 分隔 role 与 text; `\x1e` (RS, 十进制 30) 分隔记录;
- LLM 输出不会包含这两个控制符, 故**无需转义**。

`voice_common` 侧按 `MAX_LOG_RECORDS` (8) 裁剪, 只保留最近 8 条; 面板按控制符切分渲染最近
8 条 (与 Lua 裁剪数对齐), 以 `你说:` / `AI 说:` 两种颜色气泡逐条显示, 并自动滚到最后一条。
C 侧读缓冲与快照各 40KB, 分配在 **PSRAM** (内部 RAM 紧张且渲染不需要 DMA)。

写盘为**非破坏性原子写**: 先写 `<name>.tmp` 再删目标改名 (FatFs `f_rename` 在目标已存在时
返回 `FR_EXIST`, 故必须先删); 若面板恰好落在"目标已删、改名前"的窗口里, 读到的是文件不存在,
`ha_panel_read_text` / `ha_panel_read_raw` 返回 false 会**跳过本次刷新**, 保留上一帧——因此不会
闪空白, 也不会清空已显示的气泡。

| 文件 | 写入方 | 内容 |
| --- | --- | --- |
| `/fatfs/voice_status.txt` | `voice_common` (`voice_ptt.lua` / `voice_reply.lua` 调用) | 单行 `<code>|<detail>` (见上表) |
| `/fatfs/voice_log.txt` | `voice_common` (`voice_ptt.lua` 流式逐句 `log_agent_append` + `log_user`; `voice_reply.lua` 整段 `log_agent`) | 最近 8 条 `<role>\x1f<text>\x1e` 对话记录 |

**状态反馈**: 每个阶段都把状态码写进 `voice_status.txt` (面板「状态:」行, 非 `idle` 时点亮
指示灯) 并同步打串口日志, **不再静默回到「空闲」**。流程态写对应 `code` (`recording` /
`recognizing` / `confirming` / `thinking` / `synthesizing` / `speaking`); 一切失败统一写
`error|<原因>`, 面板显示「状态: 出错 · <原因>」。各阶段的失败原因:

| 阶段 | 失败原因 (`error` 的 detail) |
| --- | --- |
| 开录音 | `麦克风不可用` / `麦克风占用` (设备或仲裁器拿不到) |
| 录音中 | `麦克风读取失败` (读不到数据) |
| 录音收尾 | `录音太短 Nms` (松手太快, < 500ms); `未录到声音` (整段峰值 RMS < 150, 不再上传); `录音写盘失败` |
| ASR | `未配置 ASR` / `未配置 ASR 密钥` / `ASR 网络错误` / `ASR HTTP 4xx` / `未识别到语音` (火山返回短消息时直接透出) |
| Agent | 30s 内无回复 → `AI 无响应` |
| TTS | `TTS 网络错误` / `TTS HTTP 4xx` / `TTS 无音频返回` / `未配置 TTS` |
| 播放 | `播放失败` / `播放器创建失败` / `扬声器占用`; 正常播完回 `idle` |

失败态保留时长: `voice_ptt.lua` 内的失败态保留 4s 后自动回 `idle` (到期改写前会校验面板内容,
避免覆盖 `voice_reply.lua` 已推进的新状态); `voice_reply.lua` 是一次性脚本, 其失败态保留到下一次
语音交互 (PTT 写 `recording`) 覆盖。

注意: `/system` 为只读 FAT, 运行时写入必须落在可读写的 `/fatfs` (storage 分区)。

## 已知限制 (V1)

- ASR / TTS 已实现真实云端调用 (见上文契约): 端点为空时**不伪造**——`asr_transcribe()`
  直接放弃本次识别 (返回 nil), TTS 也直接放弃本次播报 (不播提示音); 但会把
  `未配置 ASR` / `未配置 TTS` 等**具体原因写上面板状态行**, 不再无反馈。接入真实服务前
  **务必先把 ASR/TTS 域名加入 HTTP 白名单**。
- 录音为「按下开始 / 松开结束」; 短于 `MIN_RECORD_MS` (500ms) 的按键会被丢弃,
  长于 `MAX_RECORD_MS` (10s) 会自动截断 (`/fatfs` 分区仅 3MB)。
- 唤醒词已接入 (C 侧 `ha_voice_wake` / WakeNet「嗨小欧」写 `wake_trigger`), 唤醒后
  自动录音, 靠静音/超时收尾; 该自动录音受网页 `voice_wake_enabled` 门控。
- Home Assistant 接入见 `ha_control` 技能; `ha_enabled` 为唯一门控 (关闭时 `ha_control`
  脚本直接返回, 不触达 HA)。