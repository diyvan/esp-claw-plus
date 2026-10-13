-- 语音脚本共享模块: 状态码桥 + 会话记录桥 + 运行时配置桥 + 打断信道。
--
-- 这些 /fatfs 约定原先在 voice_ptt.lua 与 voice_reply.lua 里各有一份逐字相同的拷贝,
-- 加一个字段要改多处, 两条回复路径 (流式 / 整段回退) 容易走偏 —— 例如 voice_agent.txt
-- 曾只有 voice_reply.lua 写, 而流式轮次下 C 侧不再发布 out_message
-- (claw_core_agent_loop.c 在 stream_sink.emitted 时跳过发布), 于是一问一答之后面板
-- 「AI 说」永远不更新。本模块是这些 /fatfs 约定的唯一 owner: 新增任何写入方只需
-- require 本模块。
--
-- 屏幕桥两个文件 (C 侧 ha_panel.c 每 200ms 轮询并镜像到 LVGL):
--   voice_status.txt  状态: "<code>|<detail>"  (code 见下, detail 为可选补充文本)
--   voice_log.txt     会话记录: 每条 "<role>\31<text>\30", role 为 U(用户)/ A(助手)
-- 状态用机器可读的 code 而非中文串, 面板按 code 查表得到中文与"是否忙", 这样改文案不会
-- 悄悄让面板的点灯判定失联。
--
-- 调用方与模块同目录 (/system/skills/voice/scripts), 而 package.path 首位就是脚本自身
-- 目录, 故 require("voice_common") 直接命中, 无需改 package.path。

local storage = require("storage")
local json = require("json")
local system = require("system")

local TAG = "[voice_common]"

-- 屏幕桥字段 (C 侧 ha_panel.c 轮询 /fatfs/voice_*.txt 并镜像到 LVGL 标签)。
local STATUS_FILE = "voice_status.txt"
local LOG_FILE = "voice_log.txt"

-- 会话记录的分隔符: 记录之间用 RS(\30), role 与正文之间用 US(\31)。正文里不会出现这两个
-- 控制字符 (LLM 输出), 因此无需转义。
local RECORD_SEP = "\30"
local FIELD_SEP = "\31"
-- 面板只渲染最近若干条, 这里同步裁剪, 避免文件与面板内存无限增长。
local MAX_LOG_RECORDS = 8

-- 运行时配置桥: C 侧 ha_panel.c 写 /fatfs/ha_voice_runtime.json, 脚本读。
local RUNTIME_CONFIG = "ha_voice_runtime.json"

-- 语音打断 (barge-in): 音频没有全局仲裁器, 跨脚本只能用 /fatfs 空标志文件通知正在播放的脚本。
local INTERRUPT_FLAG = "voice_interrupt"

local M = {}

local function data_path(name)
    local ok, root = pcall(storage.get_root_dir)
    if not ok or type(root) ~= "string" or root == "" then
        return nil
    end
    return storage.join_path(root, name)
end

-- 写一个屏幕桥字段。先写 <name>.tmp 再改名覆盖, 而不是直接截断写:
-- 面板若恰好落在"目标已删、改名前"的窗口里, 读到的是文件不存在 -> ha_panel_read_text 返回
-- false -> 跳过本次刷新, 保留上一帧文本; 而截断写会让面板读到空文件, 把内容闪成空。
-- FatFs 的 f_rename 在目标已存在时返回 FR_EXIST, 所以必须先删目标再改名。
local function write_bridge(name, content)
    local path = data_path(name)
    if not path then
        return false
    end
    local tmp = path .. ".tmp"
    local wrote, werr = pcall(storage.write_file, tmp, content)
    if not wrote then
        print(TAG .. " write " .. name .. " failed: " .. tostring(werr))
        return false
    end
    if storage.exists(path) then
        pcall(storage.remove, path)
    end
    local moved, merr = pcall(storage.rename, tmp, path)
    if not moved then
        -- 退路: 直接截断写。非原子, 但保证内容一定能上屏。
        pcall(storage.remove, tmp)
        local ok2, err2 = pcall(storage.write_file, path, content)
        if not ok2 then
            print(TAG .. " write " .. name .. " failed: " .. tostring(err2))
            return false
        end
        print(TAG .. " rename " .. name .. " failed (" .. tostring(merr) .. "), wrote directly")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 状态码桥
-- ---------------------------------------------------------------------------
-- code 是固定枚举 (SKILL.md「状态码」一节), detail 是可选的补充文本 (如 "录音太短 320ms"
-- 里的 "录音太短 320ms"、火山 ASR 返回的短消息)。面板按 code 决定中文文案与忙碌指示灯,
-- 与这里的自由文本解耦。

function M.set_status(code, detail)
    if detail == nil then
        detail = ""
    end
    return write_bridge(STATUS_FILE, code .. "|" .. detail)
end

-- 读回当前状态码 (只取 '|' 前段)。voice_ptt 的定时回收靠它判断"面板上是不是还是我写的状态"。
function M.read_status_code()
    local path = data_path(STATUS_FILE)
    if not path or not storage.exists(path) then
        return nil
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" then
        return nil
    end
    local bar = content:find("|", 1, true)
    if bar then
        return content:sub(1, bar - 1)
    end
    return content
end

-- ---------------------------------------------------------------------------
-- 会话记录桥 (多轮历史)
-- ---------------------------------------------------------------------------
-- 面板把记录渲染成可滚动的气泡列表。写入方只描述"这一条是什么", 不关心面板布局。

local function parse_log(content)
    local records = {}
    local i = 1
    while i <= #content do
        local rp = content:find(RECORD_SEP, i, true)
        if not rp then
            break
        end
        local rec = content:sub(i, rp - 1)
        local fp = rec:find(FIELD_SEP, 1, true)
        if fp then
            records[#records + 1] = { role = rec:sub(1, fp - 1), text = rec:sub(fp + 1) }
        end
        i = rp + 1
    end
    return records
end

local function encode_log(records)
    local parts = {}
    for i = 1, #records do
        parts[i] = records[i].role .. FIELD_SEP .. records[i].text .. RECORD_SEP
    end
    return table.concat(parts)
end

local function read_log()
    local path = data_path(LOG_FILE)
    if not path or not storage.exists(path) then
        return {}
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" then
        return {}
    end
    return parse_log(content)
end

-- 只保留最近 MAX_LOG_RECORDS 条 (丢弃最旧)。
local function trim_log(records)
    while #records > MAX_LOG_RECORDS do
        table.remove(records, 1)
    end
    return records
end

-- 设置本轮用户文本 (ASR 结果)。流式 ASR 会随识别增量反复调用, 故"最后一条是 U 就覆盖它",
-- 否则追加一条新的 U。
function M.log_user(text)
    local records = read_log()
    local last = records[#records]
    if last and last.role == "U" then
        last.text = text or ""
    else
        records[#records + 1] = { role = "U", text = text or "" }
    end
    return write_bridge(LOG_FILE, encode_log(trim_log(records)))
end

-- 整段写入助手回复 (非流式回退路径 voice_reply.lua)。
function M.log_agent(text)
    local records = read_log()
    records[#records + 1] = { role = "A", text = text or "" }
    return write_bridge(LOG_FILE, encode_log(trim_log(records)))
end

-- 流式路径按句追加助手回复: 最后一条是 A 就追加到它 (同一轮), 否则新建一条 A (本轮首句)。
function M.log_agent_append(delta)
    if not delta or delta == "" then
        return true
    end
    local records = read_log()
    local last = records[#records]
    if last and last.role == "A" then
        last.text = last.text .. delta
    else
        records[#records + 1] = { role = "A", text = delta }
    end
    return write_bridge(LOG_FILE, encode_log(trim_log(records)))
end

-- 清空会话记录 (自测脚本用; 正常运行靠 MAX_LOG_RECORDS 裁剪, 不清历史)。
function M.clear_log()
    return write_bridge(LOG_FILE, "")
end

-- ---------------------------------------------------------------------------
-- 运行时配置桥
-- ---------------------------------------------------------------------------

-- 每次真读文件 (voice_reply 每轮执行一次, 必须拿到最新配置)。
function M.load_runtime_config()
    local path = data_path(RUNTIME_CONFIG)
    if not path or not storage.exists(path) then
        return {}
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        return {}
    end
    local decode_ok, data = pcall(json.decode, content)
    if not decode_ok or type(data) ~= "table" then
        print(TAG .. " runtime config decode failed")
        return {}
    end
    return data
end

-- 同上, 但带 1s 缓存 (voice_ptt 常驻循环每轮都要查 voice_enabled / voice_wake_enabled)。
local cfg_cache, cfg_at = {}, -100000

function M.runtime_config()
    local now = system.millis()
    if now - cfg_at >= 1000 then
        cfg_cache = M.load_runtime_config()
        cfg_at = now
    end
    return cfg_cache
end

-- ---------------------------------------------------------------------------
-- 打断信道
-- ---------------------------------------------------------------------------
-- 直接创建标志文件 (存在即打断), 不走 write_bridge —— 对标志文件来说"文件存在"才是信号,
-- 删目标再改名反而会制造一段"标志不存在"的假窗口。

function M.signal_interrupt()
    local path = data_path(INTERRUPT_FLAG)
    if path then
        pcall(storage.write_file, path, "")
    end
end

function M.clear_interrupt()
    local path = data_path(INTERRUPT_FLAG)
    if path and storage.exists(path) then
        pcall(storage.remove, path)
    end
end

function M.interrupt_requested()
    local path = data_path(INTERRUPT_FLAG)
    return path ~= nil and storage.exists(path)
end

return M
