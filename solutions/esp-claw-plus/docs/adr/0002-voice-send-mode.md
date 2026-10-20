# 语音发送模式：独立字段 + BOOT 键确认手势，而非改造回复模式

状态：accepted

## Context

语音识别不是每次都准，用户有时需要**看过识别结果再决定是否发送**；同时「识别即发送」的免提体验必须保留。已有的 `voice_reply_mode`（`agent` / `direct`）描述的是"发出去之后由谁回答"，与"要不要发"是两件事。

## Decision

1. **新增独立字段 `voice_send_mode`（`auto` | `manual`，默认 `auto`）**，与 `voice_reply_mode` **正交**。二者可任意组合（例如 `manual` + `direct`）。
2. **触发点复用现有 BOOT 键**，不新增 UI：`manual` 时识别完成进入 `pending` 态（面板状态码 `confirming`），用同一颗按键确认。
3. **pending 态手势**：轻点（按住未达 500ms 即松开）= 发送；按住（≥ 500ms）= 作废本次结果并**立即重录**；无操作 15s = 自动作废回 `idle`，**不自动发送**。
4. **pending 态下 BOOT 键不再直接起录音**：`on_press_down` 只记按下时刻，判定放在 `on_press_up`（轻点 → 发送）与主循环 `pending_step()`（按住阈值 → 重录；超时 → 作废）。
5. **两条 ASR 路径共用同一落点**：流式与批量 ASR 都在收尾处改调 `handoff_recognized(text)`，由它按模式决定"直接发送"还是"进 pending"，避免两份分支。

## Considered Options

- **把 manual 做进 `voice_reply_mode` 的第三个取值**：被否——语义正交，混在一起会让已有模式组合爆炸，也让 `chat_id` 载体失去单一含义。
- **新增一个专用"发送"实体键**：被否——本板可用按键有限，且 BOOT 键在 pending 态本就空闲，零新 UI 更优。
- **pending 超时后自动发送**：被否——`manual` 的语义就是"未经确认不发送"，超时发送反而更危险。

## Consequences

- `app_config` 增字段（NVS key `voice_send_md`，受 15 字符上限约束）、`http_server_config_api.c` 注册、网页面板加下拉 + i18n 并重建 `dist`。
- 面板状态码表新增 `confirming`（`ha_panel.c` 查表兜底本就容忍未知 code，但补上才能显示中文「待确认」并点亮忙碌指示）。
- 唤醒词触发的自动录音在 `manual` 下同样需要按键确认（全局设置，语义一致）。
