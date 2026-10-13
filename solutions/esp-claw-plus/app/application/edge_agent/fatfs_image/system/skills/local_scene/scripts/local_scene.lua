-- 本地场景 (离线联动): 设置并持久化本板场景状态, 不依赖 LLM / 网络 / Home Assistant。
--
-- 触发方式:
--   1) 路由规则 startup_local_scene  : 开机时 args.scene="boot", 读回上次场景 (缺失则初始化 home)。
--   2) 路由规则 local_scene_command  : 文本 "scene:home" / "scene:away" / "scene:night" 时
--      以 args.scene="{{match.remainder}}" 触发; consume_on_match=true -> 不再进入 LLM。
--
-- 产物:
--   /fatfs/local_scene_state.json  权威状态 (scene / updated_ms / source)
--   /fatfs/local_scene.txt         供设备端界面显示的纯文本
--
-- 说明: 本脚本只做确定性、本地可见的动作 (写状态 + 写屏文本)。真实部署可在 apply_scene()
--       里进一步映射到本板硬件 (GPIO / 继电器 / 指示灯等), 路由规则无需改动。

local storage = require("storage")
local json = require("json")
local system = require("system")

local TAG = "[local_scene]"

local STATE_FILE = "local_scene_state.json"
local TEXT_FILE = "local_scene.txt"

-- 允许的场景及其中文标签; 未收录的场景名会被拒绝 (避免误触发)。
local SCENE_LABELS = {
    home = "回家",
    away = "离家",
    night = "夜间",
}

local DEFAULT_SCENE = "home"

local function root(name)
    return storage.join_path(storage.get_root_dir(), name)
end

local function write_file(name, content)
    local ok, err = pcall(storage.write_file, root(name), content)
    if not ok then
        print(TAG .. " write " .. name .. " failed: " .. tostring(err))
    end
    return ok
end

local function read_state()
    local path = root(STATE_FILE)
    if not storage.exists(path) then
        return {}
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        return {}
    end
    local decode_ok, data = pcall(json.decode, content)
    if not decode_ok or type(data) ~= "table" then
        print(TAG .. " state decode failed")
        return {}
    end
    return data
end

-- 确定性本地动作: 目前是「写权威状态 + 写屏文本」。
-- 真实部署可在此把场景映射到本板硬件 (GPIO/继电器/指示灯等)。
local function apply_scene(scene, source)
    local state = {
        scene = scene,
        updated_ms = system.millis(),
        source = source or "manual",
    }
    write_file(STATE_FILE, json.encode(state))
    write_file(TEXT_FILE, "场景: " .. (SCENE_LABELS[scene] or scene))
    print(TAG .. " scene applied: " .. scene .. " (source=" .. tostring(source) .. ")")
end

local raw = (type(args) == "table") and args or {}
local scene = raw.scene
if type(scene) == "string" then
    scene = scene:gsub("%s+", "")
end

if scene == "boot" or scene == nil or scene == "" then
    -- 开机 / 无参数: 读回上次场景, 缺失则用默认值。
    local state = read_state()
    local restored = state.scene
    if type(restored) ~= "string" or SCENE_LABELS[restored] == nil then
        restored = DEFAULT_SCENE
    end
    apply_scene(restored, scene == "boot" and "boot" or "restore")
    return
end

if SCENE_LABELS[scene] == nil then
    print(TAG .. " unknown scene '" .. tostring(scene) .. "' (allowed: home/away/night)")
    return
end

apply_scene(scene, "command")
