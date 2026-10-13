---
{
  "name": "local_scene",
  "description": "Offline, deterministic local scenes for this board. Sets a local scene (home / away / night) and persists it to /fatfs so it survives reboots and keeps working when the router or Home Assistant is unreachable.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly"
  }
}
---

# Local Scene (offline automation)

本技能是 **断网可用的确定性本地联动**：不依赖 LLM、不依赖 Home Assistant，只读写本地
状态文件并写屏。路由器/网络断开时，路由规则触发的场景脚本照常执行。

## 脚本

- `{CUR_SKILL_DIR}/scripts/local_scene.lua` — 设置并持久化本地场景。参数（`args` 对象）：
  - `scene`（字符串，可选）— `home` / `away` / `night` / `boot`；缺省时读取当前状态。

## 路由规则（离线联动入口）

本技能靠两条路由规则触发（`/fatfs/router_rules/router_rules.json`，源见
`solutions/ha_ai_panel/app/router_rules/local_rules.json`）：

1. `startup_local_scene` — 开机（`event_type=startup` / `event_key=boot_completed`）时
   执行 `local_scene.lua`，参数 `scene=boot`：读回上次场景，若本地状态缺失则初始化为
   `home`。**全程离线**，无需网络。
2. `local_scene_command` — 文本命令（`scene:home` / `scene:away` / `scene:night`）时执行
   `local_scene.lua`，参数 `scene={{match.remainder}}`；`consume_on_match=true`，因此该
   命令**不会**再进入 LLM，由 Lua 本地确定性处理（断网可用）。可用串口 REPL 离线自测：

   ```
   event_router --emit-message --source-cap cli --channel local --chat-id local --text "scene:away"
   ```

## 本地状态与可见性

| 文件 | 内容 |
| --- | --- |
| `/fatfs/local_scene_state.json` | 权威场景状态（`scene` / `updated_ms` / `source`），供其他规则/脚本读取 |
| `/fatfs/local_scene.txt` | 便于设备端界面显示的纯文本（如 `场景: 回家`） |

> `/system` 只读，运行时状态一律落 `/fatfs`。真实部署可在此脚本内把场景进一步映射到本板
> 硬件（GPIO/继电器/指示灯等），保持同一套路由规则不变。
