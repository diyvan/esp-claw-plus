-- 列出 Home Assistant MCP Server 暴露的工具 (供 ESP-Claw Agent 决策)。
--
-- 连接信息 (地址/令牌/开关) 来自运行时配置 /fatfs/ha_voice_runtime.json (ESP-Claw 网页配置页写出)。
-- ha_enabled=false 时直接返回, 不触达 Home Assistant。
-- 结果通过 print() 输出, cap_lua 会把 stdout 作为 lua_run_script 的工具结果回给 LLM。

local storage = require("storage")
local json = require("json")
local capability = require("capability")

local TAG = "[ha_list_tools]"
local RUNTIME_CONFIG = "ha_voice_runtime.json"
local DEFAULT_ENDPOINT = "mcp_server"

local function cfg_is_true(value)
    return value == true or value == "true"
end

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

-- 把 "http://host:8123/mcp_server" 拆成 origin + 路径。
-- MCP 客户端只保留 server_url 的 scheme://host:port, 路径由 endpoint 承载。
local function split_base(url)
    url = tostring(url or "")
    local scheme, rest = url:match("^(https?://)(.*)$")
    if not scheme or rest == "" then
        return nil, nil
    end
    local slash = rest:find("/")
    if not slash then
        return scheme .. rest, nil
    end
    local origin = scheme .. rest:sub(1, slash - 1)
    local path = rest:sub(slash + 1):gsub("^/+", ""):gsub("/+$", "")
    if path == "" then
        path = nil
    end
    return origin, path
end

local cfg = load_runtime_config()

if not cfg_is_true(cfg.ha_enabled) then
    print(TAG .. " Home Assistant disabled (ha_enabled=false); use ESP-Claw's own abilities instead.")
    return
end

local server_url, endpoint = split_base(cfg.ha_base_url)
if not server_url then
    print(TAG .. " ha_base_url is not configured; cannot reach Home Assistant.")
    return
end
endpoint = endpoint or DEFAULT_ENDPOINT

print(TAG .. " contacting HA MCP Server at " .. server_url .. "/" .. endpoint)

local ok, out, err = capability.call("mcp_list_tools", {
    server_url = server_url,
    endpoint = endpoint,
    bearer_token = cfg.ha_token or "",
}, { source_cap = "ha_control", max_output_bytes = 32768 })

if not ok then
    print(TAG .. " mcp_list_tools failed: " .. tostring(err) .. " (" .. tostring(out) .. ")")
    return
end

print(out or "(no tools)")
