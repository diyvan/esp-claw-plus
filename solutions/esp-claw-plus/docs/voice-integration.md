# 语音与 esp-claw 集成记录（M3 / V1 第一阶段）

更新时间：2026-10-08（真机验证：PTT 启动 ✅、注入→Agent→回复回传 ✅、麦克风录音/回放 ✅）

> 后续更新（M2/M3/M4 代码落地，待真机凭据联调）：ASR/TTS 真实云调用、语音打断（barge-in）、
> HA MCP 执行（`ha_control`）与离线本地联动（`local_scene`）均已实现，详见 §6。

---

## 1. 目标与范围

按 §6.2 的 V1 方案，把「语音」接进 esp-claw 现有的渠道层与 Agent Loop，**不新增 C 通道**：

```
BOOT 键按下 → 录音(WAV) → [ASR] → 文本注入渠道层 → Agent Loop(LLM)
           → out_message 事件 → 路由规则 → [TTS/播放]
```

本阶段打通的是**链路与机制**；ASR/TTS 云端调用已在 M3 落地（base64+JSON 上传 / `save_path` 落盘回放 / 语音打断），本机只需在网页配置页填入端点与密钥、并把域名加入 HTTP 白名单即可启用，见 §6。

> **配置基座化（本轮新增）**：ASR/TTS 端点与密钥、本地唤醒开关不再写死在脚本里，改为从 ESP-Claw
> 的**网页配置页**读取——C 侧 `app_config`(NVS) → `ha_panel_publish_runtime_config()` 写
> `/fatfs/ha_voice_runtime.json` → 语音脚本读取。保存即生效，无需重启，也不新增 Lua↔C 绑定。

---

## 2. 关键机制发现（决定了实现方式）

| 问题 | 结论 | 位置 |
|---|---|---|
| Agent 的回复如何回传？ | Agent 完成后构造 `out_message` 事件：`source_cap=claw_core`、`source_channel=回复目标渠道`、`chat_id`、`text`，经 `claw_event_router_publish()` 入队 | `claw_core_events.c` `claw_core_publish_out_message_if_requested()` |
| 回复怎么变成"语音播报"？ | 用**路由规则**匹配该 `out_message`，动作 `run_script` 调 Lua，回复文本在 `args.text` | `claw_event_router.c` 动作分发 |
| 自定义规则会不会被默认规则抢走？ | `claw_event_router_add_rule()` 用 `cJSON_InsertItemInArray(root, 0, ...)` **头插**，且匹配按数组顺序、遇 `consume_on_match=true` 即 break → 后加的规则天然优先 | `claw_event_router.c:2705` |
| 怎么避免和默认回复冲突？ | 语音用**专用渠道 `voice` + 专用 `chat_id=voice`**，规则只匹配 `chat_id=voice` 且 `consume_on_match=true` | 见 §3 规则 |
| 常驻 PTT 循环怎么跑？ | `run_script` 带 `input.async=true` → `lua_run_script_async`，默认 `timeout_ms=0` = 运行到被取消 | `cap_lua.c` |
| 无匹配消息去哪？ | `default_route_messages_to_agent=true` 且 `event_type=message` → 走默认 Agent；默认规则 `im_any_message_agent` 同样命中，故注入的文本自然进 Agent | `claw_event_router.c` 默认分支 |

> 结论：**全程零 C 改动**即可完成语音↔Agent 双向闭环。

---

## 3. 入库产物

上游克隆 `esp-claw/` 不入库，语音资产以「fatfs overlay + 规则 JSON + 安装脚本」形式入库，`setup_esp_claw.sh` 负责叠加。

| 入库产物 | 分区/位置 | 作用 |
|---|---|---|
| `app/application/edge_agent/fatfs_image/system/skills/voice/SKILL.md` | `/system` | 技能声明（**必须有 JSON frontmatter**，见 §5 教训） |
| `.../system/skills/voice/scripts/voice_ptt.lua` | `/system` | 常驻 PTT 循环：GPIO35 按下 → 录音 → ASR → `ep.publish_message` 注入 `voice/voice`（ASR 端点/密钥 + `voice_enabled`/`voice_wake_enabled` 门控读运行时 JSON） |
| `.../system/skills/voice/scripts/voice_reply.lua` | `/system` | 回复播报（非流式回退路径）：`args.text` → [TTS]（端点为空则放弃播报，不播提示音；TTS 端点/密钥读运行时 JSON） |
| `.../system/skills/voice/scripts/voice_tts.lua` | `/system` | TTS **共享合成模块**：`synthesize(cfg, text, out_base, root_dir)`（落盘回退路径）+ `stream_request(cfg, text)`（返回流式请求描述，供边收边播，见 §7.3），被 `voice_reply.lua` 与 `voice_ptt.lua` 的句子级流水线复用（generic 端点或 provider 分派，见 §7） |
| `.../system/skills/voice/scripts/voice_selftest.lua` | `/system` | 录音+回放自检（不依赖按键），验证 ES8311 输入/输出通路 |
| `.../system/skills/voice/scripts/providers/*.lua` | `/system` | 云端服务适配层（供应商插件）：`util.lua` 公共工具 + `asr_volcano.lua` / `tts_volcano.lua` 火山引擎适配器，见 §6.3 |
| `.../system/font/font_puhui_common_14_1.bin` | `/system` | 全量常用字 CJK 字体（272KB），供面板显示中文 |
| `app/router_rules/voice_rules.json` | 规则源 | 两条规则，供安装脚本逐条下发 |
| `scripts/install_voice_rules.py` | 主机侧 | 经串口 REPL 用 `event_router --add-rule-json` 安装规则 |
| `patches/esp-claw-display-owner.patch` | esp-claw 补丁 | 修 `lua_module_display` 退出钩子误释放面板持有的屏幕（详见 §4.1） |
| `patches/esp-claw-ha-voice-config.patch` | esp-claw 补丁 | 加 `ha_enabled` + `voice` 组配置字段，并在 `main.c` 保存配置后调 `ha_panel_publish_runtime_config()` 写运行时 JSON |
| `patches/esp-claw-voice-latency.patch` | esp-claw 补丁 | 延迟优化①③：`voice` 渠道注入「简短回复」系统提示（`claw_core_context.c`）+ `cap_http_request` 新增 `decode_base64_field` 字段级流式解码下沉（去掉 FATFS raw-JSON 中转与纯 Lua 解码），见 §7 |
| `patches/esp-claw-llm-stream.patch` | esp-claw 补丁 | 延迟优化④：LLM 流式 SSE（transport 增量解析 + delta 回调 + `out_message_delta` 落盘桥接），见 §7 |
| `patches/esp-claw-tts-stream.patch` | esp-claw 补丁 | 延迟优化②：新增 `cap_tts_stream` 组件（HTTP 流式 + base64 增量解码 + StreamBuffer）并为 `audio.player` 增 `play_stream`（`raw://` 输入回调拉取），见 §7.3 |

> **运行时配置桥**：`/fatfs/ha_voice_runtime.json` 由 C 侧（`ha_panel.c`）写出，字段 `ha_enabled` /
> `voice_enabled` / `ha_base_url` / `ha_token` / `voice_wake_enabled` / `voice_asr_provider` /
> `voice_asr_url` / `voice_asr_api_key` / `voice_asr_resource_id` / `voice_tts_provider` /
> `voice_tts_url` / `voice_tts_api_key` / `voice_tts_resource_id` / `voice_tts_speaker`；Lua 侧用
> `storage.read_file` + `json.decode` 读取（`voice_ptt.lua` 带 1s 缓存，`voice_reply.lua` 单次读取）。
>
> `voice_asr_provider` / `voice_tts_provider` 为**供应商选择**：空 / `generic` 走原通用契约，
> `volcano` 走火山引擎适配器（见 §6.3）；`*_resource_id` / `voice_tts_speaker` 留空时由 provider
> 取内置默认值（`volc.bigasr.auc_turbo` / `seed-tts-2.0` / `zh_female_vv_uranus_bigtts`）。
>
> `voice_enabled` 是语音**总开关**（独立于 `voice_wake_enabled`）：关闭时设备端隐藏「语音」分页、
> 禁用按键说话与唤醒词。该字段亦驱动设备端分页门控与唤醒跳转，见 §4.2。

`setup_esp_claw.sh` 新增「叠加语音技能」步骤：

```bash
FS_OVERLAY="$SOLUTION_DIR/app/application/edge_agent/fatfs_image"
cp -R "$FS_OVERLAY"/. "$SRC_DIR/application/edge_agent/fatfs_image/"
```

### 部署策略

- **Lua 技能放 `system` 分区（只读资产）**：无用户配置，重烧 `system.bin` 安全（不会动 `storage` 里的 LLM/Wi-Fi 配置）。
- **路由规则运行时安装**：`event_router --add-rule-json` 落盘到 `/fatfs/router_rules/router_rules.json`，
  重启后持久；避免重烧 `storage` 分区。规则的 `.recovery` 种子只在文件缺失时才补，改种子不会更新已存在文件，故不用种子方式。

### 两条规则

1. `voice_reply_run_script`（`consume_on_match=true`）— 匹配 `source_cap=claw_core` / `event_type=out_message` /
   `content_type=text` / `chat_id=voice` → `run_script(async)` 调 `voice_reply.lua`，`args.text={{event.text}}`。
2. `startup_voice_ptt`（`consume_on_match=false`）— 匹配 `source_cap=app_claw` / `event_type=startup` /
   `event_key=boot_completed` / `content_type=trigger` → `run_script(async)` 启动 `voice_ptt.lua`。

> M2 另加两条**离线本地联动**规则（`app/router_rules/local_rules.json`）：
> `local_scene_command`（`scene:` 前缀文本，`consume_on_match=true`，参数 `args.scene={{match.remainder}}`）
> 与 `startup_local_scene`（启动恢复上次场景，`args.scene="boot"`）。
> `install_voice_rules.py` 会同时安装语音与本地两组规则；两组规则亦已并入
> `/system/.recovery/router_rules/router_rules.json` 种子，重烧后自动恢复。

---

## 4. 真机验证

构建：`idf.py -B build build`（app）+ `idf.py -B build fatfs_system_bin`（`build/system.bin`）。

烧录（保留 nvs 与 storage）：

```
esptool --chip esp32p4 -b 460800 write-flash --flash-mode dio --flash-size 16MB --flash-freq 80m \
  0x20000 build/edge_agent.bin 0xb20000 build/system.bin
```

安装规则（沙箱外、用 IDF 的 python 环境）：

```
$IDF_PYTHON_ENV_PATH/bin/python solutions/ha_ai_panel/scripts/install_voice_rules.py
```

| 检查项 | 关键日志 | 结果 |
|---|---|---|
| 启动无 abort、技能加载 | `claw_skill: Reloaded registry with 19 skill(s)`、`Loaded 10 router rules` | ✅ |
| PTT 常驻任务自动启动 | `matched rule=startup_voice_ptt actions=1` → `Queued Lua async job ... voice_ptt.lua timeout_ms=0` → `[voice_ptt] ready: GPIO 35 active_level=0, record 4000ms` | ✅ |
| 注入 → Agent | `event_router --emit-message --source-cap lua_script --channel voice --chat-id voice --text "hello"` → `matched rule=im_any_message_agent` → LLM `completion status=done` | ✅ |
| Agent 回复回传 | `type=out_message source=claw_core channel=voice` → `matched rule=voice_reply_run_script` → `[voice_reply] agent reply (121 chars): Hello! ESP-Claw here...` | ✅ |
| 回复播报（历史：早期占位） | 早期版本无 TTS 端点时播 880Hz/200ms 提示音；**本轮已移除**，端点为空时直接放弃播报 | ⚠️ 已废弃 |
| 麦克风录音通路 | `lua --run --path /system/skills/voice/scripts/voice_selftest.lua` → `recorded /fatfs/voice_selftest.wav bytes=576000`（48kHz×3s×16bit×2ch 恰为 576000） | ✅ |
| 扬声器回放通路 | `playback done: /fatfs/voice_selftest.wav` | ✅ |
| **按下 BOOT 键触发录音** | 需人手按键，`[voice_ptt] PTT down` → `recorded ...` | ⏳ 待用户实按 |
| **屏上显示对话（中文）** | `ha_panel: CJK font loaded: /system/font/font_puhui_common_14_1.bin` → 回复后 `ha_panel: voice agent: 好的，以后都用中文回答。` | ✅ 日志确认（目视待用户确认） |
| 抢屏恢复 | `display_arbiter: display owner changed to emote` → 约 7ms 后 `display owner changed to lua` | ✅ |

注：注入消息时 `im_any_message_working_reply` 会尝试 `send_message` 到 `voice` 渠道并报
`send_message resolve failed channel=voice err=ESP_ERR_NOT_FOUND`——属预期（`voice` 是纯内部虚拟渠道，
无出站绑定），不影响链路。

### 4.1 屏上显示对话文本（M1 面板叠加）

`ha_panel.c`（M1 的 LVGL 面板）叠加一块「语音区」，把对话内容（状态 / 你说 / AI 说）显示到屏上。

- **桥接方式**：Lua 侧 `storage.write_file` 写 `/fatfs/voice_{status,user,agent}.txt`（`/system` 只读，
  必须落 `/fatfs`）；C 侧面板任务每 200ms 轮询，文本变化才 `lv_label_set_text` + `ESP_LOGI`
  （`voice status` / `voice user` / `voice agent`）。**零上游补丁**。
- **状态反馈（本轮新增）**：`voice_status.txt` 不再只在「录音中 / 思考中 / 空闲」之间跳，而是
  覆盖每个阶段并把**失败原因**透出上屏（面板「状态:」行 + 非「空闲」点亮指示灯 + 串口
  `status ->` 日志）：`麦克风不可用`/`麦克风占用`、`录音太短 Nms`、`未录到声音`（整段峰值
  RMS < 150，直接跳过上传）、`未配置 ASR`/`ASR 网络错误`/`ASR HTTP 4xx`/`未识别到语音`、
  `思考中` 30s 无回复 → `AI 无响应`、`合成中` → `TTS 网络错误`/`TTS 无音频返回`、
  `播报中` → `播放失败`。失败态在 `voice_ptt.lua` 内保留 4s 后自动回「空闲」（到期改写前校验
  面板当前内容，避免覆盖 `voice_reply.lua` 已推进的新状态）；`voice_reply.lua` 为一次性脚本，
  其失败态保留到下一次语音交互覆盖。
- **中文渲染字体**：`/system/font/font_puhui_common_14_1.bin`（272KB，1bpp/14px），经
  `gfx_font_lv_load_from_binary()` 加载（与 emote 引擎同路径，**无需 lv_fs**）。
  链接进 ELF 的 `font_puhui_basic_20_4` 只有 787 字形 / 199 个 CJK，不足以显示任意 LLM 回复，故弃用。
- **必须先开 `CONFIG_LV_FONT_FMT_TXT_LARGE=y`**（否则中文乱码，见 §5.7）。
- **时序坑**：`ha_panel_start()` 早于 `app_fs_init()` 挂载 `/system`（面板 2479ms vs 挂载 2490ms），
  首次 `fopen` 必然失败 → 字体改为**延迟加载**：面板任务内重试，挂载后首轮即成功。
- **抢屏坑（根因，已修）**：`lua_module_display` 的 Lua 退出钩子 `lua_display_exit_cleanup()` 会在**每个 Lua 脚本退出时**
  无条件 `display_arbiter_release(LUA)`——它只判断「当前 owner 是不是 LUA」，而面板正是以 LUA 身份长期持有，
  于是任何脚本（如 `voice_reply.lua`）结束都会把屏幕交还给 emote，emote 立刻把 claw 表情页画到屏上
  → 表现为「跳回 claw 页面 / 与 HA 面板混在一起」。面板再夺回时 LVGL 只重绘失效区，被 emote 覆盖的像素不会擦除，
  于是残影与新内容叠加成「乱码」。
  **修复**：`patches/esp-claw-display-owner.patch` 给该模块加 `s_display_owned` 标志，只有自己 `display.init()`
  成功过才在退出时释放。另在面板侧加防御：每帧校验 owner，丢失即 `acquire` 并 `lv_obj_invalidate(全屏)`，
  强制整屏重绘以清除他人残留像素。

### 4.2 语音分页门控与唤醒跳转

`ha_panel.c` 依据运行时配置驱动设备端分页（与 Lua 侧同源，读 `/fatfs/ha_voice_runtime.json`）：

- **分页门控**：`ha_enabled=false` 隐藏「面板」页；`voice_enabled=false` 隐藏「语音」页。对应底部分页标签同步隐藏；若当前页被隐藏则自动切到首个可见页（「设备信息」页恒可见）。
- **唤醒跳转**：唤醒词命中时（`ha_voice_wake` 事件回调）自动切到「语音」页；BOOT 键 PTT 不触发跳转。仅当「语音」页可见（`voice_enabled=true`）时才跳转。
- **生效时机**：`ha_panel_publish_runtime_config()` 写出运行时 JSON 的同时刷新分页显隐（配置保存即生效）；唤醒回调由 `ha_voice_wake_set_callback()` 在 `ha_panel_start()` 内注册。

---

## 5. 踩坑与修复

1. **新增 `SKILL.md` 缺 JSON frontmatter → 设备 abort 重启循环**（最严重）。
   `claw_skill` 报 `skill file voice/skill.md has invalid metadata` → `reload registry: ESP_ERR_INVALID_ARG`
   → `app_claw_start` 返回 `ESP_ERR_INVALID_ARG` → `ESP_ERROR_CHECK` → `abort()` 循环，串口进不了 REPL。
   **修复**：`SKILL.md` 必须以如下 frontmatter 开头（与 `light_switch/SKILL.md` 一致）：

   ```markdown
   ---
   {
     "name": "voice",
     "description": "...",
     "metadata": { "cap_groups": ["cap_lua"], "manage_mode": "readonly" }
   }
   ---
   ```

2. **REPL 命令名不是 `router` 而是 `event_router`**（`cmd_cap_router_mgr.c:455`）。
   误用 `router` 得到 `Unrecognized command`，规则一条没装上。
3. **串口提示符检测**：设备启动完成后不会自发打印 `app> `，脚本需主动敲回车逼出提示符，
   且要在整个接收缓冲里找提示符（不能只看尾部 64 字节）。
4. **`--text` 参数必须加引号**，否则 argtable 报 `option "--text" requires an argument`；
   且**控制台参数解析对非 ASCII 文本不友好**——传中文会得到 `option "" requires an argument`。
   故真机自测注入用 ASCII（如 `"hello"`）；真实链路的中文来自 ASR 结果，不经控制台，不受影响。
5. **CMake glob**：新增 `main/*.c` 需 `idf.py -B build reconfigure`（沿用 M1 教训）。
6. **屏幕被「悄悄夺走」→ 界面混合**（详见 §4.1 抢屏坑）。
   `lua_module_display` 的退出钩子把面板以 LUA 身份持有的屏幕误释放，emote 抢到后画 claw 表情页；
   面板夺回时 LVGL 按失效区增量重绘，残留像素与新内容叠加。修复：新增
   `patches/esp-claw-display-owner.patch`（只释放自己 acquire 过的屏幕）+ 面板侧「夺回即整屏重绘」。
   注：此坑只造成「残影/混合」，**不是**中文乱码的原因（乱码根因是 §5.7 的字体格式）。

7. **中文乱码（字形错位）→ `CONFIG_LV_FONT_FMT_TXT_LARGE` 必须为 `y`**。
   emote 资产字体（`font_puhui_common_*.bin`）按 LVGL **大字体格式**生成：`glyph_dsc` 每条 **16 字节**
   （`bitmap_index`/`adv_w` 为 u32；`esp_emote_gfx` 的 `gfx_glyph_dsc_t` 同布局）。实测
   `106528 B / 6658 glyphs ≈ 16.0 B/glyph` 佐证。而项目默认 `LV_FONT_FMT_TXT_LARGE=0`（8 字节步长），
   LVGL 读 `glyph_dsc[gid]` 整体错位 → 所有 CJK 字形取到错误位图 → 乱码。
   **关键判别现象**：**英文正常、中文乱码**——因为面板里 ASCII 标签（`Living Room Light`/`On`/`Off`）
   未套用该字体，走 LVGL 内置 Montserrat；只有中文标签用加载的 CJK 字体，故只有中文错位。
   **修复**：`boards/waveshare_esp32_p4_wifi6_touch_lcd_3_5/sdkconfig.defaults.board` 设
   `CONFIG_LV_FONT_FMT_TXT_LARGE=y`（C 数组字体如 `font_puhui_basic_20_4` 随宏重编，不受影响）。
   验证：`ha_panel` 打印 `glyph U+4F60 found=1 box=13x12 adv=14`（你）、`box=12x13`（好）等度量正常。
   附带修：字体是**延迟加载**的，`build_ui` 里对 `title`/`hint` 的 `apply_font` 此时 `s_cjk_font==NULL`
   故为空操作；`ensure_font()` 除刷 3 个语音标签外，还须补刷 `s_title_label`/`s_hint_label`，否则标题和
   底部提示会一直用内置字体 → 中文乱码（聊天框内容正常）。

8. **重烧 `storage.bin` 会清掉运行时装的语音路由规则 → BOOT 键失效**。
   两条语音规则（`voice_reply_run_script` / `startup_voice_ptt`）原由 `scripts/install_voice_rules.py`
   经 `event_router --add-rule-json` 落到 `/fatfs/router_rules/router_rules.json`，而 `/fatfs` 正是
   `storage` 分区；`idf.py flash` 每次都会重写 `storage.bin`（`wl_fatfsgen` 重新生成）→ 规则被冲回默认 8 条
   → `startup_voice_ptt` 不存在 → `voice_ptt.lua` 从未启动 → 按 BOOT 无反应（连 `[voice_ptt] ready` 都没有）。
   **修复**：把两条规则并入 overlay 的
   `app/application/edge_agent/fatfs_image/system/.recovery/router_rules/router_rules.json`
   （语音规则置于数组最前，保证 `voice_reply_run_script` 先于 `agent_out_message_send_message` 匹配）。
   `app_fs` 的 `recover_missing_files()` 会把 `/system/.recovery` 里**缺失**的文件补到 `/fatfs`，
   于是每次新烧录后自动恢复，无需再手动跑安装脚本。验证：启动日志 `Loaded 10 router rules` +
   `matched rule=startup_voice_ptt` + `[voice_ptt] ready: GPIO 35 ...`。
   另：日常只改面板代码时用 **`idf.py app-flash`**（或只写 `0x20000` 的 app 分区），可保留 `/fatfs`。

---

## 6. 已知限制与后续

**云端 ASR / TTS（M3 已实现）**

> 本节描述的是**通用契约**（`voice_asr_provider` / `voice_tts_provider` 为空或 `generic` 时的默认行为）。
> 另有**供应商分派**机制：填 `volcano` 走火山引擎适配器、未来可扩展阿里云等，见 §6.3。

- `voice_ptt.lua` 的 `asr_transcribe()`：端点取自运行时配置 `voice_asr_url`（网页配置页填写）。
  端点非空时读 `/fatfs/voice_ptt.wav` → **纯 Lua base64 编码**（`http_request` 的 body 只能是字符串，
  音频必须 base64 进 JSON）→ `capability.call("http_request", ...)` POST：
  `{"format":"wav","sample_rate":<sr>,"channels":<ch>,"bits":<b>,"audio_base64":"<...>"}`；
  响应文本依次尝试 `text`/`transcript`/`result`/`output_text`/`data`(字符串或 `.text`/`.result`)/
  `choices[1].message.content`（非 JSON 退化为去引号纯文本）。**端点为空**时不伪造转写，直接放弃本次识别
  （面板状态行显示 `未配置 ASR`）。
- `voice_reply.lua`：端点取自 `voice_tts_url`。端点非空时 POST `{"format":"wav","text":"<escaped>"}`，
  返回的音频经 `http_request` 的 `save_path` **二进制落盘**到 `/fatfs/voice_reply.wav`（写 `.tmp` 再 rename），
  再用 `audio.player` **异步播放**；非 200 或落盘失败则放弃本次播放（面板状态行显示 `TTS HTTP 4xx` /
  `TTS 响应缺失`）。**端点为空**时直接放弃，不播提示音（状态行显示 `未配置 TTS`）。
  支持 WAV/MP3/AAC/FLAC 解码（**不支持 OPUS/AMR**）。
- ⚠️ **必须先把 ASR/TTS 域名加入 `cap_http_request` 主机白名单**（NVS `http_allow_ls` /
  `search_http_allowlist`），否则请求会被拒绝；密钥非空时自动附 `Authorization: Bearer <key>`。

**语音打断（barge-in，M4 已实现）**

- 音频**没有全局仲裁器**（`ha_voice_arbiter` 只管麦克风输入），跨脚本停止播放只能靠文件标志：
  用户按下 BOOT 或唤醒命中时 `voice_ptt.lua` 写 `/fatfs/voice_interrupt`；`voice_reply.lua`
  播放中每 20ms `player:poll()` 一次并检查该标志，命中即 `player:stop()` 并清除标志。

**HA 执行（M2 已实现，见 `ha_control` / `local_scene` 技能）**

- `ha_control` 技能经 `cap_mcp_client`（`mcp_list_tools` / `mcp_call_tool`，新增 `bearer_token` 入参）
  调用 HA MCP Server；脚本先读运行时 JSON 的 `ha_enabled`，**关闭时直接返回、不触达 HA**；
  `ha_base_url` 的 origin 作 `server_url`、路径作 `endpoint`（Streamable HTTP 单端点，**不要给 SSE URL**）。
- `local_scene` 技能为**离线确定性联动**：`scene:` 前缀文本命令（`consume_on_match=true`，不进 LLM）
  与开机恢复规则，状态落 `/fatfs/local_scene_state.json`（断网可用）。
- `ha_enabled` / `ha_base_url` / `ha_token` 随运行时 JSON 下发并驱动设备信息页；启用时由 LLM
  做意图识别，仅在意图需要时才把请求经 MCP 转 HA，关闭时纯 ESP-Claw。

**功能后续**

- ✅ 录音「按下即录固定 4s」→ **已改为「按下开始 / 松开结束」**（`voice_ptt.lua` 状态机 + `press_up` 回调 + 手工 44 字节 WAV 头；真机实测时长随按键变化：2.02s / 1.65s，不再是固定 4s）。
- ✅ `voice_selftest.lua` 自清理：录完回放后 `pcall(storage.remove, rec_path)` 删除临时 wav，不再在 `/fatfs` 留 ~576KB 残留。
- 🔄 唤醒词（esp-sr WakeNet）：**脚手架已打通**——esp-sr 2.4.4 在本板（IDF v6.1 / P4 rev1.3）编译、烧录、`model` 分区加载全部真机验证通过（见 §6.1）；唤醒逻辑本身（AFE + 检测回环）待实现，当前仍仅 BOOT 键触发。**已定唤醒词「嗨小欧」（`wn9_hai1xiao3ou1_tts3`）**——官方内置 TTS Pipeline V3 模型，免费商用、无需自行训练（原「你好小登」自定义方案需走 TTS Pipeline 训练，因存在现成同结构词而放弃）。唤醒触发文件 `wake_trigger` 已由 `voice_ptt.lua` 消费（`consume_wake_trigger()`），并按网页配置 `voice_wake_enabled` 门控——关闭时唤醒触发被丢弃，仅保留 BOOT 键 PTT。
- 🔄 音频设备争用（esp-sr AFE vs esp-claw `audio`）：§9 风险 9，唤醒与录音分时复用。设计方案见 §6.2。

### 6.1 唤醒词接入调研结论（esp-sr WakeNet，2026-10-08）

**① 依赖形态：注册表已可直接用（M0 结论需更正）**
- 组件注册表 `espressif/esp-sr` 最新为 **2.4.4**（约 2026-10-02 发布），其 `idf_component.yml` 已声明 **`ESP-IDF >=5.0`（无上限）+ 依赖 `espressif/cjson`**，
  即已适配 IDF v6 —— **不再需要像 M0 那样下载 142MB 的 git master**，直接 `idf.py add-dependency "espressif/esp-sr^2.4.4"` 即可。
- 传递依赖：`espressif/dl_fft >=0.2.0`、`espressif/esp-dsp 1.8.0`（`esp-dsp` 工程内已存在）。
- **已实测验证**（2026-10-08）：2.4.4 在本工程 + IDF v6.1 + P4 **rev1.3**（`CONFIG_ESP32P4_SELECTS_REV_LESS_V3` → 库目录 `esp32p4_less_v3_idf6`）下可解析、可编译、可加载。真机启动日志：

  ```text
  I (2540) MODEL_LOADER: The partition size is 896 KB
  I (2540) MODEL_LOADER: Successfully load srmodels
  I (2543) ha_panel: esp-sr: 2 model(s) loaded from "model" partition
  I (2549) ha_panel: esp-sr:   [0] wn9_hai1xiao3ou1_tts3
  I (2554) ha_panel: esp-sr:   [1] vadnet1_medium
  I (2558) ha_panel: esp-sr: wakenet candidate = wn9_hai1xiao3ou1_tts3
  ```

**② 模型体积 / 内存（负 = 可行）**
- 单个 WakeNet9 模型 ≈ **284 KB**（`wn9_hilexin`：`wn9_data` 289,796 B + `wn9_index` 1,152 B）；VAD（`vadnet1_medium`）≈ **288 KB**。
- 实测打包体积（`wn9_hai1xiao3ou1_tts3` + `vadnet1_medium`）→ `srmodels.bin` = **579,132 B（≈566 KB）**，movemodel 报告 "Recommended Partition Size: 567K"，装入 896 KB 的 `model` 分区余量充足。
- 运行时：WakeNet9 **16 KB internal + ~324 KB PSRAM**；整条 `MR,SR` AFE 约 **60 KB internal + ~740 KB PSRAM**。
- P4 有 32MB PSRAM（README 风险 8）→ 内存侧无压力；**无需 MultiNet**（命令词走云端 ASR）。

**③ 分区表：末尾空隙放 `model`；后续因技能增多再调 `system`（README 风险 6 可降级）— 已落地**
- 现状末尾空隙 `0xf20000..0x1000000` = **0xE0000（896 KB）** 完全空闲。新增 `model` 数据分区（label 固定为 `model`，subtype `spiffs`）放这里即可容纳单 WakeNet9 + VAD（实测 566 KB）。
- **M2/M3 追加调整**：新增 `ha_control` / `local_scene` 技能与脚本后，`system` 分区（FAT、4KB 簇）因小文件极多、簇取整浪费而撑爆 1M（`fatfsgen: NoFreeClusterException`）。
  故 `system` 1M→**1.5M（0x180000）**，`ota_0/ota_1` 4.5M→**4.25M（0x440000）**（app 实测 4.13MB，余 3%）；`emote`(3M)/`storage`(2M)/`model` 不变。布局正好排满 16MB。
- esp-sr 的 CMake 会在 `idf.py flash` 时把 `srmodels.bin` 烧进 `model` 分区（实测 `0xf20000`，579,108 B，hash verified）；缺该分区会构建失败。
- 落地方式：`partitions_16MB.csv` 增 `model` 行 + `main/idf_component.yml` 增 `espressif/esp-sr ^2.4.4`，二者经 `patches/esp-claw-esp-sr.patch` 持久化（`setup_esp_claw.sh` 自动应用）。模型 Kconfig 写在 `boards/…/sdkconfig.defaults.board`（**须重跑 `bmgr` 并丢弃旧 `sdkconfig` 重新生成**才会生效）。

**④ AFE 输入格式 = 16 kHz / 16-bit / 交织**（关键改造点）
- esp-sr `afe->feed()` 要求 **16 kHz、16-bit、通道交织**；而本板 ES8311 + I2S 实际为 **48 kHz / 2ch**（见 §5 真机 `48000Hz/2ch/16bit`）。
- 因此需在 codec 与 AFE 之间做 **48k→16k 重采样 + 2ch→1ch 降混**（工程内已有 `esp_asrc` / `esp_audio_effects`），**或**在唤醒模式下把 codec/I2S 重配为 16k/2ch。

**⑤ 音频共享模型（决定分时复用方案）**
- `audio_adc` 与 `audio_dac` 在 board_manager 里是**两个独立注册的设备**，各自 `esp_codec_dev_init` → **输入句柄 ≠ 输出句柄**（共享同一 i2c_master 与 I2S port）。
- Lua `audio` 模块**没有跨对象互斥**：`active` 是 per-userdata 的（只防同对象重入），`holders` 只用于「有 player/recorder 引用时不许 close」。
- ⇒ 唤醒 AFE 任务与 Lua `voice_ptt.lua` 的 `input:read` 若同时读同一个 ADC 句柄会互相抢数据。**必须外部分时复用**（详见 §6.2）。

**⑥ 脚手架验证实现（本轮落地）**
- 探针 `ha_panel_sr_probe()`（[ha_panel.c](file:///Users/diyvan/Lab/esp-idf/ESP32-P4-WIFI6-Touch-LCD-3.5/solutions/ha_ai_panel/app/application/edge_agent/main/ha_panel.c)）：启动时 `esp_srmodel_init("model")` → 打印模型清单 → `esp_srmodel_deinit()`；非致命（失败只 `ESP_LOGE`，不影响面板启动）。
- 仅用于证实「模型可加载」，**不代表唤醒可用**：尚无 AFE、无麦克风喂数据、无检测回调。下一阶段用真正 AFE（含 §6.2 的分时复用）替换此探针。

### 6.2 唤醒词 + 录音分时复用（待实现方案）

思路：**一个「音频仲裁器」串行化 ADC 的占用**，唤醒与录音 / 播放互不并发。

```
[AFE 唤醒任务]  常驻持有 ADC → 16k feed → 检测到唤醒词
        │（检测到后释放 ADC / 暂停 feed）
        ▼
[发布 esp-claw 事件] wake 事件 → 路由规则 → 触发录音
        ▼
[voice_ptt 录音] 独占有 ADC → 录 WAV → ASR → 注入 Agent
        ▼
[Agent 回复] out_message → voice_reply.lua → TTS 播放（独占 DAC）
        ▼
播放结束 → 仲裁器放行 → AFE 唤醒任务重新占有 ADC
```

待定决策（见对话确认）：
- 唤醒词选择（内置：`你好小智` / `Hi 乐鑫` / `Alexa` …，或自定义训练）。
- 首版深度：全 AFE（含 AEC，为将来 TTS 打断）vs 仅 WakeNet（先跑通唤醒，AEC 后加）。
- 唤醒事件如何进入 esp-claw：新增路由规则触发 `voice_ptt.lua`（免按 BOOT）。

### 6.3 云端服务供应商扩展（provider 分派）

语音脚本对云端服务做了一层**供应商分派**：运行时配置 `voice_asr_provider` / `voice_tts_provider`
为空或 `generic` 时走 §6 的通用契约（即历史行为，完全不变）；填其它名字时按
`require("providers.<asr|tts>_<provider>")` 加载适配器。ASR 适配器若导出 `open` 则走
**流式会话**（边说边发、增量上屏），否则回退到 `transcribe` 批量契约；TTS 适配器调用 `synthesize`。
**新增云端服务（如阿里云）只需加一个适配器文件，generic 路径与其他 provider 均不受影响。**

| 产物 | 位置 | 说明 |
|---|---|---|
| `.../voice/scripts/providers/util.lua` | `/system` | 供应商公共工具：`base64_encode` / `base64_decode`（流式，防浮点精度丢失）/ `json_escape` / `uuid` / `http_post`（包装 `capability.call("http_request", ...)`，解析 `HTTP <status>\n<body>`） |
| `.../voice/scripts/providers/asr_volcano.lua` | `/system` | 火山引擎 ASR 适配器，导出流式会话 `open(cfg, info)` → 会话对象（`send` / `poll` / `finish` / `abort`）或 `nil, reason` |
| `.../voice/scripts/providers/tts_volcano.lua` | `/system` | 火山引擎 TTS 适配器，导出 `synthesize(cfg, text, out_path, root_dir)` → `true` 或 `false, reason`，外加 `default_ext`；另导出 `stream_request(cfg, text)` → 流式请求描述（url/headers/body/timeout_ms，见 §7.3） |

> `reason` 为给面板状态行用的简短中文失败原因（如 `未配置 ASR 密钥` / `ASR HTTP 401` /
> `TTS 无音频返回`），调用方（`voice_ptt.lua` / `voice_reply.lua`）用 `set_error()` 写
> `/fatfs/voice_status.txt`，见 §4.1「状态反馈」。

> `<script_dir>`（= `/system/skills/voice/scripts`）已被 `cap_lua_runtime.c` 加入 `package.path`，
> 故 `require("providers.asr_volcano")` 可直接命中 `providers/asr_volcano.lua`，无需额外配置。

**火山引擎（豆包语音，`provider = "volcano"`）**——**新版控制台鉴权**，仅需 `X-Api-Key`
（即配置项 `voice_asr_api_key` / `voice_tts_api_key`），不再需要旧版 `X-Api-App-Key` + `X-Api-Access-Key`：

- **ASR**：流式语音识别 **2.0（大模型流式）** `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`
  （WebSocket，火山 sauc 二进制协议，由 C 侧能力 `asr_stream` 封帧收发）。会话式：边说边发
  16-bit PCM 分片，增量返回累计文本（实时写入 `/fatfs/voice_user.txt` 上屏），收尾发末包得最终
  文本，**不再落盘 WAV**。WS 升级 header `X-Api-Key` / `X-Api-Resource-Id`（默认
  `volc.seedasr.sauc.duration`）/ `X-Api-Connect-Id`。⚠️ 该资源需在火山控制台开通，且 API Key
  类型需匹配 — 否则 WS 握手会返回 403。
- **TTS**：大模型语音合成 **V3 单向流式** `POST https://openspeech.bytedance.com/api/v3/tts/unidirectional`，
  header `X-Api-Key` / `X-Api-Resource-Id`（默认 `seed-tts-2.0`）/ `X-Api-Request-Id`；body
  `req_params.text` + `speaker`（默认 `zh_female_vv_uranus_bigtts`，Vivi 2.0）+ `audio_params`（mp3 / **16000Hz**）。
  响应为 chunked 流式 JSON，音频为 base64 分块——先经 `http_request` 的 `save_path` 全量落盘，
  再在 Lua 内**逐块解码后拼接字节**（不能拼 base64 字符串，分块各自补齐会损坏），写出
  `/fatfs/voice_reply.mp3` 后播放（`default_ext = "mp3"`）。
- ⚠️ 与通用契约同理，`openspeech.bytedance.com` **必须加入 `cap_http_request` 主机白名单**；
  火山 TTS 响应体（含 base64 音频）较大，`http_request` 需以 `save_path` 落盘（上限
  `max_file_bytes` 设为 4MB），不能靠 64KB 的 body 上限。

> 说明：**resource_id / speaker 留空时由 provider 取内置默认值**，故配置页可不填即可先跑通；
> 需要切换不同模型/音色时再在配置页填写。

---

## 7. 端到端延迟优化（逐项落地）

语音链路为「PTT 松开 → ASR → Agent(LLM) → TTS → 播放」，耗时集中在 **LLM 首字**与
**TTS 首帧**。按 7 项优化清单逐项落地，状态如下（✅ 已落地并编译通过 / ⏳ 未开始）：

| # | 优化项 | 落地方式 | 状态 |
|---|---|---|---|
| ① | 回复更短（减少 LLM 输出 token） | `claw_core_context.c`：`voice` 渠道注入「简短口语回复」系统提示 | ✅（补丁 `esp-claw-voice-latency.patch`） |
| ② | TTS 真·边收边播 | 新增 `cap_tts_stream` 组件（HTTP 流式 + base64 增量解码 + StreamBuffer）+ `audio.player:play_stream`（`raw://` 输入回调）；Lua 侧 `voice_tts.stream_request` 分派、`voice_ptt` 流式优先播报；**开关 = `/fatfs/voice_tts_stream` 标记文件**（见 §7.3） | ✅（补丁 `esp-claw-tts-stream.patch`；真机录音回放实测 `RESULT=OK`，首帧起播 5ms，见 §7.3） |
| ③ | 解码/写盘下沉 C、去掉 FATFS 中转 | `cap_http_request` 新增 `decode_base64_field`，在 C 侧完成字段级流式 base64 解码并直接落音频文件 | ✅（补丁 `esp-claw-voice-latency.patch`） |
| ④ | LLM 流式 SSE + 句子级流水线 | C 侧增量 delta → `/fatfs/voice_stream.txt`；`voice_ptt.lua` 常驻消费、按句切分逐句 TTS 播放 | ✅（补丁 `esp-claw-llm-stream.patch`） |
| ⑤ | 连接/会话复用 | — | ⏳ 未开始 |
| ⑥ | 降码率/采样率 | `tts_volcano.lua` 采样率 24kHz→16kHz（见 §6.3） | ✅（overlay，无补丁） |
| ⑦ | 构建验证 + 固化补丁 + 文档 | 本文件 + `setup_esp_claw.sh` 注册三个新补丁 | ✅ |

### 7.1 LLM 流式 + 句子级流水线（优化④，本轮实现）

目标：不再等 LLM 完整回复，而是**边生成边播报**——首句一到就合成播放，后续句子在播放中陆续就绪。

**C 侧（`esp-claw-llm-stream.patch`，8 个文件）**

- `claw_llm_types.h` / `claw_llm_http_transport.c` / `claw_llm_backend_openai_compatible.c`：
  为 OpenAI 兼容后端启用 `stream:true` 的 SSE，**在 transport 层增量解析** `data:` 行，
  逐 delta 触发回调（`on_delta(text_delta, user_ctx)`），仅累积完整文本；非流式后端不受影响。
- `claw_core_llm.[ch]`：把 `on_delta` / `on_delta_user_ctx` 透传给后端。
- `claw_core.h`：新增 `CLAW_CORE_REQUEST_FLAG_STREAM_REPLY (1U << 4)`。
- `claw_core_agent_loop.c`：当请求带该 flag 时，打开 `claw_core_stream_sink_t`，把每个 delta
  写入 `/fatfs/voice_stream.txt`（**每累积约 12 字节 `fflush`+`fsync`**，让消费端尽快看到），
  结束后追加结束标记 `\x01\x01END\x01\x01` 并关闭。**已流式发出的请求不再重复发 `out_message`**
  （避免非流式回退路径又播一遍）。
- `claw_event_router.c`：目标/来源 `chat_id == "voice"` 时，为该 agent 请求置 `STREAM_REPLY` flag。

> 用**文件**（而非新增 Lua↔C 绑定或事件）做流桥，是为了复用既有机制、零新增绑定：C 侧天然串行，
> 避免路由 async 并发拉起多路播放。

**Lua 侧（overlay，`voice_ptt.lua` + 共享模块 `voice_tts.lua`）**

- `voice_ptt.lua` 状态机新增 `waiting` 态：注入 ASR 文本进 Agent 后即进入等待，**每 20ms** 轮询
  增量读取 `voice_stream.txt`，按标点（强标点 `。！？!?；;\n` / 弱标点 `，,、：:`，弱标点超 40 字兜底）
  切句入队，逐句经 `voice_tts.synthesize()` 合成并用 `audio.player` 播放（player 惰性创建，
  一句播完再播下一句）→ 天然串行、无需并发仲裁。
- 结束条件：读到结束标记 **且** 队列清空 **且** player 空闲 → 写回「空闲」，回到 `idle` 态。
- barge-in：`start_recording()` 与 `wait_step()` 轮询里检查 `/fatfs/voice_interrupt`，命中即
  `player:stop()` 并中止等待（复用 §6 的打断标志）。
- 超时：沿用 `REPLY_TIMEOUT_MS`（30s），无任何 delta 则状态行显示 `AI 无响应`。
- `voice_reply.lua` 重构为复用共享模块 `voice_tts.lua`（generic 端点或 provider 分派），
  作为**非流式回退路径**保留（LLM 后端不支持流式时仍可用）。

### 7.2 接线与验证

`setup_esp_claw.sh` 在语音延迟补丁之后新增**三段**幂等 `git apply`（先 `--check`，已应用则
`--reverse --check` 跳过），依次注册 `esp-claw-voice-latency.patch`、`esp-claw-llm-stream.patch`
与 `esp-claw-tts-stream.patch`；Lua/面板改动仍走 fatfs overlay 的 `cp -R`（见 §3）。

构建验证：`cd esp-claw/application/edge_agent && idf.py build` → `edge_agent.bin`（0x425b60，约 4.15MB）
链接成功、`system.bin` 重新打包成功。**真机录音回放实测通过**（2026-10-13，见 §7.3）。

> 新增 `cap_tts_stream` 组件后**首次构建需先 `idf.py reconfigure`**：`idf.py build` 触发的
> `cmake --regenerate-during-build` 不会重跑 IDF 组件管理器的清单求解，嵌套 `idf_component.yml`
> 改动不生效；本补丁已把 `cap_tts_stream` 注册进根清单 `main/idf_component.yml`，故正确重配即解析。

### 7.3 TTS 真·边收边播（优化②，本轮实现）

目标：TTS 音频**边下载边播放**，不再「等服务端全量合成 → base64 全量落盘 → 解码 → 再播」，
把 TTS 首帧等待压到最低。

**C 侧（`esp-claw-tts-stream.patch`）**

- 新增组件 `components/claw_capabilities/cap_tts_stream`（纯 C helper，非 claw 工具组，故**无需**
  `app_capabilities.c`/Kconfig 注册）：起一个 HTTP 任务 `POST` 流式端点，**增量扫描**响应里的
  `"data":"<base64>"` 字段，逐块 `mbedtls_base64_decode` 后推入 `StreamBuffer`（48KB，带背压），
  供播放器**拉取**：`cap_tts_stream_begin/read/end/active`（`read` 返回 `>0` 字节数 / `0`=EOF / `<0`=错误）。
- `lua_module_audio`：`esp_asp_cfg_t.in.cb` 增 `audio_player_in_cb` → `cap_tts_stream_read`；
  新增 Lua 方法 **`player:play_stream({url, headers, body, timeout_ms})`**（`lua_audio_player_play_stream`），
  走 `raw://tts/stream.mp3` URI（`AUDIO_STREAM_RAW_URI`）。`player:stop()`/`close()` 调 `cap_tts_stream_end()` 收尾（barge-in 复用）。
  **现有 `player({output=...})` 文件播放路径完全不变**（全部为新增可选路径）。

**Lua 侧（overlay，`tts_volcano.lua` + `voice_tts.lua` + `voice_ptt.lua`）**

- `providers/tts_volcano.lua` 增 `stream_request(cfg, text)` → 返回 `{url, headers, body, timeout_ms}`（不落盘）；
  `voice_tts.lua` 增 `stream_request` 分派：provider 为空/`generic` 返回 `nil`（回退落盘路径），否则转发 provider 的同名函数。
- `voice_ptt.lua` 增 `play_sentence_stream(sentence)`：`stream_request` → 必要时创建 `audio.player` →
  `player:play_stream(req)`；`play_sentence` 优先走流式，失败/不支持则回退 `synthesize` + `player:play(path)`。
- **流式模式门控**：`cap_tts_stream` 为**单会话**，故流式下**必须等上一句播完再起下一句**
  （`wait_step` 用 `player_running` gate）；非流式模式保持原有逐句串行行为不变。
- **开关（默认关闭、零回归）**：在设备「文件」页把 `voice_tts_stream` 标记文件加到 `/fatfs` 即启用
  边收边播；删除即回退「落盘合成」路径。与仓库既有 `wake_trigger`/`voice_interrupt` 同款标记文件模式，
  **不引入 web UI / C 配置改动**。

> ⚠️ **已知行为差异**：item ② 直连 `esp_http_client`（在 `cap_tts_stream` 内），**绕过**
> `cap_http_request` 的主机白名单校验；即只要网页配置页填了 TTS 端点，流式路径即会直连该主机。
> 未开启该标记文件时不受影响（仍走 `cap_http_request` 受白名单约束）。
> ⚠️ **真机回放实测（2026-10-13，ESP32-P4 rev1.3，保留 storage 分区仅烧 app+system）**：
> 用罐装录音 `/system/voicetest/asr_sample.wav`（16kHz/mono/16bit，「今天天气怎么样」）驱动
> 全链路自测脚本 `voice_e2e.lua`，串口 REPL 执行 `lua --run --path /system/voicetest/voice_e2e.lua`：
> `ASR=OK text=今天天气怎么样？` → `reply streamed; skipping out_message publish`（流式路径）
> → `tts_stream: session done: pushed=82413 bytes, status=200` →
> `PLAY[1] start=5.0ms done=16498.0ms` → `RESULT=OK sentences=1 first_play=7984.0ms total=24522ms`。
> **首帧起播仅 5ms**（提交流式请求到播放器进入 running），证实「边收边播」而非等全量落盘；全程无 panic/看门狗。
> barge-in 打断在途音频仍待专项实测。

### 7.4 语音回复上屏修复 + 屏幕桥收敛为共享模块（本轮实现）

**症状**：语音问答后状态行/「你说」正常，但面板「AI 说」永远不更新。

**根因**：`voice` 渠道的每轮对话 C 侧恒定走流式（`claw_event_router.c` 对 `chat_id=="voice"`
必打 `STREAM_REPLY`），流式下 `claw_core_agent_loop.c` 在 `stream_sink.emitted` 时**跳过
`out_message` 发布**，于是路由规则 `voice_reply_run_script`（匹配 `out_message`）永不命中，
`voice_reply.lua` 成为死路径——而它恰是 `voice_agent.txt` 的**唯一写入者**，故「AI 说」永不刷新。

**修复（candidates 1+2）**

- 新增共享模块 `system/skills/voice/scripts/voice_common.lua`，作为三个 `/fatfs` 约定的
  **唯一 owner**：屏幕桥（`set_status`/`set_user`/`set_agent`/`append_agent`/`clear_agent`/
  `read_status`）、运行时配置桥（`load_runtime_config`/`runtime_config`）、打断信道
  （`signal_interrupt`/`clear_interrupt`/`interrupt_requested`）。此前这三件事在
  `voice_ptt.lua` / `voice_reply.lua` 里各有一份逐字相同的拷贝，加字段要改多处且易走偏。
- `voice_ptt.lua` 的流式播报路径在**每切出一句**时 `vc.append_agent(sentence)`（面板随播报
  逐句增长），并在 `arm_reply_wait()`（注入前）`vc.clear_agent()` 清空上一轮，避免增量接力粘连。
- 屏幕桥写盘改为**非破坏性原子写**：写 `<name>.tmp` → 删目标 → 改名（FatFs `f_rename` 在目标
  已存在时返回 `FR_EXIST`，故必须先删）；若面板恰落在窗口期，读到文件不存在会**跳过本次刷新**
  保留上一帧，不闪空白。
- `voice_reply.lua` 与非流式回退路径保留（构成真 seam），改为调用同一模块；`voice_e2e.lua`
  新增上屏断言 `SCREEN=OK|MISMATCH|EMPTY`。

**真机实测（2026-10-13，ESP32-P4 rev1.3，仅烧 app+system，保留 storage）**

```
[voice_e2e] ASR=OK text=今天天气怎么样？
I (18512) ha_panel: voice agent:
[voice_e2e] SENTENCE[1] text=深圳天气这边我真拿不到，…
I (27397) ha_panel: voice agent: 深圳天气这边我真拿不到，…
[voice_e2e] SCREEN=OK chars=144
```

`SCREEN=OK` 表示 `voice_agent.txt` 内容与流式可见文本逐字相符；`ha_panel: voice agent: …`
为面板轮询到新文本并刷新 LVGL 标签的直接证据。该修复不依赖 C 侧改动。

> ⚠️ **同轮观察到的独立问题（不在本轮范围）**：本次自测 `PLAY[1]` 报
> `E tts_stream: stream buffer create failed` → `RESULT=PARTIAL`。该失败发生在 C 侧
> `cap_tts_stream` 的 `xStreamBufferCreate(48KB)`（内部 RAM），与本次 Lua 收敛无关（未改播放
> 路径）；疑似常驻 WakeNet/AFE + WiFi 占用内部 RAM 后 48KB 连续块拿不到，与 §7.3 早期
> `RESULT=OK` 的差异待专项排查。**播放失败不影响本轮「回复上屏」的验证结论。**

### 7.5 状态码桥 + 可滚动多轮会话记录（候选 3+4，本轮实现）

**候选 3 — 状态 token 枚举（消除中文字面量耦合）**

- 动因：`voice_status.txt` 原为自由中文串（`录音中`/`识别中`/…），面板靠 `strcmp` 比对中文
  字面量决定「忙碌」指示灯。措辞与语义耦合——改一个字面量就悄悄改坏指示灯；失败原因又是另一
  套自由文本，面板无法区分「流程态」与「失败态」。
- 方案：`voice_status.txt` 改为单行 `<code>|<detail>`。`code` ∈
  `idle` / `recording` / `recognizing` / `thinking` / `synthesizing` / `speaking` / `error`
  （机器可读 token），`detail` 为可选自由文本（失败原因 / 火山短消息）。C 侧 `ha_panel.c` 用
  `s_voice_status_map[]` 查表得中文标签 + `busy` 标志；未知 `code` 兜底为「未知」+ 忙碌。**一切
  失败统一写 `error|<原因>`**。
- Lua 侧：`voice_common.set_status(code, detail)` + `read_status_code()`；`voice_ptt.lua` 状态机
  （`set_wait` / `set_error` / `tick_status`）改用 code，`tick_status` 到期改写前用
  `read_status_code()` 做 guard，避免覆盖 `voice_reply.lua` 已推进的新状态。

**候选 4 — 可滚动多轮会话记录（取代单条「你说/AI 说」）**

- 动因：原单条「你说 / AI 说」只能看到最后一轮；回复上限 768B 且两段缓冲开在 8KB 任务栈上。
- 方案：新增 `voice_log.txt`，内容为多条记录 `<role>\x1f<text>\x1e>`（`role` = `U`/`A`；
  `\x1f`/`\x1e` 控制符分隔，LLM 输出不含故无需转义），**取代** `voice_user.txt` /
  `voice_agent.txt`。`voice_common` 侧 `log_user` / `log_agent` / `log_agent_append` /
  `clear_log`，按 `MAX_LOG_RECORDS` (8) 裁剪。
  - **流式逐句增长同一气泡**：`log_agent_append` 命中最后一条 A 则拼接，否则新建；每轮先
    `log_user` 写 U，使新回复的 append 不会粘到上一轮的 A。
  - **流式 ASR 增量**：`log_user` 覆盖最后一条 U（而非新增），支持识别文本逐段上屏。
- C 侧：`ha_panel.c` 语音页 = 固定状态行 + 可滚动 log 容器（flex column +
  `lv_obj_set_scroll_dir(LV_DIR_VER)` + `LV_SCROLLBAR_MODE_AUTO`）；`ha_panel_read_raw` 二进制
  安全读入 **PSRAM** 缓冲（40KB read + 40KB snapshot），`strcmp` 与快照比对、仅变更时
  `ha_panel_rebuild_log()` 重建气泡并 `lv_obj_scroll_to_view` 到最后一条。单条上限
  `HA_VOICE_TEXT_MAX` 768 → 4096，缓冲移出任务栈/内部 RAM。

**真机实测（2026-10-13，ESP32-P4 rev1.3，仅烧 app+system，保留 storage）**

```
[voice_e2e] ASR=OK text=今天天气怎么样？
I (18668) ha_panel: voice log rebuilt: 1 record(s)
I (19110) ha_panel: voice status: code=recognizing detail=e2e-probe
[voice_e2e] SENTENCE[1] text=答案还是一样：深圳天气查不到，我不会编。你想测什么直接说。
I (23749) ha_panel: voice log rebuilt: 2 record(s)
I (25633) tts_stream: session done: pushed=45549 bytes, status=200
[voice_e2e] RESULT=OK sentences=1 first_play=4942.0ms total=16689ms
[voice_e2e] SCREEN=OK chars=87
[voice_e2e] STATUS=OK value=recognizing|e2e-probe
I (36030) ha_panel: voice status: code=idle detail=-
```

- `voice log rebuilt: 1 record(s)` → `2 record(s)`：面板按控制符切分并重建气泡（先用户气泡，再追加
  助手气泡），候选 4 的 C 重建路径被真实执行。
- `voice status: code=recognizing detail=e2e-probe`：C 侧查表 + `detail` 解析成功（`e2e-probe`
  为自测探针写入的 detail）；末尾 `code=idle` 为收尾 `set_status("idle")` 被面板映射，候选 3
  端到端贯通。
- `SCREEN=OK` / `STATUS=OK`：`voice_log.txt` / `voice_status.txt` 的字节与脚本写入逐字相符。
- 另在真实 PTT 流程中观察到 `[voice_ptt] status -> error (ASR 网络连接失败)` →
  `ha_panel: voice status: code=error detail=ASR 网络连接失败`，验证失败态 `code|detail` 端到端。
- 同轮 `tts_stream: session done: pushed=45549 bytes, status=200` → §7.4 记录的
  `stream buffer create failed` 本轮未复现（播放正常，`PLAY[1] done=11712ms`）。
