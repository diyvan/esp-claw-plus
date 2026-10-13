-- 语音输入: BOOT 键按下开始录音, 松开结束; 或由唤醒词「嗨小欧」自动触发录音 (静音/超时结束)。
--
-- 由路由规则 startup_voice_ptt 以 async 方式常驻运行 (timeout_ms = 0, 即运行到被取消)。
-- 链路: record_*() -> asr_transcribe() -> event_publisher.publish_message()
--       -> 路由规则 im_any_message_agent -> Agent -> out_message 事件
--       -> 路由规则 voice_reply_run_script -> voice_reply.lua (TTS/播放)
--
-- 唤醒链路: C 侧 ha_voice_wake (WakeNet 仅唤醒) 检测到唤醒词后, 在存储根目录写入
-- wake_trigger 文件并让出麦克风; 本脚本空闲时轮询该文件, 存在即进入自动录音模式。
--
-- V1 说明: ASR 端点/密钥从 /fatfs/ha_voice_runtime.json (网页「语音助手」页) 读取。
-- 端点非空时 asr_transcribe() 把 WAV 以 base64 放进 JSON 经 capability.call("http_request")
-- 送云端 ASR (需先把 ASR 域名加入「HTTP 白名单」); 端点为空时不伪造转写, 直接放弃本次识别。
-- 唤醒自动录音受同一 JSON 里的 voice_wake_enabled 门控; 关闭时唤醒触发被丢弃, 仅保留 BOOT 键 PTT。

local button = require("button")
local bm = require("board_manager")
local audio = require("audio")
local storage = require("storage")
local delay = require("delay")
local system = require("system")
local ep = require("event_publisher")
local json = require("json")
local capability = require("capability")

local TAG = "[voice_ptt]"

local PTT_GPIO = 35        -- BOOT 按键 (板级 strapping 引脚)
local ACTIVE_LEVEL = 0     -- 低电平有效
local POLL_MS = 20         -- 空闲时主循环轮询间隔

-- 流式采集参数
local READ_FRAMES = 1024   -- 每次读取的帧数 (48kHz 下约 21ms)
local MIN_RECORD_MS = 500  -- 短于此时长视为误触, 丢弃
local MAX_RECORD_MS = 10000 -- 上限, 避免一直按着写爆 /fatfs (3MB 分区)

-- 优先请求的采集格式: ASR 常用 16kHz 单声道, 数据量约为板级默认 48kHz 立体声的
-- 1/6, 大幅缩短 base64 编码与上传耗时; codec 不支持时回退板级默认格式。
local ASR_RATE = 16000
local ASR_CHANNELS = 1

-- 唤醒自动录音参数 (无按键, 靠静音检测收尾)
local WAKE_TRIGGER = "wake_trigger"   -- C 侧 ha_voice_wake 写入的唤醒触发文件
local AUTO_MAX_RECORD_MS = 8000       -- 自动录音上限
local AUTO_NO_SPEECH_MS = 2500        -- 一直没声就放弃 (唤醒后无人说话)
local AUTO_SILENCE_MS = 800           -- 说完后连续静音这么久即收尾
local AUTO_SPEECH_RMS = 400           -- 判定"有说话"的 RMS 阈值 (16-bit 满量程 32767)
local SILENT_RMS = 150                -- 整段录音峰值 RMS 低于此值视为没录到声音, 直接反馈不再上传

-- 状态反馈: 失败原因同样写进 voice_status.txt 上屏, 但错误态只保留 STATUS_HOLD_MS,
-- 到期由主循环自动回「空闲」, 避免面板状态行/指示灯一直卡在错误态。
local STATUS_IDLE = "空闲"
local STATUS_HOLD_MS = 4000
local REPLY_TIMEOUT_MS = 30000 -- 注入 Agent 后等待回复的上限, 超时提示「AI 无响应」
local FINISH_TIMEOUT_MS = 6000 -- 流式 ASR: 收尾发末包后等待最终结果的上限

-- 语音会话所在渠道/会话, 必须与路由规则 voice_reply_run_script 的匹配条件一致
local VOICE_CHANNEL = "voice"
local VOICE_CHAT_ID = "voice"

-- 屏幕桥: ha_panel 轮询 /fatfs/voice_*.txt 把对话显示到 LVGL 面板上。
local function write_bridge(name, content)
    local ok, err = pcall(function()
        storage.write_file(storage.join_path(storage.get_root_dir(), name), content)
    end)
    if not ok then
        print(TAG .. " write " .. name .. " failed: " .. tostring(err))
    end
    return ok
end

-- 状态反馈 (voice_status.txt -> 面板「状态:」行 + 串口日志)。
-- set_status: 流程态 (录音中/识别中/空闲), 保持到下次变化。
-- set_wait:   等待态 (思考中), 超过 timeout_ms 仍未被下一步推进 (voice_reply.lua 写新状态)
--             就改成 timeout_text, 让"识别成功但没人回复"也能看见。
-- set_error:  失败态 (录音太短/未录到声音/ASR HTTP 4xx/未识别到语音 ...), 保留
--             STATUS_HOLD_MS 后自动回「空闲」。
-- 到期改写的守卫: 只有当面板状态仍是本阶段写下的文本时才改写, 避免覆盖别的脚本
-- (voice_reply.lua) 已推进的新状态。
local status_until, status_next, status_guard = nil, nil, nil

local function arm_status(deadline, next_text, guard)
    status_until, status_next, status_guard = deadline, next_text, guard
end

local function write_status(text)
    write_bridge("voice_status.txt", text)
    print(TAG .. " status -> " .. text)
end

local function set_status(text)
    arm_status(nil, nil, nil)
    write_status(text)
end

local function set_wait(text, timeout_ms, timeout_text)
    arm_status(system.millis() + timeout_ms, timeout_text, text)
    write_status(text)
end

local function set_error(text)
    arm_status(system.millis() + STATUS_HOLD_MS, STATUS_IDLE, text)
    write_status(text)
end

local function tick_status()
    if not status_until or system.millis() < status_until then
        return
    end
    local next_text, guard = status_next, status_guard
    arm_status(nil, nil, nil)
    if guard then
        local path = storage.join_path(storage.get_root_dir(), "voice_status.txt")
        local ok, cur = pcall(storage.read_file, path)
        if not (ok and type(cur) == "string" and cur == guard) then
            return
        end
    end
    if next_text == STATUS_IDLE then
        write_status(STATUS_IDLE)
    else
        set_error(next_text)
    end
end

-- 取走唤醒触发文件: 存在则删除并返回 true (边缘触发, 一次唤醒只消费一次)。
local function take_wake_trigger()
    local path = storage.join_path(storage.get_root_dir(), WAKE_TRIGGER)
    if not storage.exists(path) then
        return false
    end
    pcall(storage.remove, path)
    return true
end

-- 语音打断 (barge-in): 用户开始说话 (按下 BOOT 或唤醒) 时写标志文件,
-- 正在播放 TTS 的 voice_reply.lua 轮询到该标志即 player:stop()。跨脚本唯一可行
-- 的信道是文件 (/fatfs), 详见 voice_reply.lua。
local INTERRUPT_FLAG = "voice_interrupt"
local function signal_interrupt()
    pcall(storage.write_file, storage.join_path(storage.get_root_dir(), INTERRUPT_FLAG), "")
end

-- ---------------------------------------------------------------------------
-- 运行时配置桥: C 侧 (ha_panel.c) 把网页配置写入 /fatfs/ha_voice_runtime.json,
-- 本脚本读取其中的 ASR/TTS 端点与唤醒开关。缓存 1s, 避免每轮轮询都读文件。
-- 字段: voice_enabled / voice_wake_enabled / voice_asr_url / voice_asr_api_key /
--       voice_asr_provider / voice_asr_resource_id /
--       voice_tts_url / voice_tts_api_key / voice_tts_provider /
--       voice_tts_resource_id / voice_tts_speaker / ha_enabled / ha_base_url / ha_token
-- 说明: voice_enabled 是语音助手总开关, 关闭后 PTT 与唤醒词都停用。
-- ---------------------------------------------------------------------------
local RUNTIME_CONFIG = "ha_voice_runtime.json"
local cfg_cache = {}
local cfg_at = -100000

local function load_runtime_config()
    local path = storage.join_path(storage.get_root_dir(), RUNTIME_CONFIG)
    if not storage.exists(path) then
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

local function runtime_config()
    local now = system.millis()
    if now - cfg_at >= 1000 then
        cfg_cache = load_runtime_config()
        cfg_at = now
    end
    return cfg_cache
end

-- 配置里的布尔值可能是 JSON 布尔 (true/false) 或字符串 ("true"/"false")。
local function cfg_is_true(value, fallback)
    if value == nil then
        return fallback
    end
    return value == true or value == "true"
end

-- 语音助手总开关 (voice_enabled): 关闭后 PTT 与唤醒词都停用, 面板也会隐藏语音页。
local function voice_assistant_enabled()
    return cfg_is_true(runtime_config().voice_enabled, true)
end

-- 估算一小段 16-bit 小端交织 PCM 的 RMS (每 4 帧取 1 帧, 限制 CPU 开销)。
local function chunk_rms(chunk, bytes_per_frame)
    local bpf = bytes_per_frame
    if not bpf or bpf < 2 then
        bpf = 2
    end
    local n_bytes = #chunk
    if n_bytes < bpf then
        return 0
    end
    local step = bpf * 4
    local sum, count = 0, 0
    local i = 1
    while i + 1 <= n_bytes do
        local lo = string.byte(chunk, i)
        local hi = string.byte(chunk, i + 1)
        if lo and hi then
            local v = hi * 256 + lo
            if v >= 32768 then
                v = v - 65536
            end
            sum = sum + v * v
            count = count + 1
        end
        i = i + step
    end
    if count == 0 then
        return 0
    end
    return math.sqrt(sum / count)
end

-- 组装 44 字节小端 WAV 头 (PCM, 16-bit 字段格式编号 = 1)。
local function u16le(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function wav_header(data_bytes, rate, channels, bits)
    local bytes_per_sample = math.floor(bits / 8)
    local block_align = channels * bytes_per_sample
    local byte_rate = rate * block_align
    return "RIFF" .. u32le(data_bytes + 36) .. "WAVE"
        .. "fmt " .. u32le(16) .. u16le(1) .. u16le(channels)
        .. u32le(rate) .. u32le(byte_rate) .. u16le(block_align) .. u16le(bits)
        .. "data" .. u32le(data_bytes)
end

-- ---------------------------------------------------------------------------
-- Base64 编码 (纯 Lua, 避免依赖位运算)。
-- 优化: 预取 64 个单字符 (单字符子串会被驻留), 每 3 字节把 4 个索引分别写入
-- group, 每 2048 项才 concat 一次 —— 避免原先每组 4 次 string.sub + 3 次字符串
-- 拼接产生的几十万次临时字符串分配 (这是 520KB 上传卡顿的主因)。
-- http_request 的 body 只能是字符串, 故音频必须以 base64 放进 JSON 上传。
-- ---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64_CHAR = {}
for i = 0, 63 do
    B64_CHAR[i] = B64:sub(i + 1, i + 1)
end

-- 每 3 字节 -> 4 个索引: [a>>2][(a%4)*16+(b>>4)][(b%16)*4+(c>>6)][c%64]
local function base64_encode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end
    local byte = string.byte
    local n = #data
    local out, group = {}, {}
    local gi, i = 0, 1
    while i + 2 <= n do
        local a, b, c = byte(data, i), byte(data, i + 1), byte(data, i + 2)
        group[gi + 1] = B64_CHAR[(a - a % 4) / 4]
        group[gi + 2] = B64_CHAR[(a % 4) * 16 + (b - b % 16) / 16]
        group[gi + 3] = B64_CHAR[(b % 16) * 4 + (c - c % 64) / 64]
        group[gi + 4] = B64_CHAR[c % 64]
        gi = gi + 4
        if gi >= 2048 then
            out[#out + 1] = table.concat(group)
            group, gi = {}, 0
        end
        i = i + 3
    end
    local rem = n - i + 1
    if rem == 1 then
        local a = byte(data, i)
        group[gi + 1] = B64_CHAR[(a - a % 4) / 4]
        group[gi + 2] = B64_CHAR[(a % 4) * 16]
        group[gi + 3] = "=="
        gi = gi + 3
    elseif rem == 2 then
        local a, b = byte(data, i), byte(data, i + 1)
        group[gi + 1] = B64_CHAR[(a - a % 4) / 4]
        group[gi + 2] = B64_CHAR[(a % 4) * 16 + (b - b % 16) / 16]
        group[gi + 3] = B64_CHAR[(b % 16) * 4]
        group[gi + 4] = "="
        gi = gi + 4
    end
    if gi > 0 then
        out[#out + 1] = table.concat(group)
    end
    return table.concat(out)
end

local function first_string(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and v ~= "" then
            return v
        end
    end
    return nil
end

-- 从 ASR 响应里取转写文本: 兼容常见字段名, 非 JSON 时退化为去引号的纯文本。
local function extract_transcript(resp)
    if type(resp) ~= "string" or resp == "" then
        return nil
    end
    local decode_ok, data = pcall(json.decode, resp)
    if decode_ok and type(data) == "table" then
        local d = data.data
        local choice1 = (type(data.choices) == "table") and data.choices[1] or nil
        local msg = (type(choice1) == "table") and choice1.message or nil
        local content = (type(msg) == "table") and msg.content or nil
        return first_string(
            data.text, data.transcript, data.result, data.output_text,
            (type(d) == "table") and d.text or nil,
            (type(d) == "table") and d.result or nil,
            (type(d) == "string") and d or nil,
            content
        )
    end
    local trimmed = resp:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"(.*)"$', "%1")
    if trimmed ~= "" then
        return trimmed
    end
    return nil
end

-- ASR: 端点与密钥来自运行时配置 (网页「语音助手」页)。端点为空时不做任何伪造, 直接放弃本次识别。
--
-- 返回: 转写文本 (成功且非空) 或 nil; 第二个返回值为给面板反馈的简短失败原因 (中文)。
--
-- 上传契约 (POST voice_asr_url, Content-Type: application/json):
--   {"format":"wav","sample_rate":<sr>,"channels":<ch>,"bits":<b>,"audio_base64":"<...>"}
-- 响应: JSON, 转写文本依次尝试 text / transcript / result / output_text /
--       data(.text/.result/字符串) / choices[1].message.content。
-- 鉴权: voice_asr_api_key 非空时附 Authorization: Bearer <key>。
-- 注意: cap_http_request 有主机白名单, 必须先把 ASR 域名加入「HTTP 白名单」
--       (search_http_allowlist / NVS http_allow_ls)。
local function asr_transcribe(wav_path, info)
    local cfg = runtime_config()

    -- 供应商分派: voice_asr_provider 为空 / "generic" 时走下方原有 generic 逻辑(保持不变);
    -- 其余值即 require("providers.asr_<provider>")。接入新云端只需新增 providers/asr_*.lua。
    local provider = cfg.voice_asr_provider or ""
    if provider ~= "" and provider ~= "generic" then
        local ok, mod = pcall(require, "providers.asr_" .. provider)
        if ok and type(mod) == "table" and type(mod.transcribe) == "function" then
            return mod.transcribe(cfg, wav_path, info)
        end
        print(TAG .. " ASR: unknown provider '" .. tostring(provider) .. "', aborting")
        return nil, "ASR 配置无效"
    end

    local asr_url = cfg.voice_asr_url or ""
    if asr_url == "" then
        print(TAG .. " ASR: no endpoint configured, aborting transcription")
        return nil, "未配置 ASR"
    end
    if not storage.exists(wav_path) then
        print(TAG .. " ASR: wav not found: " .. tostring(wav_path))
        return nil, "录音文件缺失"
    end
    local read_ok, wav = pcall(storage.read_file, wav_path)
    if not read_ok or type(wav) ~= "string" or wav == "" then
        print(TAG .. " ASR: read wav failed")
        return nil, "录音读取失败"
    end

    local rate = (info and info.sample_rate) or 16000
    local channels = (info and info.channels) or 1
    local bits = (info and info.bits) or 16
    local body = string.format(
        '{"format":"wav","sample_rate":%d,"channels":%d,"bits":%d,"audio_base64":"%s"}',
        rate, channels, bits, base64_encode(wav))

    local headers = { ["Content-Type"] = "application/json" }
    local api_key = cfg.voice_asr_api_key or ""
    if api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end

    print(string.format("%s ASR upload: %d bytes wav -> %s (%dHz/%dch/%dbit)",
                        TAG, #wav, asr_url, rate, channels, bits))

    local call_ok, out, err = capability.call("http_request", {
        url = asr_url,
        method = "POST",
        headers = headers,
        body = body,
        timeout_ms = 20000,
        max_body_bytes = 16384,
    }, { source_cap = "voice_asr", max_output_bytes = 32768 })

    if not call_ok then
        print(TAG .. " ASR http_request failed: " .. tostring(err) .. " (" .. tostring(out) .. ")")
        return nil, "ASR 网络错误"
    end

    local status, resp = tostring(out):match("^HTTP (%d+)\n(.*)$")
    if not status then
        print(TAG .. " ASR: unexpected response: " .. tostring(out))
        return nil, "ASR 响应异常"
    end
    if status ~= "200" then
        print(TAG .. " ASR HTTP status " .. status .. ": " .. tostring(resp))
        return nil, "ASR HTTP " .. status
    end

    local text = extract_transcript(resp)
    if not text then
        print(TAG .. " ASR: no transcript in response: " .. tostring(resp))
        return nil, "未识别到语音"
    end
    return text
end


local function inject_text(text)
    ep.publish_message({
        source_cap = "lua_script",
        channel = VOICE_CHANNEL,
        chat_id = VOICE_CHAT_ID,
        text = text,
    })
    print(TAG .. " injected into agent: " .. text)
end

-- ---------------------------------------------------------------------------
-- PTT 状态机: idle <-> recording
-- ---------------------------------------------------------------------------
local state = "idle"          -- "idle" | "recording"
local release_requested = false
local rec = nil               -- { input, info, chunks, bytes, start_ms }

-- 收尾: 关闭设备, 落盘 wav, 走 ASR 并注入 Agent。
-- 每个失败分支都把原因经 set_error() 反馈到面板状态行 (不再静默回到「空闲」) 并打串口日志。
local function finish_recording(ok, reason)
    local input = rec.input
    local info = rec.info
    local chunks = rec.chunks
    local session = rec.session
    local stream_err = rec.stream_err
    local data_bytes = rec.bytes
    local peak_rms = rec.peak_rms
    local elapsed = system.millis() - rec.start_ms

    input:close()
    rec = nil
    state = "idle"
    release_requested = false

    if not ok or data_bytes == 0 then
        if session then session:abort() end
        print(TAG .. " recording aborted")
        set_error(reason or "录音失败")
        return
    end
    if elapsed < MIN_RECORD_MS then
        if session then session:abort() end
        print(string.format("%s too short (%dms < %dms), ignored", TAG, elapsed, MIN_RECORD_MS))
        set_error(string.format("录音太短 %dms", elapsed))
        return
    end
    -- 整段录音的峰值 RMS 太低 = 麦克风没收到有效声音, 及时反馈, 不做无谓的云端上传。
    if peak_rms < SILENT_RMS then
        if session then session:abort() end
        print(string.format("%s no signal (peak rms=%.0f < %d), skip asr", TAG, peak_rms, SILENT_RMS))
        set_error("未录到声音")
        return
    end

    -- 流式 ASR: 音频已边录边发, 此处仅发末包并取最终文本, 不落盘 WAV。
    if session then
        print(string.format("%s streamed %dms %dHz/%dch/%dbit bytes=%d peak_rms=%.0f",
                            TAG, elapsed, info.sample_rate, info.channels, info.bits, data_bytes, peak_rms))
        set_status("识别中")
        local text, err = session:finish(FINISH_TIMEOUT_MS)
        if (not text or text == "") and stream_err then
            err = stream_err
        end
        if text and text ~= "" then
            write_bridge("voice_user.txt", text)
            set_wait("思考中", REPLY_TIMEOUT_MS, "AI 无响应")
            inject_text(text)
        else
            set_error(err or "识别失败")
        end
        return
    end

    -- 批量上传 (generic 契约): 数据 + 头部一次性落盘 (storage.write_file 为二进制安全写入)。
    local out = { wav_header(data_bytes, info.sample_rate, info.channels, info.bits) }
    for i = 1, #chunks do
        out[i + 1] = chunks[i]
    end
    if not write_bridge("voice_ptt.wav", table.concat(out)) then
        set_error("录音写盘失败")
        return
    end

    print(string.format("%s recorded %dms %dHz/%dch/%dbit bytes=%d peak_rms=%.0f",
                        TAG, elapsed, info.sample_rate, info.channels, info.bits, data_bytes, peak_rms))

    set_status("识别中")
    local text, err = asr_transcribe(storage.join_path(storage.get_root_dir(), "voice_ptt.wav"), info)
    if text and text ~= "" then
        write_bridge("voice_user.txt", text)
        set_wait("思考中", REPLY_TIMEOUT_MS, "AI 无响应")
        inject_text(text)
    else
        set_error(err or "识别失败")
    end
end

-- 读一小段 PCM; 松手 / 静音 / 超时后收尾。由主循环在 recording 状态下调用。
local function record_step()
    local bytes_per_frame = rec.info.bytes_per_frame
    if not bytes_per_frame or bytes_per_frame <= 0 then
        bytes_per_frame = 2
    end
    local want = READ_FRAMES * bytes_per_frame

    local chunk = rec.input:read({ bytes = want })
    if not chunk or #chunk == 0 then
        print(TAG .. " input read returned no data, aborting")
        finish_recording(false, "麦克风读取失败")
        return
    end

    rec.bytes = rec.bytes + #chunk

    if rec.session then
        -- 流式 ASR: 边录边发, 并把增量识别文本实时上屏。
        local sent, serr = rec.session:send(chunk)
        if not sent then
            rec.stream_err = serr or "ASR 发送失败"
            print(TAG .. " ASR send failed: " .. tostring(rec.stream_err))
            finish_recording(true)
            return
        end
        local text, perr = rec.session:poll()
        if perr then
            rec.stream_err = perr
            print(TAG .. " ASR poll failed: " .. tostring(perr))
            finish_recording(true)
            return
        end
        if text and text ~= "" and text ~= rec.stream_text then
            rec.stream_text = text
            write_bridge("voice_user.txt", text)
        end
    else
        rec.chunks[#rec.chunks + 1] = chunk
    end

    local elapsed = system.millis() - rec.start_ms
    -- 记录峰值 RMS: 收尾时据此判断"有没有真的录到声音" (两种模式都用)。
    local rms = chunk_rms(chunk, bytes_per_frame)
    if rms > rec.peak_rms then
        rec.peak_rms = rms
    end

    if rec.mode == "auto" then
        if rms >= AUTO_SPEECH_RMS then
            rec.spoke = true
            rec.silence_ms = 0
        elseif rec.spoke then
            rec.silence_ms = rec.silence_ms + rec.chunk_ms
            if rec.silence_ms >= AUTO_SILENCE_MS then
                print(string.format("%s auto: %dms silence after speech, stopping", TAG, rec.silence_ms))
                finish_recording(true)
                return
            end
        elseif elapsed >= AUTO_NO_SPEECH_MS then
            print(TAG .. " auto: no speech detected, aborting")
            finish_recording(false, "未检测到说话")
            return
        end
    end

    if release_requested or elapsed >= rec.max_ms then
        if elapsed >= rec.max_ms then
            print(string.format("%s reached max %dms, stopping", TAG, rec.max_ms))
        end
        finish_recording(true)
    end
end

-- mode: "ptt" (按键) | "auto" (唤醒词触发)
local function start_recording(mode)
    local codec, rate, channels, bits = bm.get_audio_codec_input_params("audio_adc")
    if not codec then
        print(TAG .. " get_audio_codec_input_params(audio_adc) failed")
        set_error("麦克风不可用")
        return
    end

    -- 优先请求 16kHz 单声道; codec/底层不支持时回退板级默认格式 (新的 new_input
    -- 会重新配置 codec, 失败时已释放麦克风仲裁, 故可安全重试)。
    local input = audio.new_input({ codec, ASR_RATE, ASR_CHANNELS, bits, volume = 80 })
    if not input then
        print(string.format("%s %dHz/%dch not supported, fallback to default %dHz/%dch",
                            TAG, ASR_RATE, ASR_CHANNELS, rate, channels))
        input = audio.new_input({ codec, rate, channels, bits, volume = 80 })
    end
    if not input then
        print(TAG .. " open audio input failed")
        set_error("麦克风占用")
        return
    end

    local info = input:info()
    local chunk_ms = 0
    if info.sample_rate and info.sample_rate > 0 then
        chunk_ms = math.floor(READ_FRAMES * 1000 / info.sample_rate)
    end
    rec = {
        input = input,
        info = info,
        chunks = {},
        bytes = 0,
        start_ms = system.millis(),
        mode = mode,
        max_ms = (mode == "auto") and AUTO_MAX_RECORD_MS or MAX_RECORD_MS,
        chunk_ms = chunk_ms,
        spoke = false,
        silence_ms = 0,
        peak_rms = 0,
        session = nil,
        stream_text = "",
        stream_err = nil,
    }
    release_requested = false

    -- 流式 ASR: provider 导出 open() 时先开一条会话, 之后 record_step 边录边发。
    -- (provider 为空 / generic 时保持原有批量路径, 此处不做任何事。)
    local cfg = runtime_config()
    local provider = cfg.voice_asr_provider or ""
    if provider ~= "" and provider ~= "generic" then
        local ok, mod = pcall(require, "providers.asr_" .. provider)
        if ok and type(mod) == "table" and type(mod.open) == "function" then
            local session, serr = mod.open(cfg, info)
            if not session then
                input:close()
                rec = nil
                set_error(serr or "ASR 初始化失败")
                return
            end
            rec.session = session
        elseif not (ok and type(mod) == "table" and type(mod.transcribe) == "function") then
            print(TAG .. " ASR: unknown provider '" .. tostring(provider) .. "', using batch path")
        end
    end

    state = "recording"

    set_status("录音中")
    print(string.format("%s %s start: %dHz/%dch/%dbit (bpf=%s)%s",
                        TAG, mode, info.sample_rate, info.channels, info.bits,
                        tostring(info.bytes_per_frame), rec.session and " [stream]" or ""))
end

local function on_press_down(evt)
    if state == "recording" then
        return
    end
    if not voice_assistant_enabled() then
        print(TAG .. " voice assistant disabled by config -> PTT ignored")
        return
    end
    print(TAG .. " PTT down (event=" .. tostring(evt and evt.event) .. ")")
    -- 丢弃可能残留的唤醒触发, 避免按键结束后又被自动录音再触发一次。
    take_wake_trigger()
    -- 立即打断正在播放的 TTS (barge-in)。
    signal_interrupt()
    start_recording("ptt")
end

local function on_press_up(evt)
    if state ~= "recording" then
        return
    end
    print(TAG .. " PTT up (event=" .. tostring(evt and evt.event) .. "), stopping")
    release_requested = true
end

local handle, herr = button.new(PTT_GPIO, ACTIVE_LEVEL)
if not handle then
    error(TAG .. " button.new failed for GPIO " .. PTT_GPIO .. ": " .. tostring(herr))
end

local ok_down, err_down = button.on(handle, "press_down", on_press_down)
if not ok_down then
    error(TAG .. " button.on(press_down) failed: " .. tostring(err_down))
end

local ok_up, err_up = button.on(handle, "press_up", on_press_up)
if not ok_up then
    error(TAG .. " button.on(press_up) failed: " .. tostring(err_up))
end

print(string.format("%s ready: GPIO %d active_level=%d, PTT (min %dms / max %dms) + wake auto-record (silence %dms / max %dms)",
                    TAG, PTT_GPIO, ACTIVE_LEVEL, MIN_RECORD_MS, MAX_RECORD_MS, AUTO_SILENCE_MS, AUTO_MAX_RECORD_MS))

-- 唤醒触发: 语音助手与唤醒词都开启时才自动录音。
-- 关闭时必须消费掉触发文件, 否则会不断重复判定。
local function consume_wake_trigger()
    if not take_wake_trigger() then
        return false
    end
    if not voice_assistant_enabled() then
        print(TAG .. " voice assistant disabled by config -> trigger ignored")
        return false
    end
    if not cfg_is_true(runtime_config().voice_wake_enabled, true) then
        print(TAG .. " wake word disabled by config -> trigger ignored")
        return false
    end
    return true
end

while true do
    button.dispatch()
    if state == "recording" then
        record_step()
    elseif consume_wake_trigger() then
        print(TAG .. " wake trigger detected -> auto record")
        signal_interrupt()
        start_recording("auto")
    else
        -- 空闲时把到期的错误状态恢复成「空闲」, 然后按轮询间隔休眠。
        tick_status()
        delay.delay_ms(POLL_MS)
    end
end
