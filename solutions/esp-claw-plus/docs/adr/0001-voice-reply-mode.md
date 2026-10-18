# 语音回复模式：在 Agent Loop 内切换，而非另建“直连 LLM”路径

状态：accepted

## Context

语音一轮的延迟主要花在 LLM 首字。实测表明 claw 路径对「无工具调用」的普通问答本来就只做一次 LLM 往返，相对直连 LLM 的额外开销仅是系统提示/工具 schema 的 prefill 与可能的工具往返。为让用户能在设备上按需在「要能力的问答」与「要确定性的快速问答」之间选择，引入回复模式 `agent` / `direct`。

## Decision

1. **不新建“直连 LLM”的 HTTP 路径**。Lua 侧没有流式 HTTP 读（`cap_http_request` 整包落盘），走 Lua 直连会丢掉 SSE、反而更慢。`direct` 改为复用 claw_core Agent Loop：新增一个 request flag，仅关掉工具、上下文与持久化，并使用极简 system prompt。流式回复桥、逐句流水线、barge-in、状态上屏全部原样复用。
2. **模式由 Lua 换算成 `chat_id` 传递**（agent→`voice`，direct→`voice_llm`），router 据此打 flag。原因：C 侧的 router/claw_core 不读 `app_config` 与运行时 JSON，且 Lua 的 `publish_message` 无法携带自定义字段。
3. **开关放设备语音面板**，状态存 NVS（字段 `voice_reply_mode`，默认 `agent`），并镜像到 `ha_voice_runtime.json` 供 Lua 读取（≤1s 生效）。
4. **direct 仅复用 LLM 配置**（`llm_base_url/model/api_key` 与 agent 同源），不新增一套。
5. **direct 的 system prompt**：一条极简约束（简短口语、≤80 字、无 markdown/列表/链接）+ 一句"无法控制设备，遇设备控制请求提示切到智能体模式"。
6. **切换在下一轮生效**，不打断在途轮次；离线前缀命令（如 `scene:`）在两种模式下都保持生效（与是否走 LLM 无关）。

## Considered Options

- **Lua 直连 LLM**：被否——无流式 HTTP 读，丢 SSE，首字反而更晚。
- **文本前缀传模式**（如 `llm:`）：被否——污染注入文本，且与 `local_scene` 的 prefix 规则语义冲突。
- **给 router 注入 `app_config` 依赖、C 侧直读模式**：被否——跨层依赖，且每请求多一次配置读取。

## Consequences

- 需新增一个 `CLAW_CORE_REQUEST_FLAG_*` 位，并在 context/tools/persist 三处加门控。
- 现有按 `chat_id=="voice"` 的判断（voice 的 ≤80 字提示、`voice_reply_run_script` 规则）需放宽为“属于 {voice, voice_llm}”。
- 先做一次逐跳延迟插桩，用数据验证该开关的收益，再决定是否调整优先级。
