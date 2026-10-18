-- voice_stream 模块自测 (设备侧, 经串口 REPL 运行)
--
-- 运行: lua --run --path /system/voicetest/voice_stream_test.lua
--
-- 覆盖 voice_stream 的文件桥契约: 整读差分 (不重复喂字符)、按标点切句、结束时 flush 残余尾句、
-- 哨兵 (\1\1END\1\1) 剥离、finished() 判定; 以及 C4 计时/首句上限: on_first_sentence 回调、
-- first_latency_ms、first_sentence_ms(默认 600) 无标点强制软切与 0 关闭。前四组用注入的
-- 合成读源 (不依赖后端), 第五组落真实 /fatfs/voice_stream.txt 走默认读源, 6-8 组用注入时钟。
--
-- 输出: 每条断言 PASS/FAIL, 结尾 RESULT=OK|FAIL cases=<n> pass=<n> fail=<n>。

package.path = package.path
    .. ";/system/skills/voice/scripts/?.lua"
    .. ";/system/skills/voice/scripts/?/init.lua"

local storage = require("storage")
local vstream = require("voice_stream")

local TAG = "[voice_stream_test]"
local MARKER = "\1\1" .. "END" .. "\1\1"
local STREAM_FILE = "voice_stream.txt"

local pass, fail = 0, 0

local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        print(TAG .. " PASS " .. name)
    else
        fail = fail + 1
        print(string.format("%s FAIL %s %s", TAG, name, detail or ""))
    end
end

local function eq_list(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function join(a)
    return table.concat(a, "|")
end

-- 注入读源: 依次返回 events[i] = { text, ended }; 用尽后重复最后一项 (模拟文件不再增长)。
local function feeder(events)
    local i = 0
    return function()
        if i < #events then
            i = i + 1
        end
        local e = events[i]
        return e[1], e[2]
    end
end

-- 按"轮询轮次"取句, 与真实调用方 (voice_ptt 的等待态主循环: 每轮先榨干可取句子, 再睡片刻)
-- 一致: 每轮把当前可取句子全部取出, 未结束则进入下一轮, 最多 rounds 轮。
local function collect(c, rounds)
    local got = {}
    for _ = 1, (rounds or 50) do
        while true do
            local s = c:next()
            if not s then
                break
            end
            got[#got + 1] = s
        end
        if c:finished() then
            break
        end
    end
    return got
end

local function run_case(name, events, expected, expect_finished)
    local c = vstream.consumer({ read = feeder(events) })
    local got = collect(c)
    check(name .. ".sentences", eq_list(got, expected),
        "got=" .. join(got) .. " want=" .. join(expected))
    if expect_finished ~= nil then
        check(name .. ".finished", c:finished() == expect_finished,
            "finished=" .. tostring(c:finished()))
    end
end

-- 1. 增量差分 + 强终止符即时断句 + 多句顺序 (读源每次返回"累计可见文本")。
run_case("incremental_strong", {
    { "Hi!", false },
    { "Hi!How", false },
    { "Hi!How are you?", false },
    { "Hi!How are you?Bye!", true },
}, { "Hi!", "How are you?", "Bye!" }, true)

-- 2. 无强标点但超过 40 字节 -> 在最后一个软标点处切句; 结束时的残余同样 flush。
local long_soft = string.rep("a", 40) .. ",more"
run_case("soft_split", { { long_soft, true } },
    { string.rep("a", 40) .. ",", "more" }, true)

-- 3. 结束时 flush 残余 (整段无标点)。
run_case("flush_tail", { { "hello world", true } }, { "hello world" }, true)

-- 4. 未结束且凑不出完整句 -> 不产出, 也未完成。
run_case("pending", { { "a,b", false } }, {}, false)

-- 5. 真实文件桥: 落 voice_stream.txt + 哨兵, 走默认读源; 并验证 reset 清理与无哨兵未结束。
do
    local root = storage.get_root_dir()
    local path = storage.join_path(root, STREAM_FILE)

    vstream.reset(root)
    check("file_bridge.reset_removes", not storage.exists(path))

    pcall(storage.write_file, path, "OK!Done!" .. MARKER)
    local c = vstream.consumer({ root_dir = root })
    local got = collect(c)
    check("file_bridge.sentences", eq_list(got, { "OK!", "Done!" }), "got=" .. join(got))
    check("file_bridge.finished", c:finished(), "finished=" .. tostring(c:finished()))

    pcall(storage.write_file, path, "no marker yet")
    local c2 = vstream.consumer({ root_dir = root })
    local got2 = collect(c2, 3)
    check("file_bridge.no_marker", #got2 == 0 and not c2:finished(),
        "got=" .. join(got2) .. " finished=" .. tostring(c2:finished()))

    vstream.reset(root)
end

-- 6. 首句计时: 注入时钟 (+100ms/次), on_first_sentence 与 first_latency_ms 首句时各产生一次。
do
    local clock = 0
    local function step()
        clock = clock + 100
        return clock
    end
    local cb_calls, cb_sentence, cb_ms = 0, nil, nil
    local c = vstream.consumer({
        read = feeder({ { "Hello wor", false }, { "Hello world!", false },
                         { "Hello world!Again.", true } }),
        now = step,
        on_first_sentence = function(s, ms)
            cb_calls = cb_calls + 1
            cb_sentence = s
            cb_ms = ms
        end,
    })
    local got = collect(c)
    check("first_latency.sentences", eq_list(got, { "Hello world!", "Again." }),
        "got=" .. join(got))
    check("first_latency.value", c.first_latency_ms == 300,
        "first_latency_ms=" .. tostring(c.first_latency_ms))
    check("first_latency.callback",
        cb_calls == 1 and cb_sentence == "Hello world!" and cb_ms == 300,
        string.format("calls=%d sentence=%s ms=%s",
            cb_calls, tostring(cb_sentence), tostring(cb_ms)))
end

-- 7. 首句延迟上限: 全程无终止符且超过 first_sentence_ms(默认 600) -> 强制软切整段, 仅首句。
do
    local clock = 0
    local function step()
        clock = clock + 100
        return clock
    end
    local c = vstream.consumer({ read = feeder({ { "abcdef", false } }), now = step })
    local got = collect(c, 20)
    check("cap_force_cut.sentences", eq_list(got, { "abcdef" }), "got=" .. join(got))
    check("cap_force_cut.latency",
        c.first_latency_ms ~= nil and c.first_latency_ms >= 600,
        "first_latency_ms=" .. tostring(c.first_latency_ms))
    check("cap_force_cut.not_finished", not c:finished(),
        "finished=" .. tostring(c:finished()))
end

-- 8. first_sentence_ms = 0 关闭上限: 时钟飞进也不强制切, 未结束前不产出任何句子。
do
    local clock = 0
    local function step()
        clock = clock + 10000
        return clock
    end
    local c = vstream.consumer({
        read = feeder({ { "abcdef", false } }), now = step, first_sentence_ms = 0 })
    local got = collect(c, 10)
    check("cap_disabled.pending", #got == 0, "got=" .. join(got))
    check("cap_disabled.not_finished", not c:finished(),
        "finished=" .. tostring(c:finished()))
end

-- 9. 中文多字节标点 (UTF-8 3 字节): 强终止符 "。" / "？" 立即断句 (回归: 旧实现逐字节比较
--    匹配不上多字节标点, 中文回复完全不按标点断句)。
run_case("cjk_strong", {
    { "你好。", false },
    { "你好。今天天气不错？", true },
}, { "你好。", "今天天气不错？" }, true)

-- 10. 中文软标点超长兜底: 无强标点但超过 40 字节 -> 在最后一个 "，" 处切句。
local long_cjk = string.rep("啊", 20) .. "，" .. "然后呢"   -- 20*3=60 字节 > 40
run_case("cjk_soft", { { long_cjk, true } },
    { string.rep("啊", 20) .. "，", "然后呢" }, true)

print(string.format("%s RESULT=%s cases=%d pass=%d fail=%d",
    TAG, (fail == 0) and "OK" or "FAIL", pass + fail, pass, fail))
