-- 语音识别离线回放自测: 用一段罐装录音直接驱动流式 ASR, 不依赖麦克风/PTT/唤醒词。
--
-- 用途: 以完全一致的输入复现并定位「ASR 网络连接失败」等识别异常, 每次测试条件相同。
-- 运行 (串口 REPL):
--   lua --run --path /system/voicetest/asr_replay.lua
--
-- 录音文件: /system/voicetest/asr_sample.wav (16kHz/mono/16bit, 内容「今天天气怎么样」)
-- 配置来源: 与 voice_ptt 相同 —— /fatfs/ha_voice_runtime.json (网页「语音助手」页写)。
--
-- 输出关键行:
--   RESULT=OK text=<识别文本>        识别成功
--   RESULT=OPEN_FAILED reason=<中文> 建连失败 (「ASR 网络连接失败」等)
--   RESULT=SEND_FAILED / POLL_FAILED / FINISH_FAILED
--
-- provider 位于 /system/skills/voice/scripts, 不在本脚本目录内, 故手动补 package.path。

package.path = package.path
    .. ";/system/skills/voice/scripts/?.lua"
    .. ";/system/skills/voice/scripts/?/init.lua"

local storage = require("storage")
local delay = require("delay")
local json = require("json")

local TAG = "[asr_replay]"
local SAMPLE = "/system/voicetest/asr_sample.wav"
local CHUNK_MS = 60          -- 与 voice_ptt 边录边发节奏一致
local FINISH_TIMEOUT_MS = 8000

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

-- 解析最小的 RIFF/WAVE: 取 fmt(采样格式) 与 data(裸 PCM) 两个块。
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
        pos = pos + 8 + size + (size % 2)   -- 块按 2 字节边界对齐
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

print(TAG .. " starting")

local cfg = load_cfg()
local provider = cfg.voice_asr_provider
if not provider or provider == "" then
    provider = "volcano"
end
print(string.format("%s provider=%s url=%s key=%s", TAG, provider,
                    tostring(cfg.voice_asr_url or ""),
                    (cfg.voice_asr_api_key and cfg.voice_asr_api_key ~= "") and "set" or "MISSING"))

if not storage.exists(SAMPLE) then
    print(TAG .. " RESULT=SAMPLE_MISSING path=" .. SAMPLE)
    return
end
local raw = storage.read_file(SAMPLE)
local wav, werr = parse_wav(raw)
if not wav then
    print(TAG .. " RESULT=BAD_WAV reason=" .. tostring(werr))
    return
end
print(string.format("%s sample %d bytes, %dHz/%dch/%dbit, pcm=%d bytes",
                    TAG, #raw, wav.rate, wav.channels, wav.bits, #wav.pcm))

local loaded, mod = pcall(require, "providers.asr_" .. provider)
if not loaded or type(mod) ~= "table" or type(mod.open) ~= "function" then
    print(TAG .. " RESULT=PROVIDER_LOAD_FAILED reason=" .. tostring(mod))
    return
end

local session, serr = mod.open(cfg, { sample_rate = wav.rate, channels = wav.channels, bits = wav.bits })
if not session then
    print(TAG .. " RESULT=OPEN_FAILED reason=" .. tostring(serr))
    return
end
print(TAG .. " session open ok")

local bytes_per_frame = math.floor(wav.bits / 8) * wav.channels
local chunk_bytes = math.floor(wav.rate * CHUNK_MS / 1000) * bytes_per_frame
local total = #wav.pcm
local last_text = ""
local sent = 0
local i = 1
while i <= total do
    local piece = wav.pcm:sub(i, math.min(i + chunk_bytes - 1, total))
    local sok, send_err = session:send(piece)
    if not sok then
        print(TAG .. " RESULT=SEND_FAILED reason=" .. tostring(send_err))
        session:abort()
        return
    end
    sent = sent + #piece
    local text, poll_err = session:poll()
    if poll_err then
        print(TAG .. " RESULT=POLL_FAILED reason=" .. tostring(poll_err))
        session:abort()
        return
    end
    if text and text ~= "" and text ~= last_text then
        last_text = text
        print(TAG .. " partial: " .. text)
    end
    i = i + chunk_bytes
    delay.delay_ms(CHUNK_MS)
end

print(string.format("%s sent %d/%d bytes, finish (timeout %dms)", TAG, sent, total, FINISH_TIMEOUT_MS))
local text, finish_err = session:finish(FINISH_TIMEOUT_MS)
if not text then
    print(TAG .. " RESULT=FINISH_FAILED reason=" .. tostring(finish_err))
    return
end
print(TAG .. " RESULT=OK text=" .. tostring(text))
