-- 火山引擎(豆包语音) ASR provider —— 流式语音识别 2.0 (大模型流式)。
--
-- 鉴权: 新版控制台, 只需 X-Api-Key (无需旧版的 X-Api-App-Key / X-Api-Access-Key)。
-- 端点: wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async (双向流式优化版)
-- 传输: WebSocket 二进制帧 (火山 sauc 协议), 由 C 侧 cap_asr_stream 承载。
-- 契约: 会话式 —— 边说边发 PCM, 逐步返回累计文本; 收尾发末包得到最终文本。
--
-- 与旧的「录音文件识别极速版」(一次性 HTTP POST base64 WAV) 不同, 流式需要把麦克风
-- 采集到的 16-bit PCM 直接分片发送, 不再落盘 WAV。
--
-- 配置字段 (运行时 JSON, 网页「语音助手」页):
--   voice_asr_url         —— 留空用官方默认端点 (wss://.../bigmodel_async)
--   voice_asr_api_key     —— 新版控制台 API Key (必填)
--   voice_asr_resource_id —— 留空默认 volc.seedasr.sauc.duration (2.0 小时版)

local util = require("providers.util")

local M = {}

local TAG = "[voice_asr_volcano]"
local DEFAULT_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
local DEFAULT_RESOURCE_ID = "volc.seedasr.sauc.duration"
local CAP_NAME = "asr_stream"

-- ---------------------------------------------------------------------------
-- 调用 C 侧流式会话 cap: capability.call("asr_stream", {action=...}, opts)。
-- 成功返回 (head, rest): head 为 OK / TEXT / FINAL / ERR, rest 为随附文本。
-- 失败返回 nil, err。
-- ---------------------------------------------------------------------------
local function stream_call(input)
    local capability = require("capability")
    local ok, out, err = capability.call(CAP_NAME, input,
        { source_cap = "voice_asr", max_output_bytes = 8192 })
    if not ok then
        return nil, tostring(err) .. " (" .. tostring(out) .. ")"
    end
    local head, rest = tostring(out):match("^([^\n]*)\n?(.*)$")
    if not head or head == "" then
        return nil, "ASR 响应异常"
    end
    return head, rest
end

-- ---------------------------------------------------------------------------
-- 会话对象: send / poll / finish / abort, 由 voice_ptt.lua 驱动。
-- ---------------------------------------------------------------------------
local Session = {}
Session.__index = Session

-- 发送一片 16-bit PCM (原始字节)。成功返回 true; 失败返回 nil, reason。
function Session:send(chunk)
    if type(chunk) ~= "string" or chunk == "" then
        return true
    end
    local head, rest = stream_call({ action = "audio", pcm = util.base64_encode(chunk) })
    if head == "OK" then
        return true
    end
    return nil, (head == "ERR" and rest ~= "") and rest or "ASR 发送失败"
end

-- 取当前累计识别文本。返回 text(string, 可能为空); 失败返回 nil, reason。
function Session:poll()
    local head, rest = stream_call({ action = "poll" })
    if head == "TEXT" then
        return rest
    end
    if head == "ERR" then
        return nil, (rest ~= "" and rest) or "ASR 识别失败"
    end
    return nil, "ASR 响应异常"
end

-- 收尾: 发送末包并等待最终结果。返回 text; 失败返回 nil, reason。
function Session:finish(timeout_ms)
    local head, rest = stream_call({ action = "finish", timeout_ms = timeout_ms or 6000 })
    if head == "FINAL" then
        return rest
    end
    if head == "ERR" then
        return nil, (rest ~= "" and rest) or "ASR 识别失败"
    end
    return nil, "ASR 响应异常"
end

-- 放弃本次会话 (不发末包, 直接断开)。
function Session:abort()
    stream_call({ action = "abort" })
end

-- ---------------------------------------------------------------------------
-- 开启一个流式会话。cfg 为运行时配置表; info 为实际采集格式 (sample_rate/channels/bits)。
-- 返回 session 或 nil, reason (给面板反馈的中文原因)。
-- ---------------------------------------------------------------------------
function M.open(cfg, info)
    local api_key = cfg.voice_asr_api_key or ""
    if api_key == "" then
        print(TAG .. " missing X-Api-Key (voice_asr_api_key), abort")
        return nil, "未配置 ASR 密钥"
    end

    local url = cfg.voice_asr_url
    if not url or url == "" then
        url = DEFAULT_URL
    end
    local resource_id = cfg.voice_asr_resource_id
    if not resource_id or resource_id == "" then
        resource_id = DEFAULT_RESOURCE_ID
    end

    local rate = (info and info.sample_rate) or 16000
    local channels = (info and info.channels) or 1
    local bits = (info and info.bits) or 16
    if channels ~= 1 or rate ~= 16000 then
        print(string.format("%s WARN: streaming ASR expects 16kHz/mono, got %dHz/%dch",
                            TAG, rate, channels))
    end

    -- WebSocket 升级请求头 (原始字符串, 每行以 \r\n 结尾)。
    local headers = string.format(
        "X-Api-Key: %s\r\nX-Api-Resource-Id: %s\r\nX-Api-Connect-Id: %s\r\n",
        api_key, resource_id, util.uuid())

    -- full client request 负载: 声明音频格式 + 识别请求参数。
    -- enable_nonstream=true 开启二遍识别 (仅 bigmodel_async 支持), 提升准确率。
    local payload = string.format(
        '{"user":{"uid":"esp-claw"},'
        .. '"audio":{"format":"pcm","codec":"raw","rate":%d,"bits":%d,"channel":%d},'
        .. '"request":{"model_name":"bigmodel","enable_nonstream":true,'
        .. '"result_type":"full","show_utterances":true,"end_window_size":800}}',
        rate, bits, channels)

    print(string.format("%s open %s (resource=%s, %dHz/%dch/%dbit)",
                        TAG, url, resource_id, rate, channels, bits))

    local head, rest = stream_call({
        action = "start",
        url = url,
        headers = headers,
        payload_json = payload,
    })
    if head ~= "OK" then
        local reason = (head == "ERR" and rest ~= "") and rest or "ASR 连接失败"
        print(TAG .. " start failed: " .. tostring(reason))
        return nil, reason
    end

    return setmetatable({ url = url, rate = rate, channels = channels }, Session)
end

return M
