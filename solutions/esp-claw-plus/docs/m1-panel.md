# M1 面板上屏记录（第一阶段：C 应用层 LVGL 面板）

更新时间：2026-10-10（真机验证：面板正常显示；已去除 mock 实体与语音占位）

> 更新（去 mock）：面板页不再渲染 mock 实体卡片，改为展示 **HA 链接状态**（是否已配置 + 地址）；
> 设备信息页改为 **ESP-Claw 系统状态**分组卡片（网络 / LLM / IM / 语音）。详见 §6。

---

## 1. 目标与范围

M1 的最终验收是「屏上看到米家实体卡片并能开关灯」。第一阶段先打通**显示链路**：

- 在 esp-claw 的 `edge_agent` 应用层自建 LVGL 面板，接管板载 ST7796；
- 面板页验证「绘制 + 触摸切页」闭环；HA 实体卡片留待第二阶段（HA WebSocket client）接入，
  当前**不使用 mock 数据**，面板页只显示 HA 链接状态。

决策来源：HA 接入方式选「先做屏上 UI」；UI 实现选「C 应用层自建 LVGL 面板」。

---

## 2. 关键约束（改造前必须理解）

esp-claw 已经内置了一条完整的显示栈，面板必须与它共存而不是叠加：

| 事实 | 位置 | 影响 |
|---|---|---|
| 屏幕由 `display_arbiter` 仲裁，枚举只有 `NONE/LUA/EMOTE`，**默认 owner = EMOTE** | `components/common/display_arbiter/display_arbiter.c:26-28` | 启动时表情引擎正在画屏，必须显式抢owner |
| `acquire/release` 只接受 LUA 或 EMOTE；LUA 用 `lua_depth` 计数，深度归零才切回 EMOTE | 同文件 `:84` / `:120-137` | 想长期独占屏幕，需 LUA 持有一次不释放 |
| emote 的 flush 回调只在 `display_arbiter_is_owner(EMOTE)` 时才 `esp_lcd_panel_draw_bitmap` | `components/common/emote/emote.c:57-75` | 面板取得 LUA 后，emote 自动停止写屏（无需禁用它） |
| `app_claw_ui_start()` 就是 `emote_start()` | `components/common/app_claw/app_claw.c:209-216` | `app_main` 里它之后即是最佳挂载点 |
| LVGL（`lvgl__lvgl`）已在构建中，但 `lv_init()`/`lv_display_create()` 是 Lua 侧按需懒初始化 | `components/lua_modules/lua_module_lvgl/src/lua_lvgl_runtime.c:446-505` | 启动时 LVGL display 并不存在，C 侧可独占创建 |
| board manager 取句柄：`display_lcd` → `dev_display_lcd_handles_t.panel_handle/io_handle`；触摸设备名是字符串 `"lcd_touch"` → `dev_lcd_touch_handles_t.touch_handle` | `emote.c:90-118`、`lua_module_board_manager.c:237-255` | 无需硬编码控制器句柄 |
| 触摸 LVGL indev 的标准写法：读回调内 `esp_lcd_touch_read_data` + `esp_lcd_touch_get_data` | `lua_lvgl_indev.c:46-68` | 直接照搬到 C 面板 |
| ST7796 走 SPI，板级 YAML 为 `data_endian: BIG` | `board_devices.yaml` | LVGL RGB565 需 **字节序翻转**，缓冲需 **DMA 能力** |

**结论（设计取舍）**：复用 `DISPLAY_ARBITER_OWNER_LUA`，不为面板新增 owner 枚举。
理由：无需改动上游 `display_arbiter`（保持补丁最小），且 LUA 语义上就是「LVGL 显示栈持屏」；
面板在启动时 `acquire(LUA)` 一次并永不释放，owner 即长期为 LUA。代价：Lua 脚本再调
`lvgl.init()` 会因 owner 已是 LUA 而报错——本方案不接受 Lua 侧再建 LVGL display，可接受。

---

## 3. 实现

产出以「应用层叠加 + main.c 补丁」的形式入库（上游克隆 `esp-claw/` 不入库）：

| 入库产物 | 作用 |
|---|---|
| `app/application/edge_agent/main/ha_panel.{c,h}` | 面板实现（由 `setup_esp_claw.sh` 复制进克隆的 `main/`） |
| `patches/esp-claw-m1-panel.patch` | 仅改 `main/main.c`：加 `#include "ha_panel.h"` + 调 `ha_panel_start()` |

`setup_esp_claw.sh` 在板级叠加之后新增「叠加应用层 LVGL 面板 (M1)」步骤：容错应用面板补丁 +
复制 overlay。重新 clone 后重跑脚本即可复原，不丢改动。`main/CMakeLists.txt` 是 `SRC_DIRS "."`，
无需改 CMake。

`ha_panel_start()` 流程：

1. 建自建 mutex（**返回 bool，勿按 `esp_err_t` 判**——AGENTS.md 白屏教训）。
2. 从 board manager 取 `display_lcd` 的 `panel_handle`/`io_handle` 与 `"lcd_touch"` 的 `touch_handle`。
3. `display_arbiter_acquire(DISPLAY_ARBITER_OWNER_LUA)` 取得屏幕。
4. 分配绘制缓冲（`MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA`，40 行 × 320 × 2B = 38,400 B）。
5. `lv_init()` → `lv_display_create(320,480)` → 设 partial 缓冲与 flush 回调。
6. flush 回调：判权失败则 `lv_display_flush_ready` 直接返回；否则 `bswap16` 后 `esp_lcd_panel_draw_bitmap`，
   由 panel io 的 `on_color_trans_done` 回调触发 `lv_display_flush_ready`（异步刷新，标准 port 写法）。
7. 注册触摸 indev（`LV_INDEV_TYPE_POINTER`）。
8. 构建分页 screen：标题条 + 底部分页条（面板 / 语音 / 设备）；三页内容由 `ha_panel_build_*_page()` 生成。
9. 起 5 ms tick 定时器 + 10 ms 周期的 LVGL task（优先级 4，栈 8 KB）。

构建注意：新增 `main/*.c` 后 `idf.py -B build build` **不会**被 CMake 缓存 glob 捕获
（只重编了 `main.c.obj`，链接期报 `undefined reference to ha_panel_start`）；
必须先 `idf.py -B build reconfigure` 再 build。

---

## 4. 真机验证

烧录：仅烧 app 分区，保留 nvs(Wi-Fi) 与 /fatfs(LLM 配置)：

```
idf.py -p /dev/tty.usbmodem5B910423531 -b 460800 -B build app-flash
# 等价于写 0x20000 edge_agent.bin（flash_args 中 app 偏移）
```

关键日志：

```
I (1894) DEV_LCD_TOUCH: Successfully initialized LCD touch: lcd_touch, chip: ft5x06, sub_type: i2c
I (2459) display_arbiter: display owner changed to lua
I (2535) ha_panel: HA panel started: 320x480, buf=38400 bytes, touch=yes
...
I (12395) main_task: Returned from app_main()
```

| 检查项 | 结果 |
|---|---|
| 无 panic / 无重启循环 | ✅ |
| display owner 切到 lua | ✅ |
| 触摸设备可用（`touch=yes`） | ✅ |
| 屏上出现深色背景 + 蓝色标题条 + 底部分页条（面板 / 语音 / 设备） | ✅ 目视确认 |
| 触摸可切页、页面内容解耦 | ✅ 目视确认 |
| Wi-Fi STA / LLM 对话不受影响 | ✅ |

遗留（非阻塞）：`transport: Version mismatch: Host [2.12.0] > Co-proc [0.0.0]`（C6 协处理器固件版本，
与 M0 相同，待办）；`sdmmc 0x107`（无 TF 卡）等告警照旧。

---

## 5. 第二阶段（待真实 HA）

需用户提供：HA 地址（http/https + 端口）与**长期访问令牌**。计划：

1. 新增 `main/ha_client.c`：`esp_websocket_client`（构建中已有 `espressif__esp_websocket_client`）
   连 `ws(s)://<ha>/api/websocket`，处理 `auth_required` → `auth` → `auth_ok`，
   发 `subscribe_events`（`state_changed`）/`get_states`。
2. 在面板页填入真实实体列表（`ha_panel_build_panel_page()` 当前只显示 HA 链接状态，无 mock），
   开关回调发 `call_service`（`light.turn_on/off` 等），状态回包驱动 UI 刷新。
3. 复用现有 display_arbiter 判权：HA 状态更新只在 owner 为 LUA 时刷新 UI。

HA 侧前置（见 README §6.4）：安装米家集成 → 启用 MCP Server → 生成长期令牌。

### 5.1 配置项已就位（验收暂停）

按本轮要求，先在 esp-claw 上把 HA 地址/令牌的**配置能力**做好（只做 plumbing），真机验收**暂停**
（用户暂无地址/令牌）。产物为 `patches/esp-claw-ha-config.patch`（5 个文件）：

- `app_config.c/.h`：新增 NVS 配置字段 `ha_base_url`、`ha_token`（默认空串）；
- `http_server_config_api.c`：把二者挂到配置分组的 **`ha`** 组，可用 `POST /api/config` 写入；
- `app_claw.h`：`app_claw_config_t` 增加两字段；
- `main.c`：配置拷贝函数补齐两字段。

回环自测方式（凭据到位后）：`POST /api/config`，分组 `ha`，字段 `ha_base_url` / `ha_token`；
只做了编译级验证，尚未真机往返，见 `docs/m0-verification.md` 同款 `/api/config` 用法。

### 5.2 基座化落地（设备端分页菜单 + 网页配置 + 运行时桥）

按 README §1.2「新增能力一律长在 ESP-Claw 上」的三条原则，本阶段在 §5.1 的 plumbing 之上补齐：

**(1) 设备端界面 → 底部分页菜单**

`ha_panel.c` 从"单屏"升级为**底部导航条三页**，触摸切页，页面内容解耦：

| 页面 | 内容 |
|---|---|
| 面板 | **HA 链接状态**（是否已配置 + 地址；无 mock 实体）；随 `ha_enabled` 显隐 |
| 语音 | 唤醒状态 + 最近一条字幕 + 最近一条 Agent 回复（镜像自语音 Lua 脚本写的 `/fatfs` 文件） |
| 设备信息 | **ESP-Claw 系统状态**分组卡片：网络 / LLM / IM / 语音（详见 §6） |

**(2) 配置能力 → 走 ESP-Claw 网页配置机制**

新增 `patches/esp-claw-ha-voice-config.patch`（4 个文件），在既有 `ha` 组加启停开关并新增 `voice` 组：

| 分组 | 前端字段名 | NVS key | 说明 |
|---|---|---|---|
| ha | `ha_enabled` | `ha_enabled` | HA 启用开关（true/false，默认 true） |
| voice | `voice_wake_enabled` | `voice_wake_en` | 本地唤醒开关（默认 true） |
| voice | `voice_asr_url` / `voice_asr_api_key` | `voice_asr_url` / `voice_asr_key` | 云 ASR 端点与密钥（默认空） |
| voice | `voice_tts_url` / `voice_tts_api_key` | `voice_tts_url` / `voice_tts_key` | 云 TTS 端点与密钥（默认空） |

前端（SolidJS）新增 **HA 配置页 / 语音配置页**：`client.ts` 的 `AppConfig` / `ConfigGroup` / `GROUP_FIELDS`
与 C 侧 `CONFIG_FIELDS[]` 同步，i18n 中英双语补齐，重建 `dist/index.html.gz` 作为 overlay 叠加
（`setup_esp_claw.sh` 已加拷贝步骤）。`http_server_config_api.c` 的布尔校验扩展到
`ha_enabled` / `voice_wake_enabled`。

**(3) 运行时配置桥（网页 → 语音脚本）**

`main.c` 保存配置后调用 `ha_panel_publish_runtime_config()`，把上述字段写入
`/fatfs/ha_voice_runtime.json`；Lua 语音脚本（`voice_ptt.lua` / `voice_reply.lua`）读取其中的
ASR/TTS 端点与 `voice_wake_enabled` 门控，**保存即生效、无需重启**。复用既有 `/fatfs` 可写分区，
不新增 Lua↔C 绑定（与"屏幕桥"同向）。

> 说明：M1 阶段完成的是**门控 plumbing**——`ha_enabled` 已写入运行时 JSON 并驱动设备信息页；
> 完整的 HA MCP + LLM 意图路由（启用时才把请求经 MCP 转 HA）归 M2 落地。

---

## 6. 去 mock + 设备系统状态（本轮变更）

### 6.1 面板页：mock 实体 → HA 链接状态

删除 `ha_entity_card_t` / `ha_panel_add_entity_card()` / `ha_entity_switch_cb()` 与两张 mock 卡片。
面板页改为一卡两行：`状态: 已配置 · 未接入` / `未配置`，`地址: <ha_base_url>` / `(未配置)`。
「已配置」以 `ha_base_url` 非空判定；「已接入」待真实 HA WebSocket client 落地（第二阶段）。

### 6.2 设备页：ESP-Claw 系统状态分组卡片

设备页改为四张分组卡片，页面开启**垂直滚动**（卡片多于屏幕）：

| 卡片 | 行 | 数据源 / 判定 |
|---|---|---|
| 网络 | 网络名 / 连接 / IP 地址 / AP 热点 | `app_config.wifi_ssid` + `wifi_manager_get_status()`（`sta_connected`→已连接(绿)+IP；`ap_active`→AP 模式；`sta_configured`→未连接；否则未设置）。AP 热点行独立展示 `ap_ssid` + `ap_ip`（`ap_active`→开着(绿)，否则"未开启"） |
| LLM | 状态 / 模型 | `llm_api_key` 或 `llm_base_url` 非空 → 已设置；模型取 `llm_model`（空显示 `-`） |
| IM | 已设置: N/4 + 两行渠道标记 | 逐渠道判凭据：微信 `wechat_token`、飞书 `feishu_app_id`、QQ `qq_app_id`、电报 `tg_bot_token`；不臆造"已连接" |
| 语音 | 语音唤醒 / ASR / TTS | `voice_wake_enabled` 门控 + `voice_asr_url` / `voice_tts_url` 是否已配置 |

网络行**运行时轮询**（面板任务每 200 ms 调 `ha_panel_refresh_network()`），其余行在配置保存时
经 `ha_panel_publish_runtime_config()` → `ha_panel_refresh_info()` 刷新。所有行用 `ha_panel_set_label()`
做「文本变化才 `set_text`」的缓存比较，避免轮询强制重绘。

### 6.3 语音占位移除

- `voice_ptt.lua`：`voice_asr_url` 为空时不再返回固定文本「你好，请简单介绍一下你自己」，
  改为打印错误并 `return nil`，当轮直接放弃，同时把失败原因（`未配置 ASR` 等）写上面板状态行，
  不再静默回 `空闲`（见 `voice-integration.md` §4.1「状态反馈」）。
- `voice_reply.lua`：删除 `tone_freq` / `tone_ms` / `play_tone_only()`；`voice_tts_url` 为空时不播任何
  提示音，直接放弃本次回复；DAC 输出改为**端点检查之后**才打开，各失败分支统一 `output:close(); return`。