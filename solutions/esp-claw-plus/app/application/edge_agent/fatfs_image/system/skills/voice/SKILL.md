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
  真实 TTS: 把文本 POST 给云 TTS, 响应音频落盘后异步播放; 播放期间轮询打断标志
  `/fatfs/voice_interrupt`, 命中即停止 (语音打断 / barge-in)。
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

语音链路依赖两条路由规则 (`/fatfs/router_rules/router_rules.json`):

1. `voice_reply_run_script` — 匹配 `source_cap=claw_core`、`event_type=out_message`、
   `chat_id=voice`, 动作 `run_script` 调用 `voice_reply.lua`, 参数 `args.text={{event.text}}`。
   必须排在默认规则 `agent_out_message_send_message` **之前**(`consume_on_match=true`)。
   本设备通过 `event_router --add-rule-json` 安装, 新规则会被插入到规则数组最前面。
2. `startup_voice_ptt` — 匹配 `source_cap=app_claw`、`event_type=startup`、
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

## 语音打断 (barge-in)

跨脚本唯一可行的信道是 `/fatfs` 文件 (音频无全局仲裁器): 用户按下 BOOT 或唤醒命中时,
`voice_ptt.lua` 写 `/fatfs/voice_interrupt` 空标志; `voice_reply.lua` 播放中每 20ms 轮询,
见到标志即 `player:stop()` 并清标志, 实现"说话即打断 TTS"。

## 相关技能

- `ha_control` — HA MCP 控制 (list_tools / call_tool), 受 `ha_enabled` 门控。
- `local_scene` — 离线本地场景联动 (`scene:` 前缀命令 + 启动恢复), 断网可用。

## 运行时配置桥 (网页 -> 语音脚本)

网页「语音助手」页保存的配置, 由 C 侧 `ha_panel.c` 的
`ha_panel_publish_runtime_config()` 写入 `/fatfs/ha_voice_runtime.json`; 两个脚本读取该
JSON 获取 ASR/TTS 端点与唤醒开关 (与屏幕桥同向, 复用 `/fatfs` 可写分区, 无需新增
Lua<->C 绑定)。字段:

| 字段 | 用途 |
| --- | --- |
| `voice_wake_enabled` | 唤醒词自动录音开关; `false` 时 `voice_ptt.lua` 丢弃唤醒触发, 仅保留 BOOT 键 PTT |
| `voice_asr_provider` | ASR 供应商; 空 / `generic` = 通用契约, `volcano` = 火山引擎 |
| `voice_asr_url` / `voice_asr_api_key` | ASR 端点与密钥 (火山云用新版控制台 `X-Api-Key`) |
| `voice_asr_resource_id` | ASR 资源 ID; 留空用 provider 默认 (`volc.seedasr.sauc.duration`) |
| `voice_tts_provider` | TTS 供应商; 空 / `generic` = 通用契约, `volcano` = 火山引擎 |
| `voice_tts_url` / `voice_tts_api_key` | TTS 端点与密钥 |
| `voice_tts_resource_id` | TTS 资源 ID; 留空用 provider 默认 (`seed-tts-2.0`) |
| `voice_tts_speaker` | TTS 发音人; 留空用 provider 默认 (`zh_female_vv_uranus_bigtts`) |
| `ha_enabled` / `ha_base_url` / `ha_token` | Home Assistant 开关与接入信息 (M2 意图路由使用) |

配置在网页保存后即时生效, 无需重启 (脚本每 1s 重新读取一次)。

## 屏幕桥 (对话文本上屏)

语音对话内容会同步显示到 M1 的 LVGL 面板 (`ha_panel.c`)。桥接方式为文件: 脚本通过
`storage.write_file` 写 `/fatfs/voice_*.txt`, 面板每 200ms 轮询读取并刷新标签。

| 文件 | 写入方 | 内容 |
| --- | --- | --- |
| `/fatfs/voice_status.txt` | `voice_ptt.lua` / `voice_reply.lua` | 状态: 流程态 `录音中` / `识别中` / `思考中` / `合成中` / `播报中` / `空闲`; 失败态见下 |
| `/fatfs/voice_user.txt` | `voice_ptt.lua` | ASR 转出的用户文本 |
| `/fatfs/voice_agent.txt` | `voice_reply.lua` | Agent 回复文本 |

**状态反馈**: 每个阶段都把状态/失败原因写进 `voice_status.txt` (面板「状态:」行, 非「空闲」时点亮
指示灯) 并同步打串口日志, **不再静默回到「空闲」**。各阶段的反馈词:

| 阶段 | 反馈 |
| --- | --- |
| 开录音 | `麦克风不可用` / `麦克风占用` (设备或仲裁器拿不到) |
| 录音中 | `录音中`; 读不到数据 → `麦克风读取失败` |
| 录音收尾 | `录音太短 Nms` (松手太快, < 500ms); `未录到声音` (整段峰值 RMS < 150, 不再上传); `录音写盘失败` |
| ASR | `识别中` → `未配置 ASR` / `未配置 ASR 密钥` / `ASR 网络错误` / `ASR HTTP 4xx` / `未识别到语音` (火山返回短消息时直接透出) |
| Agent | `思考中` → 30s 内无回复 → `AI 无响应` |
| TTS | `合成中` → `TTS 网络错误` / `TTS HTTP 4xx` / `TTS 无音频返回` / `未配置 TTS` |
| 播放 | `播报中` → `播放失败` / `播放器创建失败` / `扬声器占用`; 正常播完回 `空闲` |

失败态保留时长: `voice_ptt.lua` 内的失败态保留 4s 后自动回「空闲」(到期改写前会校验面板内容,
避免覆盖 `voice_reply.lua` 已推进的新状态); `voice_reply.lua` 是一次性脚本, 其失败态保留到下一次
语音交互 (PTT 写「录音中」) 覆盖。

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