-- 共享 TTS 合成: 把一段文本合成为音频文件并返回落盘路径。
--
-- voice_reply.lua (整段回复) 与 voice_ptt.lua (流式逐句播报) 共用本模块, 避免重复实现
-- provider 分派与 generic 端点逻辑。
--
-- 分派规则 (与 voice_reply.lua 原逻辑一致):
--   voice_tts_provider 为空 / "generic": 走通用端点 voice_tts_url, 响应 WAV 经 save_path 落盘。
--   否则: 加载 providers/tts_<provider>.lua, 由 provider 负责合成并落盘, 扩展名取 module.default_ext。
--
-- 需先把 TTS 域名加入「HTTP 白名单」(search_http_allowlist)。

local storage = require("storage")
local capability = require("capability")

local M = {}

local TAG = "[voice_tts]"

-- 把文本转义成 JSON 字符串内容。
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

-- generic 通用端点 (POST voice_tts_url, {"format":"wav","text":"..."})。
local function generic_synthesize(cfg, text, out_path)
    local headers = { ["Content-Type"] = "application/json" }
    local api_key = cfg.voice_tts_api_key or ""
    if api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end

    local body = string.format('{"format":"wav","text":"%s"}', json_escape(text))

    local call_ok, out, err = capability.call("http_request", {
        url = cfg.voice_tts_url,
        method = "POST",
        headers = headers,
        body = body,
        save_path = out_path,
        timeout_ms = 20000,
        max_file_bytes = 4194304,
    }, { source_cap = "voice_tts", max_output_bytes = 8192 })

    if not call_ok then
        print(TAG .. " http_request failed: " .. tostring(err) .. " (" .. tostring(out) .. ")")
        return nil, "TTS 网络错误"
    end

    local status = tostring(out):match("^HTTP (%d+)")
    if status ~= "200" then
        print(TAG .. " HTTP " .. tostring(status) .. ": " .. tostring(out))
        pcall(storage.remove, out_path)
        return nil, "TTS HTTP " .. tostring(status)
    end
    if not storage.exists(out_path) then
        print(TAG .. " response file missing")
        return nil, "TTS 响应缺失"
    end
    return out_path
end

-- text -> 音频文件。
-- out_base: 不含扩展名的落盘前缀 (generic 固定 .wav, provider 用 module.default_ext)。
-- 成功返回文件路径; 失败返回 nil + 简短原因 (中文, 供面板反馈)。
function M.synthesize(cfg, text, out_base, root_dir)
    local provider = cfg.voice_tts_provider or ""

    if provider == "" or provider == "generic" then
        if (cfg.voice_tts_url or "") == "" then
            return nil, "未配置 TTS"
        end
        return generic_synthesize(cfg, text, storage.join_path(root_dir, out_base .. ".wav"))
    end

    local ok, mod = pcall(require, "providers.tts_" .. provider)
    if not (ok and type(mod) == "table" and type(mod.synthesize) == "function") then
        print(TAG .. " unknown provider '" .. tostring(provider) .. "'")
        return nil, "TTS 配置无效"
    end

    local candidate = storage.join_path(root_dir, out_base .. "." .. (mod.default_ext or "wav"))
    local done, reason = mod.synthesize(cfg, text, candidate, root_dir)
    if done then
        return candidate
    end
    print(TAG .. " provider '" .. provider .. "' synthesize failed: " .. tostring(reason))
    return nil, reason or "语音合成失败"
end

-- 「边收边播」: 返回该 provider 的流式请求描述 (见 providers/tts_*.lua 的 stream_request),
-- 交由 audio.player:play_stream() 直接边收边解码边播放, 不落盘。
-- provider 不支持流式时返回 nil (调用方回退到 M.synthesize 的落盘路径)。
function M.stream_request(cfg, text)
    local provider = cfg.voice_tts_provider or ""
    if provider == "" or provider == "generic" then
        return nil
    end
    local ok, mod = pcall(require, "providers.tts_" .. provider)
    if ok and type(mod) == "table" and type(mod.stream_request) == "function" then
        return mod.stream_request(cfg, text)
    end
    return nil
end

return M
