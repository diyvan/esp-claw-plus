---
{
  "name": "ha_control",
  "description": "Control Home Assistant (and the Mi Home / Xiaomi devices behind it) through the Home Assistant MCP Server. Only reachable when the runtime config has ha_enabled=true; when it is off these scripts refuse to contact Home Assistant and you must answer with ESP-Claw's own abilities instead.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly"
  }
}
---

# HA Control (Home Assistant via MCP)

本技能把 ESP-Claw 的 Agent 接到 Home Assistant 的 **MCP Server**：先用
`mcp_list_tools` 发现 HA 侧暴露的工具，再用 `mcp_call_tool` 调用来开关灯、调亮度、
温控、触发场景等。米家设备由 HA 侧的米家集成接入，ESP-Claw 只经 HA 中转。

## 何时使用

- 只有当**运行时配置** `ha_enabled=true` 时才应调用本技能；
  关闭时脚本会直接返回提示，不会触达 Home Assistant。
- 语音/IM 的请求**始终先到 ESP-Claw Agent**。由 LLM 判断这条意图是否需要 Home Assistant：
  需要（控制设备/查状态/跑场景）才调用本技能，否则用 ESP-Claw 自身能力直接应答。

## 脚本

LLM 直接用 `lua_run_script` 调用（`{CUR_SKILL_DIR}` 会被展开为绝对路径）：

- `{CUR_SKILL_DIR}/scripts/ha_list_tools.lua` — 列出 HA MCP Server 暴露的工具（无参数）。
  先调用它了解 HA 侧有哪些可用工具及其参数，再决定调用哪一个。
- `{CUR_SKILL_DIR}/scripts/ha_call.lua` — 调用一个 HA MCP 工具。参数（`args` 对象）：
  - `tool_name`（字符串，必填）— 要调用的 HA MCP 工具名（来自 `ha_list_tools.lua`）。
  - `arguments`（对象，可选）— 该工具的参数，键名与 `ha_list_tools.lua` 返回的 schema 一致。

示例（LLM 生成的调用）：

```json
{"path": "{CUR_SKILL_DIR}/scripts/ha_call.lua",
 "args": {"tool_name": "HassTurnOn", "arguments": {"name": "客厅灯"}}}
```

## 连接与认证（设备侧，自动处理）

两个脚本都从**运行时配置** `/fatfs/ha_voice_runtime.json` 读取连接信息，无需 LLM 提供：

| 字段 | 用途 |
| --- | --- |
| `ha_enabled` | 总开关；`false` 时脚本直接返回，不触达 HA |
| `ha_base_url` | HA 地址，如 `http://homeassistant.local:8123`；若带上路径（如 `.../mcp_server`）则该路径作为 MCP 端点 |
| `ha_token` | HA 长期访问令牌，作为 `Authorization: Bearer <token>` 附带 |

这些字段由 ESP-Claw 网页配置页维护（`app_config` → `ha_panel_publish_runtime_config()`
写出上述 JSON），改完即存即用。令牌只留在设备侧（Lua 读文件后直接传给 `mcp_call_tool`
的 `bearer_token`），**不进入 LLM 上下文**。

## 依赖的 Lua 模块 / 能力

`capability`（调 `mcp_list_tools` / `mcp_call_tool`）、`storage`、`json`。

> 说明：`mcp_list_tools` / `mcp_call_tool` 由 `cap_mcp_client` 提供，脚本经 Lua
> `capability.call` 调用（调用方为 SYSTEM，不受 LLM 可见性组限制）。
> **本技能刻意不把 `cap_mcp_client` 声明进 `cap_groups`**——否则这些 MCP 工具会直接暴露给
> LLM，LLM 就能绕开 `ha_enabled` 门控自己直连 HA。让 LLM 只经过本技能的两个脚本，
> 门控才唯一、有效。
> MCP 客户端对 HA 的地址处理：`server_url` 只保留 `scheme://host:port`，路径部分
> 由 `endpoint` 承载（默认取 `ha_base_url` 的路径，缺省为 `mcp_server`）。
