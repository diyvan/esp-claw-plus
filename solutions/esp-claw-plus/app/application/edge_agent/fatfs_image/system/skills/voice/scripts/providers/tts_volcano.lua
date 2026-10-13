-- 火山引擎(豆包语音) TTS provider —— 大模型语音合成 V3 单向流式 HTTP。
--
-- 鉴权: 新版控制台, 只需 X-Api-Key (旧版为 X-Api-App-Id + X-Api-Access-Key)。
-- 端点: POST https://openspeech.bytedance.com/api/v3/tts/unidirectional
-- 契约: 服务端以 HTTP chunked 流式返回多个 JSON, 音频为 base64 分块:
--         {"code":0,"message":"","data":"<base64 音频>"} ... {"code":20000000,"data":null}
--       参考文档明确「音频数据是 base64, 需解析后拼接到字节数组」——即逐块解码后拼接字节,
--       而不是把 base64 字符串首尾相连 (分块各自补齐, 直接拼接会损坏)。
-- 实现: 借助 cap_http_request 的 decode_base64_field 模式, 由 C 侧在收到 HTTP 分块时
--       增量扫描 "data" 字段并逐块 base64 解码, 直接把音频字节写入 out_path。相比旧的
--       「整包落盘 -> 读回 Lua -> 正则提取 -> 纯 Lua 解码 -> 再写盘」省掉一次大文件
--       FATFS 往返与全部 Lua 侧解码开销。
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
-- 默认 16kHz: 相比 24kHz 可显著减小音频体积/下载时长与解码开销, 语音播报场景足够。
local DEFAULT_SAMPLE_RATE = 16000

-- 音频落盘扩展名 (esp_audio simple player 依扩展名选解码器)。
M.default_ext = DEFAULT_FORMAT

-- 合成并把音频写入 out_path。成功返回 true, 失败返回 false + 简短失败原因 (中文, 供面板反馈)。
-- root_dir: storage.get_root_dir() (保留参数以兼容 provider 统一签名)。
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

    local sample_rate = DEFAULT_SAMPLE_RATE

    local body = string.format(
        '{"user":{"uid":"esp-claw"},"req_params":{"text":"%s","speaker":"%s","audio_params":{"format":"%s","sample_rate":%d}}}',
        util.json_escape(text), util.json_escape(speaker), DEFAULT_FORMAT, sample_rate)

    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Api-Key"] = api_key,
        ["X-Api-Resource-Id"] = resource_id,
        ["X-Api-Request-Id"] = util.uuid(),
    }

    print(string.format("%s request %d chars -> %s (resource=%s speaker=%s)",
                        TAG, #text, url, resource_id, speaker))

    local status, resp, err = util.http_post({
        url = url,
        headers = headers,
        body = body,
        save_path = out_path,
        decode_base64_field = "data",
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
        pcall(storage.remove, out_path)
        return false, "TTS HTTP " .. tostring(status)
    end
    if not storage.exists(out_path) then
        print(TAG .. " decoded audio missing: " .. tostring(resp))
        return false, "TTS 无音频返回"
    end

    local size = nil
    if storage.stat then
        local st = storage.stat(out_path)
        if type(st) == "table" then
            size = st.size
        end
    end
    print(string.format("%s wrote audio -> %s%s", TAG, out_path,
                        size and (" (" .. tostring(size) .. " bytes)") or ""))
    return true
end

-- 构造「边收边播」所需的流式请求描述 (不落盘)。
-- 返回 { url=<string>, headers=<table {Name=Value}>, body=<string>, timeout_ms=<int> };
-- 该 provider 不支持流式或配置缺失时返回 nil + 简短原因。
-- 由 audio.player:play_stream() 直接发起请求: C 侧增量解析 data 字段并 base64 解码,
-- 解码后的 MP3 字节经 raw:// 输入回调喂给解码器 -> 省掉「整段合成 + 落盘 + 回读」的延迟。
function M.stream_request(cfg, text)
    local api_key = cfg.voice_tts_api_key or ""
    if api_key == "" then
        return nil, "未配置 TTS 密钥"
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

    return {
        url = url,
        headers = {
            ["X-Api-Key"] = api_key,
            ["X-Api-Resource-Id"] = resource_id,
            ["X-Api-Request-Id"] = util.uuid(),
        },
        body = body,
        timeout_ms = 20000,
    }
end

return M
