-- 语音回复: 由路由规则 voice_reply_run_script 调用, Agent 的回复文本经 args.text 传入。
--
-- 链路: 路由规则匹配 claw_core / out_message (chat_id = "voice") -> 本脚本 -> TTS -> 播放
--
-- V1 说明: TTS 端点/密钥从 /fatfs/ha_voice_runtime.json 读取。
--   voice_tts_provider 为空/generic: 走原通用端点 (voice_tts_url), 把回复文本 POST 给云 TTS,
--             响应音频经 save_path 落盘; 端点为空则直接放弃本次回复。
--   voice_tts_provider 非空: 加载 providers/tts_<provider>.lua 完成合成并落盘 (如 volcano 火山云,
--             新版控制台 X-Api-Key 鉴权), 详见对应 provider 模块。
--   落盘后统一用 audio.player 异步播放; 播放期间轮询打断标志 /fatfs/voice_interrupt,
--             命中即 player:stop() (barge-in)。
--   需先把 TTS 域名加入「HTTP 白名单」(search_http_allowlist)。

local audio = require("audio")
local bm = require("board_manager")
local storage = require("storage")
local json = require("json")
local delay = require("delay")
local capability = require("capability")

local TAG = "[voice_reply]"

-- TTS 落盘文件 (扩展名决定解码器; WAV 由 esp_audio_simple_player 处理)。
local TTS_FILE = "voice_reply.wav"
-- 打断标志: 由 voice_ptt.lua 在用户按下 BOOT / 唤醒时写入; 本脚本播放中轮询到即停止播放。
local INTERRUPT_FLAG = "voice_interrupt"

local text = (args and args.text) or ""
print(TAG .. " agent reply (" .. tostring(#text) .. " chars): " .. text)

local function root(name)
    return storage.join_path(storage.get_root_dir(), name)
end

-- 屏幕桥: ha_panel 轮询 /fatfs/voice_*.txt 把对话显示到 LVGL 面板上。
local function write_bridge(name, content)
    local ok, err = pcall(storage.write_file, root(name), content)
    if not ok then
        print(TAG .. " write " .. name .. " failed: " .. tostring(err))
    end
end

-- 状态反馈 (voice_status.txt -> 面板「状态:」行 + 串口日志)。
-- 本脚本每次回复单独执行一次, 没有常驻循环可做定时回收, 故失败态会一直留在面板上,
-- 直到下一次语音交互 (PTT 开始录音时写「录音中」) 覆盖它。
local function set_status(text)
    write_bridge("voice_status.txt", text)
    print(TAG .. " status -> " .. text)
end

write_bridge("voice_agent.txt", text)
set_status("合成中")

-- 运行时配置桥: 与 voice_ptt.lua 共用 /fatfs/ha_voice_runtime.json (由 ha_panel.c 写入)。
local function load_runtime_config()
    local path = root("ha_voice_runtime.json")
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

local function clear_interrupt()
    local path = root(INTERRUPT_FLAG)
    if storage.exists(path) then
        pcall(storage.remove, path)
    end
end

local function interrupt_requested()
    return storage.exists(root(INTERRUPT_FLAG))
end

-- 把回复文本转义成 JSON 字符串内容。
local function json_escape(s)
    return (s:gsub('[%c\\"]', function(c)
        if c == "\\" then return "\\\\" end
        if c == '"' then return '\\"' end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", string.byte(c))
    end))
end

local cfg = load_runtime_config()
local TTS_URL = cfg.voice_tts_url or ""
local TTS_PROVIDER = cfg.voice_tts_provider or ""
local USE_GENERIC_TTS = (TTS_PROVIDER == "" or TTS_PROVIDER == "generic")

if USE_GENERIC_TTS and TTS_URL == "" then
    print(TAG .. " TTS: no endpoint configured, skipping reply playback")
    set_status("未配置 TTS")
    return
end

-- 打开 DAC 输出 (仅真实 TTS 音频走这里)。
local codec, rate, channels, bits = bm.get_audio_codec_output_params("audio_dac")
if not codec then
    print(TAG .. " get_audio_codec_output_params(audio_dac) failed, skip playback")
    set_status("扬声器不可用")
    return
end

local output = audio.new_output({ codec, rate, channels, bits, volume = 80 })
if not output then
    print(TAG .. " open audio output failed, skip playback")
    set_status("扬声器占用")
    return
end

-- generic 模式: 通用 TTS 端点 (保持原有行为不变)。
--   请求契约 (POST voice_tts_url, Content-Type: application/json):
--     {"format":"wav","text":"<agent reply>"}
--     响应的音频 (WAV) 经 save_path 直接落盘; 鉴权: voice_tts_api_key 非空时附
--     Authorization: Bearer <key>。成功返回落盘路径, 失败返回 nil + 简短原因。
local function generic_synthesize()
    local headers = { ["Content-Type"] = "application/json" }
    local api_key = cfg.voice_tts_api_key or ""
    if api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end

    local body = string.format('{"format":"wav","text":"%s"}', json_escape(text))
    local path = root(TTS_FILE)

    print(TAG .. " TTS request -> " .. TTS_URL .. " (" .. tostring(#text) .. " chars)")

    local call_ok, out, err = capability.call("http_request", {
        url = TTS_URL,
        method = "POST",
        headers = headers,
        body = body,
        save_path = path,
        timeout_ms = 20000,
        max_file_bytes = 4194304,
    }, { source_cap = "voice_tts", max_output_bytes = 8192 })

    if not call_ok then
        print(TAG .. " TTS http_request failed: " .. tostring(err) .. " (" .. tostring(out) .. ")")
        return nil, "TTS 网络错误"
    end

    local status = tostring(out):match("^HTTP (%d+)")
    if status ~= "200" then
        print(TAG .. " TTS HTTP status " .. tostring(status) .. ": " .. tostring(out))
        pcall(storage.remove, path)
        return nil, "TTS HTTP " .. tostring(status)
    end

    if not storage.exists(path) then
        print(TAG .. " TTS: response file missing, skip playback")
        return nil, "TTS 响应缺失"
    end

    return path
end

-- provider 分派: voice_tts_provider 为空/generic 走原逻辑; 否则加载 providers/tts_<name>.lua,
--   由 provider 负责合成音频并落盘, 返回音频文件路径后缀由 provider.default_ext 决定。
local save_path
local tts_error
if USE_GENERIC_TTS then
    save_path, tts_error = generic_synthesize()
else
    local ok, mod = pcall(require, "providers.tts_" .. TTS_PROVIDER)
    if ok and type(mod) == "table" and type(mod.synthesize) == "function" then
        local candidate = root("voice_reply." .. (mod.default_ext or "wav"))
        local done, reason = mod.synthesize(cfg, text, candidate, storage.get_root_dir())
        if done then
            save_path = candidate
        else
            print(TAG .. " TTS provider '" .. TTS_PROVIDER .. "' synthesize failed: " .. tostring(reason))
            tts_error = reason or "语音合成失败"
        end
    else
        print(TAG .. " TTS: unknown provider '" .. tostring(TTS_PROVIDER) .. "', skip playback")
        tts_error = "TTS 配置无效"
    end
end

if not save_path then
    set_status(tts_error or "语音合成失败")
    output:close()
    return
end

-- 播放前清掉可能残留的打断标志, 避免上一条过早停止本次播放。
clear_interrupt()

local player = audio.player({ output = output })
if not player then
    print(TAG .. " create player failed, skip playback")
    set_status("播放器创建失败")
    output:close()
    return
end

local started = player:play(save_path) -- 默认异步 (wait 缺省 false)
if not started then
    print(TAG .. " play failed: " .. save_path)
    set_status("播放失败")
    player:close()
    output:close()
    return
end

set_status("播报中")
print(TAG .. " playback started: " .. save_path)

-- 轮询到播放结束; 期间若用户开始说话 (barge-in) 立即停止。
local interrupted = false
while true do
    local st = player:poll()
    if not (st and st.running) then
        break
    end
    if interrupt_requested() then
        print(TAG .. " barge-in detected -> stop playback")
        player:stop()
        clear_interrupt()
        interrupted = true
        break
    end
    delay.delay_ms(20)
end

player:close()
output:close()
-- 被打断时不写状态: 此时 voice_ptt.lua 已开始录音并写了「录音中」, 别把它覆盖掉。
if not interrupted then
    set_status("空闲")
end
print(TAG .. " playback done")
