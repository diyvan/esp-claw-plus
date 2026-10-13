# 计划(v2):solutions/ha_ai_panel — HA 面板 + 小智语音 + ESP-Claw 执行引擎

## Summary

应用户要求加入 `espressif/esp-claw` 作为 **AI 执行层**并重新评估可行性。终态愿景不变:一块 ESP32-P4 板 = 触摸 HA 面板(控米家)+ AI 语音(唤醒/多轮对话)+ **ESP-Claw 边缘 Agent(本地感知/决策/执行闭环)**。本轮交付物不变:仅新增 `solutions/ha_ai_panel/README.md` 整体方案文档,固件实现待文档评审后再启动。

## 新核实的事实(本轮调研)

- **esp-claw 定位**:乐鑫官方 Chat Coding 边缘 Agent 框架(2026-04 发布)。LLM 动态决策 + Lua 确定性规则、事件驱动(毫秒级)、本地结构化记忆(JSONL+tags,隐私不上云)、**MCP Server/Client 双身份**、IM 渠道(Telegram/QQ/飞书/微信)、Board Manager(YAML 声明式板级配置)。
- **P4 支持**:README 明确支持 ESP32-P4(本地构建);板级目录已有 `waveshare_esp32_p4_nano`(微雪 P4+C6 板),其 `board_devices.yaml` 含 **ES8311 音频 ADC/DAC + i2s_audio_in/out**——与本板同款 codec,语音 I/O 是一等设备类型。本板适配 = 仿写一套 YAML(`board_devices.yaml`/`board_peripherals.yaml`/`setup_device.c`/`sdkconfig.defaults.board`)。
- **执行链路红利**:Home Assistant 内置 MCP Server 集成 → esp-claw 作为 MCP Client 可直接调用 HA 控制实体(米家设备经 `XiaoMi/ha_xiaomi_home` 暴露),"AI 执行"落到米家无需自写工具桥。
- **xiaozhi v2.4.0** 官方支持本板,语音对话(esp-sr 唤醒 + OPUS + WS/MQTT+UDP + 多轮)开箱即用。
- **核心矛盾**:xiaozhi 与 esp-claw 都是完整应用框架(各自 main/任务模型/板级抽象/NVS 布局),单固件合并 = 框架级手术;esp-claw 交互以 IM 为主,语音对话(唤醒+ASR/TTS)不是其核心能力;esp-claw 较新,API 未稳定,IDF 版本要求与本仓库 v6.1 的兼容性待 M0 核实。
- CI(`scripts/ci/classify_changes.py`)只路由 `examples/esp-idf/`,新建顶层目录不影响 CI。

## 架构路线对比(文档中将完整呈现,供用户选定)

| 路线 | 基座 | 现成 | 需自建 | 风险 |
|---|---|---|---|---|
| **A 单固件·xiaozhi 基座** | xiaozhi v2.4.0 | 语音对话全链路 | esp-claw agent loop/Lua/MCP/记忆组件化嵌入;LVGL HA 面板页 | 高(双框架合并手术) |
| **B 单固件·esp-claw 基座** | esp-claw edge_agent | 执行/记忆/MCP/Lua | 语音链路自建(esp-sr+录音+云 ASR/TTS);LVGL 面板页 | 中高(语音体验最难保证) |
| **C 双固件分阶段(推荐起步)** | 固件1=xiaozhi 官方;固件2=esp-claw | 各自核心能力 | 固件2 加本板适配(仿 p4_nano)+ LVGL HA 面板页 | 最低;缺点=同一时刻只跑一个固件,切换需重烧 |

**推荐**:C 起步(每步真机可验收),跑通后基于验证数据决策是否合并(A/B)。

## 本轮执行(仅新增 1 个文件)

`solutions/ha_ai_panel/README.md`(中文),章节 = v1 大纲(目标/硬件盘点/架构图/功能规格/验收标准)基础上重写:

1. 目标与范围(明确不做的:直连米家云、ESPHome、摄像头)
2. 硬件资源盘点(ES8311+mic+喇叭是 esp-claw 语音 I/O 与小智语音的公共基础)
3. 总体架构(mermaid):LVGL UI / 小智语音协议栈 / **ESP-Claw Agent Runtime(LLM+Lua+MCP+记忆)** / HA WebSocket client / NVS / BSP 2.0.2 / esp_hosted(C6)
4. **三条路线完整对比 + 推荐**(上表展开:接口切分图、各自工作量分解)
5. 功能规格:面板(连接配置/实体分组/卡片/场景)、语音(唤醒/多轮/打断)、**Agent 执行(MCP Client→HA MCP Server 控米家、Lua 本地规则断网可用、MCP Server 暴露板载传感器/执行器)**
6. 里程碑:M0 双官方固件真机验证(xiaozhi 语音 / esp-claw 适配本板)→ M1 固件2 + LVGL HA 面板 → M2 MCP→HA 控米家 + Lua 规则 → M3 语音意图接入 Agent(桥接)→ M4 合并决策(可选单固件化)
7. 后续目录规划(实现阶段):`solutions/ha_ai_panel/` 下按路线 A/B/C 分别列出结构;`config/revision_profiles.cmake` 接入方式
8. 风险与开放问题:v2 新增——esp-claw API 未稳定(锁 tag)、双框架合并的工程量、esp-claw 的 IDF 版本兼容性、HA MCP Server 版本要求(≥2025.x)、语音意图→Agent 的桥接协议设计
9. 验收标准:每里程碑编译要求(rev1_3 档)+ 真机验收点;引用 `docs/flash.md`

## Assumptions & Decisions

- 用户已确认:对话引擎 = 小智云;面板 = 自研 LVGL + HA WebSocket;目录 = `solutions/ha_ai_panel/`;**AI 执行 = ESP-Claw**
- 路线 A/B/C 的最终选择在文档评审时由用户拍板,文档给推荐(C 起步)
- 本轮只写文档,不动 CI、不改 docs/、不建固件代码

## Verification

- `git status` 仅新增 `solutions/ha_ai_panel/README.md`
- 文档自查:三路线对比可执行、里程碑可验收、风险有缓解方向
- 用户评审通过后进入 M0 实施
