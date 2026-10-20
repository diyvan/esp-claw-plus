-- 轮次闸门 (round gate): 跨脚本的「这是哪一轮对话」唯一 owner。
--
-- 问题: 语音链路里有两个各跑各的脚本 —— voice_ptt.lua (常驻, 输入侧) 与 voice_reply.lua
-- (由路由规则按条触发, 回复侧)。voice_ptt 自己有局部 state, voice_reply 完全没有轮次概念,
-- 两者只能靠 /fatfs 里"当前状态码是不是我写的"这种弱比较 (voice_common 的 code-guard) 与
-- 一个"存在即打断"的标志文件 (voice_interrupt) 来协调。后果是: 一轮回复的合成/播放可能
-- 在用户已经发起下一轮录音之后才发生 —— 既会插入过期的语音, 也是「播放中再录音」问题的
-- 一部分成因。
--
-- 本模块给每一轮"用户开始说话"分配一个单调递增的轮次号, 落盘到 /fatfs/voice_round, 作为
-- 跨脚本的归属标记。异步回复脚本在进入时记下自己的轮次号, 播放期间据此判断自己是否已被
-- 新一轮取代 (is_current), 过期即自行放弃。这样"归属"从隐式的状态码比较, 变成显式的轮次
-- 身份比较, 是这些脚本之间协调的唯一真源。
--
-- 与其它 owner 的分工:
--   * 设备所有权 (谁持有麦克风/扬声器, 录音到来时如何撤销) 在 C 层 ha_voice_arbiter
--     (见 docs/adr/0003-audio-device-owner.md)。
--   * 播放收敛 (唯一播放 owner) 在 voice_playback.lua。
--   * 相位 (recording/thinking/speaking...) 仍由 voice_status.txt 承载, 其唯一写入 owner
--     是 voice_common.lua; 本模块只管「轮次身份」, 不重复管相位。
-- 见 docs/adr/0004-voice-round-and-playback-owner.md。
--
-- 用法:
--   local round = require("voice_round")
--   local rid = round.begin()        -- 开始一轮 (用户开始说话时调一次)
--   ...
--   if not round.is_current(rid) then ... end   -- 回复侧判自己是否已过期
--
-- 调用方与模块同目录 (/system/skills/voice/scripts), package.path 首位即脚本自身目录, 故
-- require("voice_round") 直接命中, 无需改 package.path。

local storage = require("storage")

local TAG = "[voice_round]"
local ROUND_FILE = "voice_round"   -- 内容为十进制轮次号

local M = {}

local function round_path()
    local ok, root = pcall(storage.get_root_dir)
    if not ok or type(root) ~= "string" or root == "" then
        return nil
    end
    return storage.join_path(root, ROUND_FILE)
end

-- 读当前轮次号。无文件 / 读失败 / 内容损坏一律视为 0 (尚未开始任何一轮)。
function M.id()
    local path = round_path()
    if not path or not storage.exists(path) then
        return 0
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" then
        return 0
    end
    return tonumber(content:match("^%s*(%d+)")) or 0
end

-- 开始新一轮: 轮次号 +1 并落盘, 返回新号。
-- 语义: 每次「用户开始说话」(BOOT 按下录音 / 唤醒词触发自动录音) 都开一轮。轮次号是跨脚本
-- 的归属标记 —— 递增即意味着此前所有在途的回复都过期了。
function M.begin()
    local next_id = M.id() + 1
    local path = round_path()
    if path then
        local ok, err = pcall(storage.write_file, path, tostring(next_id))
        if not ok then
            print(TAG .. " write round failed: " .. tostring(err))
        end
    end
    return next_id
end

-- 给定轮次号是否仍是当前轮。返回 false 表示该轮已被更新的录音轮次取代, 调用方应放弃。
function M.is_current(id)
    if type(id) ~= "number" then
        return false
    end
    return id == M.id()
end

return M
