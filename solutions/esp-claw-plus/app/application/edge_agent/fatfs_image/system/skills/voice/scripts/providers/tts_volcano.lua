-- 火山引擎(豆包语音) TTS provider —— 大模型语音合成 V3 单向流式 HTTP。
--
-- 鉴权: 新版控制台, 只需 X-Api-Key (旧版为 X-Api-App-Id + X-Api-Access-Key)。
-- 端点: POST https://openspeech.bytedance.com/api/v3/tts/unidirectional
-- 契约: 服务端以 HTTP chunked 流式返回多个 JSON, 音频为 base64 分块:
--         {"code":0,"message":"","data":"<base64 音频>"} ... {"code":20000000,"data":null}
--       参考文档明确「音频数据是 base64, 需解析后拼接到字节数组」——即逐块解码后拼接字节,
--       而不是把 base64 字符串首尾相连 (分块各自补齐, 直接拼接会损坏)。
-- 实现: cap_http_request 不暴露流式回调, 故先用 save_path 把整个响应体落盘, 再在 Lua 内
--       提取所有 "data":"..." 分块 -> 逐块 base64 解码 -> 拼接 -> 写出音频文件。
-- 注意: TTS 域名需先加入「HTTP 白名单」。
--
-- 配置字段 (运行时 JSON, 网页「语音助手」页):
--   voice_tts_url         —— 留空用官方默认端点
--   voice_tts_api_key     —— 新版控制台 API Key (必填)
--   voice_tts_resource_id —— 留空默认 seed-tts-2.0 (豆包语音合成模型 2.0)
--   voice_tts_speaker     —— 发音人, 留空默认 zh_female_vv_uranus_bigtts (Vivi 2.0)

local storage = require("storage")
local util = require("providers.util")

local M = {}

local TAG = "[voice_tts_volcano]"
local DEFAULT_URL = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
local DEFAULT_RESOURCE_ID = "seed-tts-2.0"
local DEFAULT_SPEAKER = "zh_female_vv_uranus_bigtts"
local DEFAULT_FORMAT = "mp3"
local DEFAULT_SAMPLE_RATE = 24000

-- 音频落盘扩展名 (esp_audio simple player 依扩展名选解码器)。
M.default_ext = DEFAULT_FORMAT

-- 从流式响应体里提取所有 base64 音频分块。
local function extract_audio_chunks(stream)
    local chunks = {}
    local pos = 1
    while true do
        local s, e, val = stream:find('"data"%s*:%s*"([A-Za-z0-9+/=]*)"', pos)
        if not s then
            break
        end
        if val and val ~= "" then
            chunks[#chunks + 1] = val
        end
        pos = e + 1
    end
    return chunks
end

-- 合成并把音频写入 out_path。成功返回 true, 失败返回 false + 简短失败原因 (中文, 供面板反馈)。
-- root_dir: storage.get_root_dir(), 用于放响应的临时落盘文件。
function M.synthesize(cfg, text, out_path, root_dir)
    local api_key = cfg.voice_tts_api_key or ""
    if api_key == "" then
        print(TAG .. " missing X-Api-Key (voice_tts_api_key), abort")
        return false, "未配置 TTS 密钥"
    end

    local url = cfg.voice_tts_url
    if not url or url == "" then
        url = DEFAULT_URL
    end
    local resource_id = cfg.voice_tts_resource_id
    if not resource_id or resource_id == "" then
        resource_id = DEFAULT_RESOURCE_ID
    end
    local speaker = cfg.voice_tts_speaker
    if not speaker or speaker == "" then
        speaker = DEFAULT_SPEAKER
    end

    local body = string.format(
        '{"user":{"uid":"esp-claw"},"req_params":{"text":"%s","speaker":"%s","audio_params":{"format":"%s","sample_rate":%d}}}',
        util.json_escape(text), util.json_escape(speaker), DEFAULT_FORMAT, DEFAULT_SAMPLE_RATE)

    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Api-Key"] = api_key,
        ["X-Api-Resource-Id"] = resource_id,
        ["X-Api-Request-Id"] = util.uuid(),
    }

    local raw_path = storage.join_path(root_dir, "voice_tts_raw.json")

    print(string.format("%s request %d chars -> %s (resource=%s speaker=%s)",
                        TAG, #text, url, resource_id, speaker))

    local status, resp, err = util.http_post({
        url = url,
        headers = headers,
        body = body,
        save_path = raw_path,
        timeout_ms = 20000,
        max_file_bytes = 4194304,
        max_body_bytes = 8192,
        source_cap = "voice_tts",
        max_output_bytes = 8192,
    })

    if not status then
        print(TAG .. " request failed: " .. tostring(err) .. " (" .. tostring(resp) .. ")")
        return false, "TTS 网络错误"
    end
    if status ~= 200 then
        print(TAG .. " HTTP " .. tostring(status) .. ": " .. tostring(resp))
        pcall(storage.remove, raw_path)
        return false, "TTS HTTP " .. tostring(status)
    end
    if not storage.exists(raw_path) then
        print(TAG .. " raw response missing")
        return false, "TTS 响应缺失"
    end

    local read_ok, stream = pcall(storage.read_file, raw_path)
    pcall(storage.remove, raw_path)
    if not read_ok or type(stream) ~= "string" or stream == "" then
        print(TAG .. " read raw response failed")
        return false, "TTS 响应读取失败"
    end

    local chunks = extract_audio_chunks(stream)
    if #chunks == 0 then
        print(TAG .. " no audio data in response: " .. tostring(resp))
        return false, "TTS 无音频返回"
    end

    local parts = {}
    for i = 1, #chunks do
        parts[i] = util.base64_decode(chunks[i])
    end
    local audio = table.concat(parts)
    if audio == "" then
        print(TAG .. " decoded audio empty")
        return false, "TTS 音频解码失败"
    end

    local write_ok = pcall(storage.write_file, out_path, audio)
    if not write_ok then
        print(TAG .. " write audio failed: " .. tostring(out_path))
        return false, "TTS 写盘失败"
    end
    print(string.format("%s wrote %d bytes -> %s", TAG, #audio, out_path))
    return true
end

return M
