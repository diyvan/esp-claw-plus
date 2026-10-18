-- 端到端语音链路离线回放自测 (优化② TTS 真·边收边播验证)
--
-- 用一段罐装录音驱动完整链路, 完全不依赖麦克风 / BOOT 键 / 唤醒词:
--   录音文件 -> 流式 ASR -> 注入 Agent(voice 渠道) -> LLM 流式增量落 voice_stream.txt
--   -> 按句切分 -> tts.stream_request + player:play_stream (HTTP 流式边收边解码边播放)
--
-- 运行 (串口 REPL):
--   lua --run --path /system/voicetest/voice_e2e.lua
--
-- 录音文件: /system/voicetest/asr_sample.wav (16kHz/mono/16bit, 内容「今天天气怎么样」)
-- 配置来源: /fatfs/ha_voice_runtime.json (网页「语音助手」页), 与 voice_ptt 同源。
--
-- 输出关键行:
--   ASR=OK text=<识别文本>                    识别成功
--   ASR=FAILED reason=<中文>                  识别失败
--   SENTENCE[<n>] text=<句子>                 切出待播句子
--   APPEND[<n>] at=<ms>                       该句追加进流式流水线的时刻 (首句即建立会话)
--   PLAY_END at=<ms>                          整段音频连续播完的时刻 (单条播放, 句间不重建)
--   RESULT=OK sentences=<n> first_play=<ms> play_end=<ms> total=<ms>
--   RESULT=<NO_REPLY|NO_TTS|PLAYER_FAILED|TIMEOUT|SAMPLE_MISSING|BAD_WAV|ASR_FAILED>
--
-- provider 位于 /system/skills/voice/scripts, 不在本脚本目录内, 故手动补 package.path。

package.path = package.path
    .. ";/system/skills/voice/scripts/?.lua"
    .. ";/system/skills/voice/scripts/?/init.lua"

local storage = require("storage")
local delay = require("delay")
local system = require("system")
local json = require("json")
local audio = require("audio")
local bm = require("board_manager")
local ep = require("event_publisher")
local tts = require("voice_tts")
local vc = require("voice_common")
local vstream = require("voice_stream")

local TAG = "[voice_e2e]"
local SAMPLE = "/system/voicetest/asr_sample.wav"
local CHUNK_MS = 60                 -- 与 voice_ptt 边录边发节奏一致
local ASR_FINISH_TIMEOUT_MS = 8000
local REPLY_TIMEOUT_MS = 180000     -- 注入 Agent 后等待/播报的总上限 (agent 模式常有多次 tool_call, 放宽)
local POLL_MS = 20

local VOICE_CHANNEL = "voice"
local VOICE_CHAT_ID = "voice"

-- 读取运行配置 (与 voice_ptt 同一来源, 保证测的就是真机实际用的那份配置)。
local function load_cfg()
    local path = storage.join_path(storage.get_root_dir(), "ha_voice_runtime.json")
    if not storage.exists(path) then
        return {}
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        return {}
    end
    local dok, data = pcall(json.decode, content)
    if not dok or type(data) ~= "table" then
        return {}
    end
    return data
end

-- 解析最小 RIFF/WAVE: 取 fmt(采样格式) 与 data(裸 PCM) 两个块。
local function parse_wav(bytes)
    if #bytes < 44 or bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WAVE" then
        return nil, "not a RIFF/WAVE file"
    end
    local le16 = function(p) return string.byte(bytes, p) + string.byte(bytes, p + 1) * 256 end
    local le32 = function(p)
        return string.byte(bytes, p) + string.byte(bytes, p + 1) * 256
             + string.byte(bytes, p + 2) * 65536 + string.byte(bytes, p + 3) * 16777216
    end
    local fmt, off, len
    local pos = 13
    while pos + 7 <= #bytes do
        local id = bytes:sub(pos, pos + 3)
        local size = le32(pos + 4)
        if id == "fmt " then
            fmt = { channels = le16(pos + 10), rate = le32(pos + 12), bits = le16(pos + 22) }
        elseif id == "data" then
            off, len = pos + 8, size
        end
        pos = pos + 8 + size + (size % 2)
    end
    if not fmt or not off then
        return nil, "missing fmt/data chunk"
    end
    if off + len - 1 > #bytes then
        len = #bytes - off + 1
    end
    return { pcm = bytes:sub(off, off + len - 1),
             rate = fmt.rate, channels = fmt.channels, bits = fmt.bits }
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 用录音文件跑一遍流式 ASR, 返回识别文本 (失败返回 nil, reason)。
local function run_asr(cfg, wav)
    local provider = cfg.voice_asr_provider
    if not provider or provider == "" then
        provider = "volcano"
    end
    local loaded, mod = pcall(require, "providers.asr_" .. provider)
    if not loaded or type(mod) ~= "table" or type(mod.open) ~= "function" then
        return nil, "provider load failed: " .. tostring(mod)
    end
    local session, serr = mod.open(cfg, { sample_rate = wav.rate, channels = wav.channels, bits = wav.bits })
    if not session then
        return nil, serr or "session open failed"
    end
    local bytes_per_frame = math.floor(wav.bits / 8) * wav.channels
    local chunk_bytes = math.floor(wav.rate * CHUNK_MS / 1000) * bytes_per_frame
    local total = #wav.pcm
    local i = 1
    while i <= total do
        local piece = wav.pcm:sub(i, math.min(i + chunk_bytes - 1, total))
        local sok, send_err = session:send(piece)
        if not sok then
            session:abort()
            return nil, "send failed: " .. tostring(send_err)
        end
        local _, poll_err = session:poll()
        if poll_err then
            session:abort()
            return nil, "poll failed: " .. tostring(poll_err)
        end
        i = i + chunk_bytes
        delay.delay_ms(CHUNK_MS)
    end
    local text, finish_err = session:finish(ASR_FINISH_TIMEOUT_MS)
    if not text or text == "" then
        return nil, finish_err or "empty transcript"
    end
    return text
end

-- 建一次输出 + 播放器 (整段链路复用, 与 voice_ptt 的 arm_reply_wait 同款)。
local function make_player()
    local codec, rate, channels, bits = bm.get_audio_codec_output_params("audio_dac")
    if not codec then
        return nil, nil
    end
    local out = audio.new_output({ codec, rate, channels, bits, volume = 80 })
    if not out then
        return nil, nil
    end
    local player = audio.player({ output = out })
    if not player then
        out:close()
        return nil, nil
    end
    return player, out
end

-- 提交一句到分句流水线: 首句 play_stream() 建立会话, 后续句 play_stream_append() 追加到
-- 同一会话 (音频在底层环形缓冲中首尾相接, 句间无静音断层)。返回 (ok, reason)。
local function submit_sentence(cfg, sentence, player, started)
    local req, reason = tts.stream_request(cfg, sentence)
    if not req then
        return false, reason or "no stream request"
    end
    local ok
    if started then
        ok = player:play_stream_append(req)
    else
        ok = player:play_stream(req)
    end
    if not ok then
        return false, (started and "play_stream_append failed" or "play_stream submit failed")
    end
    return true
end

-- ---------------------------------------------------------------------------
print(TAG .. " starting")

local cfg = load_cfg()
print(string.format("%s asr_provider=%s tts_provider=%s tts_key=%s",
    TAG, tostring(cfg.voice_asr_provider or "(default)"),
    tostring(cfg.voice_tts_provider or "(default)"),
    (cfg.voice_tts_api_key and cfg.voice_tts_api_key ~= "") and "set" or "MISSING"))

if not storage.exists(SAMPLE) then
    print(TAG .. " RESULT=SAMPLE_MISSING path=" .. SAMPLE)
    return
end
local wav, werr = parse_wav(storage.read_file(SAMPLE))
if not wav then
    print(TAG .. " RESULT=BAD_WAV reason=" .. tostring(werr))
    return
end
print(string.format("%s sample %dHz/%dch/%dbit pcm=%d bytes",
    TAG, wav.rate, wav.channels, wav.bits, #wav.pcm))

print(string.format("%s timing: asr_start t=%d", TAG, system.millis()))
local text, asr_err = run_asr(cfg, wav)
if not text then
    print(string.format("%s timing: asr_done t=%d ok=0", TAG, system.millis()))
    print(TAG .. " ASR=FAILED reason=" .. tostring(asr_err))
    print(TAG .. " RESULT=ASR_FAILED")
    return
end
print(string.format("%s timing: asr_done t=%d ok=1", TAG, system.millis()))
print(TAG .. " ASR=OK text=" .. text)

local player, out = make_player()
if not player then
    print(TAG .. " RESULT=PLAYER_FAILED")
    return
end
if type(player.play_stream) ~= "function" or type(player.play_stream_append) ~= "function"
   or type(player.play_stream_finish) ~= "function" then
    print(TAG .. " RESULT=NO_PLAY_STREAM (firmware lacks player:play_stream pipeline)")
    return
end

-- 清掉上一轮残留, 再注入, 避免读到旧内容。
vstream.reset(storage.get_root_dir())
pcall(storage.remove, storage.join_path(storage.get_root_dir(), "voice_interrupt"))

-- 屏幕桥: 自测基线先清空会话记录, 再写入本轮用户文本 (与 voice_ptt 的 log_user 同款)。
vc.clear_log()
vc.log_user(text)

-- 状态码桥探针: 写一条固定的 <code>|<detail>, 面板轮询时应打印
-- "voice status: code=recognizing detail=e2e-probe" (验证 C 侧查表), 结束时断言文件字节。
local STATUS_PROBE = "recognizing|e2e-probe"
vc.set_status("recognizing", "e2e-probe")

local t_inject = system.millis()
print(string.format("%s timing: inject t=%d", TAG, t_inject))
ep.publish_message({
    source_cap = "lua_script",
    channel = VOICE_CHANNEL,
    chat_id = VOICE_CHAT_ID,
    text = text,
})
print(TAG .. " injected into agent: " .. text)

local queue = {}
local n = 0
local first_play_ms = nil
local t_first_stream = nil
local fail_reason = nil
local raw = ""                       -- 句子拼接 = 完整可见文本 (切句不丢字符), 用于断言上屏
local stream_started = false         -- 首句已建立流式流水线会话
local finish_sent = false            -- 已通知流水线不再追加
local play_end_ms = nil              -- 整段音频播完 (player 停止) 的时刻

-- 消费 /fatfs/voice_stream.txt: 包一层默认读源以记录「首次出现可见文本」的时刻 (first_stream
-- 计时), 其余整读差分 + 切句全部交给 voice_stream。
local base_read = vstream.file_read
local root_dir = storage.get_root_dir()
local function observed_read()
    local vis, done = base_read(root_dir)
    if not t_first_stream and #vis > 0 then
        t_first_stream = system.millis()
        print(string.format("%s timing: first_stream t=%d delta=%d bytes=%d",
            TAG, t_first_stream, t_first_stream - t_inject, #vis))
    end
    return vis, done
end
local stream = vstream.consumer({ read = observed_read })

-- 主循环: 边切句边追加进同一条 TTS 流水线, 直到文本流结束。
while true do
    while true do
        local sentence = stream:next()
        if not sentence then
            break
        end
        vc.log_agent_append(sentence)
        queue[#queue + 1] = sentence
        raw = raw .. sentence
    end

    while #queue > 0 do
        local sentence = trim(table.remove(queue, 1))
        if sentence ~= "" then
            n = n + 1
            print(string.format("%s SENTENCE[%d] text=%s", TAG, n, sentence))
            if not first_play_ms then
                first_play_ms = system.millis() - t_inject
                print(string.format("%s timing: first_sentence t=%d delta=%d", TAG,
                    system.millis(), first_play_ms))
            end
            local ok, reason = submit_sentence(cfg, sentence, player, stream_started)
            if ok then
                print(string.format("%s APPEND[%d] at=%dms", TAG, n, system.millis() - t_inject))
                stream_started = true
            else
                fail_reason = reason
                print(string.format("%s APPEND[%d] FAILED reason=%s", TAG, n, tostring(reason)))
            end
        end
    end

    if stream:finished() then
        if stream_started and not finish_sent then
            player:play_stream_finish()
            finish_sent = true
        end
        break
    end
    if system.millis() - t_inject > REPLY_TIMEOUT_MS then
        fail_reason = fail_reason or "timeout waiting for stream end"
        print(TAG .. " TIMEOUT waiting for reply stream")
        break
    end
    delay.delay_ms(POLL_MS)
end

-- 等待流水线把整段音频连续播完 (单条播放, 句间不重建 player / 不重连)。
if stream_started then
    local saw_running = false
    while true do
        local st = player:poll()
        local running = (st and st.running) and true or false
        if running then
            saw_running = true
        elseif saw_running then
            break
        end
        if system.millis() - t_inject > REPLY_TIMEOUT_MS then
            fail_reason = fail_reason or "playback timeout"
            print(TAG .. " TIMEOUT waiting for playback end")
            break
        end
        delay.delay_ms(POLL_MS)
    end
    play_end_ms = system.millis() - t_inject
    print(string.format("%s PLAY_END at=%dms finish=%s", TAG, play_end_ms, tostring(finish_sent)))
end

pcall(function() player:close() end)
pcall(function() out:close() end)

local total = system.millis() - t_inject
if n == 0 then
    print(TAG .. " RESULT=NO_REPLY")
elseif fail_reason then
    print(string.format("%s RESULT=PARTIAL sentences=%d first_play=%sms play_end=%sms total=%dms reason=%s",
        TAG, n, tostring(first_play_ms), tostring(play_end_ms), total, tostring(fail_reason)))
else
    print(string.format("%s RESULT=OK sentences=%d first_play=%sms play_end=%sms total=%dms",
        TAG, n, tostring(first_play_ms), tostring(play_end_ms), total))
end

-- 上屏断言: 面板气泡来自 /fatfs/voice_log.txt 的 A(助手) 记录 (由 vc.log_agent_append 逐句写入),
-- 首条 A 记录应等于流式文件的完整可见文本。RESULT 只验播放, 这里补验"回复内容是否真的上屏"。
local log_path = storage.join_path(storage.get_root_dir(), "voice_log.txt")
local agent = ""
if storage.exists(log_path) then
    local ok, content = pcall(storage.read_file, log_path)
    if ok and type(content) == "string" then
        -- 记录格式: "<role>\31<text>\30", role 为 U(用户)/ A(助手)。
        for rec in content:gmatch("(.-)\30") do
            local role, body = rec:match("^(.)\31(.*)$")
            if role == "A" then
                agent = body
                break
            end
        end
    end
end
if #agent == 0 then
    print(TAG .. " SCREEN=EMPTY (voice_log.txt 无 A 记录, 面板不会显示回复)")
elseif agent == raw then
    print(string.format("%s SCREEN=OK chars=%d", TAG, #agent))
else
    print(string.format("%s SCREEN=MISMATCH agent=%d raw=%d", TAG, #agent, #raw))
end

-- 状态桥断言: voice_status.txt 的原始字节应等于探针写入的 "<code>|<detail>"。
-- (面板侧查表由上面的 "voice status: code=... detail=..." 日志佐证。)
local status_path = storage.join_path(storage.get_root_dir(), "voice_status.txt")
local status_raw = ""
if storage.exists(status_path) then
    local ok, content = pcall(storage.read_file, status_path)
    if ok and type(content) == "string" then
        status_raw = content
    end
end
if status_raw == STATUS_PROBE then
    print(string.format("%s STATUS=OK value=%s", TAG, status_raw))
else
    print(string.format("%s STATUS=MISMATCH expect=%s got=%s", TAG, STATUS_PROBE, status_raw))
end
vc.set_status("idle")
