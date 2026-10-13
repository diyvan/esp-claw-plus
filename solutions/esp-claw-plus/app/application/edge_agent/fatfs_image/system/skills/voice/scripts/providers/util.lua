-- 语音 provider 公共工具: base64 编解码 / JSON 转义 / UUID / HTTP POST 封装。
--
-- 供 scripts/providers/*.lua 复用。cap_lua 会把「运行脚本自身所在目录」加入
-- package.path(<script_dir>/?.lua), 故 voice_ptt.lua / voice_reply.lua 里
-- require("providers.util") 会命中本文件。纯 Lua, 不依赖 C 侧新增绑定。

local M = {}

-- ---------------------------------------------------------------------------
-- Base64 编码 (纯 Lua)。
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
function M.base64_encode(data)
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

-- ---------------------------------------------------------------------------
-- Base64 解码 (流式累加, acc 保持在低位以免浮点精度丢失)。
-- ---------------------------------------------------------------------------
local B64_LOOKUP = {}
for i = 1, #B64 do
    B64_LOOKUP[B64:byte(i)] = i - 1
end

function M.base64_decode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end
    local out, group = {}, {}
    local gi, acc, nbits = 0, 0, 0
    for i = 1, #data do
        local b = data:byte(i)
        if b == 61 then -- '='
            break
        end
        local v = B64_LOOKUP[b]
        if v then
            acc = acc * 64 + v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                local shift = 2 ^ nbits
                gi = gi + 1
                group[gi] = string.char(math.floor(acc / shift) % 256)
                acc = acc % shift
                if gi >= 512 then
                    out[#out + 1] = table.concat(group)
                    group, gi = {}, 0
                end
            end
        end
    end
    if gi > 0 then
        out[#out + 1] = table.concat(group)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- JSON 字符串内容转义 (把回复文本安全嵌进 JSON)。
-- ---------------------------------------------------------------------------
function M.json_escape(s)
    return (tostring(s):gsub('[%c\\"]', function(c)
        if c == "\\" then return "\\\\" end
        if c == '"' then return '\\"' end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", string.byte(c))
    end))
end

-- ---------------------------------------------------------------------------
-- 随机 UUID (用于火山 X-Api-Request-Id)。首次调用时用 millis 播种。
-- ---------------------------------------------------------------------------
local seeded = false

function M.uuid()
    if not seeded then
        local ok, sys = pcall(require, "system")
        if ok and sys and sys.millis then
            math.randomseed(sys.millis() % 2147483647)
        end
        seeded = true
    end
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        local v
        if c == "x" then
            v = math.random(0, 15)
        else
            v = math.random(8, 11)
        end
        return string.format("%x", v)
    end))
end

-- ---------------------------------------------------------------------------
-- POST 一个请求。成功返回 status(number), body(string);
-- 失败返回 nil, err(string), detail(string)。
-- opts: url / headers / body / timeout_ms / max_body_bytes /
--       save_path / max_file_bytes / source_cap / max_output_bytes
-- 说明: 设置 save_path 时 cap_http_request 会把完整响应体落盘, body 仅保留摘要。
-- ---------------------------------------------------------------------------
function M.http_post(opts)
    local capability = require("capability")
    local call_ok, out, err = capability.call("http_request", {
        url = opts.url,
        method = "POST",
        headers = opts.headers,
        body = opts.body,
        timeout_ms = opts.timeout_ms or 20000,
        max_body_bytes = opts.max_body_bytes or 16384,
        save_path = opts.save_path,
        max_file_bytes = opts.max_file_bytes,
    }, { source_cap = opts.source_cap or "voice", max_output_bytes = opts.max_output_bytes or 32768 })

    if not call_ok then
        return nil, tostring(err), tostring(out)
    end
    local status, resp = tostring(out):match("^HTTP (%d+)\n(.*)$")
    if not status then
        return nil, "unexpected response", tostring(out)
    end
    return tonumber(status), resp
end

return M
