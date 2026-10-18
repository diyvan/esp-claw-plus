-- 语音流式回复桥: C 侧写入的 LLM 增量文本 -> 可逐句取用的消费者。
--
-- C 侧 (claw_core_agent_loop.c) 在 voice 轮次把 LLM 流式增量追加到 /fatfs/voice_stream.txt,
-- 生成结束时写入结束哨兵 STREAM_END_MARKER。本模块把这套文件桥约定 (文件名、哨兵、整读 +
-- 差分、按标点切句) 收敛为唯一 owner: 消费方只需拿到一个 consumer, 循环 next() 取句、用
-- finished() 判断是否播完, 不必各自复制一份一模一样的读文件/切句代码。
--
-- 原实现里 voice_ptt.lua (播报) 与 voice_e2e.lua (自测) 各有一份逐字相同的拷贝, 加一种
-- 断句规则或改一次哨兵就得改两处, 自测还可能悄悄与真机行为走偏 —— 这正是本模块要消除的
-- 重复。读源 (read) 可注入, 便于测试喂入合成增量而不必真的起一个后端。
--
-- 用法:
--   local vstream = require("voice_stream")
--   vstream.reset(storage.get_root_dir())           -- 每轮开始前清上一轮残留
--   local c = vstream.consumer({ root_dir = storage.get_root_dir() })
--   while true do
--       local s = c:next()                           -- 取一句, 无可取返回 nil
--       if not s then break end
--       ...合成/播放...
--   end
--   if c:finished() then ... 本轮流已彻底读完 ... end
--
-- 计时与首句延迟上限: consumer 可传 on_first_sentence(sentence, latency_ms)(首句产出时回调
-- 一次, latency 为距建 consumer 的毫秒)与 first_sentence_ms(默认 600): 首句迟迟凑不到标点时
-- 强制软切(优先软标点, 否则整段), 压首句 TTS 延迟; 传 0 关闭。时钟经 opts.now 注入
-- (缺省 system.millis()), 便于测试。
--
-- 调用方与模块同目录 (/system/skills/voice/scripts), 而 package.path 首位就是脚本自身
-- 目录, 故 require("voice_stream") 直接命中, 无需改 package.path。

local storage = require("storage")
local system = require("system")

-- C 侧写入 /fatfs/voice_stream.txt, 结束追加哨兵；见 claw_core_agent_loop.c。
local STREAM_FILE = "voice_stream.txt"
local STREAM_END_MARKER = "\1\1" .. "END" .. "\1\1"

-- 切句参数: 无强标点时超过此长度即在软标点处切句, 限制首句延迟 (长度按 UTF-8 字节计)。
local SOFT_SPLIT_MAX = 40
-- 首句延迟上限: 第一句超过此时长仍无任何终止符即强制软切 (仅首句一次)。
local FIRST_SENTENCE_MAX_MS = 600
-- 终止符按"字面量整串"匹配 (plain find), 以便中文多字节标点 (如 "。") 整体命中。
-- 早先实现逐字节比较 (buf:sub(i,i) == "。"), 多字节标点被拆成孤立字节, 永远匹配不上,
-- 导致中文回复完全不按标点断句 (只能靠首句上限强切或收尾 flush)。
local STRONG_TERM = { "。", "！", "？", "!", "?", "；", ";", "\n" }  -- 强终止符: 命中立即断句
local SOFT_TERM = { "，", ",", "、", "：", ":" }                    -- 软终止符: 仅超长兜底处断句

local M = {}

-- 找 buf 中最早的强终止符, 返回 (起始字节位置, 长度); 未命中返回 nil。
local function first_strong(buf)
    local pos, len
    for _, ch in ipairs(STRONG_TERM) do
        local i = buf:find(ch, 1, true)
        if i and (not pos or i < pos) then
            pos, len = i, #ch
        end
    end
    return pos, len
end

-- 找 buf 中最晚的软终止符, 返回 (起始字节位置, 长度); 未命中返回 nil。
local function last_soft(buf)
    local pos, len
    for _, ch in ipairs(SOFT_TERM) do
        local from = 1
        while true do
            local i = buf:find(ch, from, true)
            if not i then
                break
            end
            if not pos or i > pos then
                pos, len = i, #ch
            end
            from = i + #ch
        end
    end
    return pos, len
end

-- 从缓冲取一句: 优先强终止符; 无强标点且已很长时在最后一个软标点处切; flush 时返回全部。
local function cut(buf, flush)
    if buf == "" then
        return nil, buf
    end
    local p, plen = first_strong(buf)
    if p then
        return buf:sub(1, p + plen - 1), buf:sub(p + plen)
    end
    if #buf >= SOFT_SPLIT_MAX then
        local q, qlen = last_soft(buf)
        if q then
            return buf:sub(1, q + qlen - 1), buf:sub(q + qlen)
        end
    end
    if flush then
        return buf, ""
    end
    return nil, buf
end

-- 强制软切 (首句延迟上限触发): 优先最后一个软标点, 没有则整段切出。
local function force_cut(buf)
    local q, qlen = last_soft(buf)
    if q then
        return buf:sub(1, q + qlen - 1), buf:sub(q + qlen)
    end
    return buf, ""
end

-- 默认读源: 读整份流式文件, 返回 (可见文本, 是否已结束)。文本不含结束标记; 只出现控制
-- 字节 \1\1 也视为未写完的标记, 一并剔除。导出为 M.file_read, 供 (如 voice_e2e) 包一层
-- 观测计时后注入。
local function file_read(root_dir)
    local path = storage.join_path(root_dir, STREAM_FILE)
    if not storage.exists(path) then
        return "", false
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" then
        return "", false
    end
    local p = content:find("\1\1", 1, true)
    if p then
        local tail = content:sub(p, p + #STREAM_END_MARKER - 1)
        return content:sub(1, p - 1), tail == STREAM_END_MARKER
    end
    return content, false
end

M.file_read = file_read

-- 清掉上一轮流文件 (否则会读到上一轮残留)。每轮注入前由调用方调用。
function M.reset(root_dir)
    return pcall(storage.remove, storage.join_path(root_dir, STREAM_FILE))
end

-- 有状态消费者: 记住已读到的字节数 (consumed) 与切剩的缓冲 (buf), 增量喂给切句器。
local Consumer = {}
Consumer.__index = Consumer

-- 取下一句; 当前流里已无完整句子时返回 nil。每次调用至多读一次文件。
function Consumer:next()
    if #self.queue == 0 then
        if self.ended then
            return nil
        end
        local text, ended = self.read()
        if #text > self.consumed then
            if not self.first_byte_at then
                self.first_byte_at = self.now()
            end
            self.buf = self.buf .. text:sub(self.consumed + 1)
            self.consumed = #text
        end
        if ended then
            self.ended = true
        end
        local sentence
        repeat
            sentence, self.buf = cut(self.buf, self.ended)
            if sentence then
                self.queue[#self.queue + 1] = sentence
            end
        until not sentence
        -- 首句延迟上限: 第一句超过 first_sentence_ms 仍无终止符 -> 强制软切 (仅首句一次)。
        if not self.ended and not self.first_done and #self.queue == 0
                and self.buf ~= "" and self.first_byte_at and self.first_sentence_ms > 0
                and self.now() - self.first_byte_at >= self.first_sentence_ms then
            sentence, self.buf = force_cut(self.buf)
            self.queue[#self.queue + 1] = sentence
        end
    end
    local s = table.remove(self.queue, 1)
    if s and not self.first_done then
        self.first_done = true
        self.first_latency_ms = self.now() - self.t0
        if self.on_first_sentence then
            pcall(self.on_first_sentence, s, self.first_latency_ms)
        end
    end
    return s
end

-- 是否已彻底读完: 哨兵已到且没有句子还留在手上。
function Consumer:finished()
    return self.ended and #self.queue == 0
end

-- 建一个消费者。opts = {
--   root_dir           = <存储根目录>,
--   read               = <自定义读源 fn() -> text, ended>,
--   now                = <时钟 fn() -> ms>,            缺省 system.millis()
--   on_first_sentence  = <fn(sentence, latency_ms)>,   首句产出时回调一次
--   first_sentence_ms  = <首句延迟上限 ms>,            缺省 600, 传 0 关闭
-- }
-- read 缺省时用 file_read(root_dir); 注入 read 时 root_dir 仅用于缺省读源, 可省略。
function M.consumer(opts)
    opts = opts or {}
    local root_dir = opts.root_dir or storage.get_root_dir()
    local now = opts.now or function() return system.millis() end
    return setmetatable({
        read = opts.read or function() return file_read(root_dir) end,
        now = now,
        t0 = now(),
        first_sentence_ms = opts.first_sentence_ms or FIRST_SENTENCE_MAX_MS,
        on_first_sentence = opts.on_first_sentence,
        first_byte_at = nil,
        first_done = false,
        first_latency_ms = nil,
        buf = "",
        consumed = 0,
        queue = {},
        ended = false,
    }, Consumer)
end

return M
