# 轮次闸门归 `voice_round`、播放收敛归 `voice_playback`（两个 Lua owner）

状态：accepted

## Context

语音链路里有两个各跑各的脚本：`voice_ptt.lua`（常驻的 PTT/唤醒循环，输入侧）与 `voice_reply.lua`（由路由规则按条触发，回复侧）。二者是**独立任务**，不共享 Lua 状态，因此存在两处结构性缺陷：

1. **轮次相位分散、回复侧无轮次感知**。`voice_ptt.lua` 有自己的局部 `state`（输入侧相位）；`voice_reply.lua` 完全没有「这是哪一轮」的概念，只能靠 `/fatfs/voice_status.txt` 的状态码比较（`voice_ptt` 的定时回收里用「面板上还是不是我写的 code」做 guard）与一个「存在即打断」的 `/fatfs/voice_interrupt` 标志来弱协调。后果：一轮回复的 TTS 合成/播放可能在用户已经发起下一轮录音之后才发生——既插播过期语音，也是「播放中再录音」问题的一部分成因。
2. **播放实现重复两份**。`voice_ptt.lua` 的逐句流水线（`reply_wait`）与 `voice_reply.lua` 的整段回退路径各自复制了一份逐字相同的播放代码：取板级 DAC 参数、开 output、建 player、流式会话（`play_stream` / `play_stream_append` / `play_stream_finish`）、落盘 `play(path)`、`poll` 收尾、barge-in 时 `stop`、`close` 释放。任一处打补丁都容易只改一边、另一边漏掉。

设备级所有权（谁真正持有扬声器、录音到来时如何撤销正在写的 writer）与采集 48k 不变量已由 C 层 `ha_voice_arbiter` 承接，见 `docs/adr/0003-audio-device-owner.md`。本 ADR 处理的是**调用方 Lua 侧**的对应收敛。

## Decision

1. **新增 `voice_round.lua` 作为「轮次闸门」的唯一 owner**：每次用户开始说话（PTT 按下 / 唤醒）由 `voice_ptt.lua` 调 `round.begin()`，递增一个单调轮次号并落盘 `/fatfs/voice_round`。异步回复脚本在进入时用 `round.id()` 记下自己的轮次号，起播前与播放中用 `round.is_current(rid)` 判断是否已被新一轮取代——过期即不起播 / 停播。
   - 把「归属」从隐式的状态码字符串比较，变成显式的轮次身份比较；不依赖标志文件是否被及时清掉。
   - 相位（`recording` / `thinking` / `speaking` …）仍由 `voice_status.txt` 承载，其唯一写入 owner 仍是 `voice_common`；`voice_round` 只管「轮次身份」，不重复管相位。
2. **新增 `voice_playback.lua` 作为「播放 owner」的唯一实现**：`playback.open(cfg)` 取板级 DAC 参数开输出（player 惰性创建），对外提供 `play_stream` / `play_stream_append` / `play_stream_finish` / `play_file` / `poll` / `stop` / `close` / `stream_active` / `idle`。`voice_ptt.lua` 与 `voice_reply.lua` 都改调它，删除各自的播放拷贝。
3. **保留 `voice_interrupt` 标志信道**：它是「立即停音」的边沿信号（`voice_ptt` 一按下就写、`voice_reply` 每 20ms 轮询即 `stop`），与轮次闸门的「语义归属 / 过期判定」互补，二者不互相替代。

## Considered Options

- **只保留 `voice_interrupt`，不引入轮次号**：被否——标志是「瞬时边沿」，存在「写早了、清早了、被覆盖」的竞态窗口，无法表达「这轮是否已被取代」这一持续语义。
- **把轮次相位也塞进 `voice_round`（连 `voice_status` 一并接管）**：被否——会与 `voice_common` 的屏幕桥 owner 重叠，且面板按 code 查表已稳定，无收益。
- **把播放 owner 放进 `voice_common`**（复用已有共享模块）：被否——`voice_common` 的职责是 `/fatfs` 文本桥，混入音频设备/player 生命周期会让两个概念耦合；单独模块更清晰、`deletion test` 更干净。
- **把轮次号写进 `voice_status.txt`（复用同一文件）**：被否——会改变 C 侧 `ha_panel.c` 的 `"<code>|<detail>"` 解析契约，需要改 C 并重新烧录面板代码，代价大于收益（单独一个小文件即可）。

## Consequences

- 新增两个 overlay 文件（`app/.../skills/voice/scripts/voice_round.lua`、`voice_playback.lua`），构建时随 `fatfs_image/system/` 一并打包进 `system` 分区；**无需补丁、无需改动 C 侧**。
- `voice_ptt.lua`：`reply_wait` 字段由 `player` / `output` / `stream_started` 收敛为单一 `pb`；`start_recording()` 里新增 `round.begin()`。
- `voice_reply.lua`：删除本地的 `audio` / `board_manager` 依赖，播放统一走 `voice_playback`；新增轮次号记取与 `superseded()` 闸门（合成前 / 起播前 / 播放中各查一次）。
- 行为等价性以「起播时机 + 停播时机」为准：正常轮次与原来一致；新增的只是「已被新一轮取代时不起播/停播」这一更强保证。
- 两个 owner 的说法以 `SKILL.md`、`CONTEXT.md` 为准；本 ADR 与 `0003` 共同描述 C 侧 + Lua 侧的完整收敛。
