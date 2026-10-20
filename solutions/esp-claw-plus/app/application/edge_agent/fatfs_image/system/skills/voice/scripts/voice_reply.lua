-- 语音回复: 由路由规则 voice_reply_run_script 调用, Agent 的回复文本经 args.text 传入。
--
-- 链路: 路由规则匹配 claw_core / out_message (chat_id = "voice") -> 本脚本 -> TTS -> 播放
--
-- V1 说明: TTS 端点/密钥从 /fatfs/ha_voice_runtime.json 读取。
--   voice_tts_provider 为 "local": 走设备端 esp-tts 本地合成, 直接流式播放 (无落盘/无网络)。
--   voice_tts_provider 为空/generic: 走原通用端点 (voice_tts_url), 把回复文本 POST 给云 TTS,
--             响应音频经 save_path 落盘; 端点为空则直接放弃本次回复。
--   voice_tts_provider 非空: 加载 providers/tts_<provider>.lua 完成合成并落盘 (如 volcano 火山云,
--             新版控制台 X-Api-Key 鉴权), 详见对应 provider 模块。
--   落盘/流式播报统一走播放 owner voice_playback; 播放期间轮询打断标志 /fatfs/voice_interrupt,
--             命中即 pb:stop() (barge-in)。
--   需先把 TTS 域名加入「HTTP 白名单」(search_http_allowlist)。

local storage = require("storage")
local delay = require("delay")
local tts = require("voice_tts")
local vc = require("voice_common")
local playback = require("voice_playback")
local round = require("voice_round")

local TAG = "[voice_reply]"

local text = (args and args.text) or ""
print(TAG .. " agent reply (" .. tostring(#text) .. " chars): " .. text)

-- 本轮轮次号 (闸门): voice_ptt 每次开始录音都递增它。记下进入时的号, 之后若用户又发起
-- 新一轮录音, 本号即被视为过期 —— 本脚本据此在合成/播放前与播放中自行放弃, 不再插播过期
-- 语音 (跨脚本归属见 voice_round / docs/adr/0004-voice-round-and-playback-owner.md)。
local rid = round.id()

-- 本轮是否已被新一轮录音取代 (闸门)。起播前与播放中都要查。
local function superseded()
    return not round.is_current(rid)
end

-- 状态反馈 (voice_status.txt -> 面板「状态:」行 + 串口日志), 屏幕桥/配置桥/打断信道
-- 统一走 voice_common。状态是机器可读的 code (见 SKILL.md「状态码」), detail 只承载补充文本。
-- 本脚本每次回复单独执行一次, 没有常驻循环可做定时回收, 故失败态会一直留在面板上, 直到
-- 下一次语音交互 (PTT 开始录音时写 recording) 覆盖它。
local function set_status(code)
    vc.set_status(code)
    print(TAG .. " status -> " .. code)
end

-- 失败态: 写 error|<原因>。
local function set_error(reason)
    vc.set_status("error", reason)
    print(TAG .. " status -> error (" .. tostring(reason) .. ")")
end

vc.log_agent(text)
set_status("synthesizing")

local cfg = vc.load_runtime_config()
local TTS_URL = cfg.voice_tts_url or ""
local TTS_PROVIDER = cfg.voice_tts_provider or ""
local USE_GENERIC_TTS = (TTS_PROVIDER == "" or TTS_PROVIDER == "generic")

if USE_GENERIC_TTS and TTS_URL == "" then
    print(TAG .. " TTS: no endpoint configured, skipping reply playback")
    set_error("未配置 TTS")
    return
end

-- 播放 owner (voice_playback): 统一开 DAC 输出、建 player、流式/落盘播报与收尾。
-- player 惰性创建, 故「扬声器不可用/占用」在此返回, 「播放器创建失败」在首次播放时返回。
local pb, pb_reason = playback.open(cfg)
if not pb then
    print(TAG .. " open audio output failed, skip playback: " .. tostring(pb_reason))
    set_error(pb_reason or "扬声器不可用")
    return
end

-- 播放前清掉可能残留的打断标志, 避免上一条过早停止本次播放。
vc.clear_interrupt()

if tts.is_local(cfg) then
    -- 本地引擎 (esp-tts): 无落盘中间产物, 直接流式合成播放。
    -- 单段文本: 建会话后立即声明不再追加, 队列排空即自然收尾 (EOF)。
    if superseded() then
        print(TAG .. " round #" .. tostring(rid) .. " superseded before playback -> skip")
        pb:close()
        return
    end
    local ok_stream, serr = pb:play_stream(tts.stream_request(cfg, text))
    if not ok_stream then
        print(TAG .. " play_stream failed: " .. tostring(serr))
        set_error(serr or "播放失败")
        pb:close()
        return
    end
    pb:play_stream_finish()
else
    -- 合成: 统一走共享模块 voice_tts (generic 端点或 provider 分派)。
    local save_path, tts_error = tts.synthesize(cfg, text, "voice_reply", storage.get_root_dir())
    if not save_path then
        set_error(tts_error or "语音合成失败")
        pb:close()
        return
    end
    -- 合成是网络调用, 可能耗时数秒; 期间用户若已发起新一轮录音, 本轮过期 -> 不起播。
    if superseded() then
        print(TAG .. " round #" .. tostring(rid) .. " superseded during synthesis -> skip")
        pb:close()
        return
    end
    local ok_play, perr = pb:play_file(save_path)
    if not ok_play then
        print(TAG .. " play failed: " .. save_path .. " (" .. tostring(perr) .. ")")
        set_error(perr or "播放失败")
        pb:close()
        return
    end
    print(TAG .. " playback started: " .. save_path)
end

set_status("speaking")

-- 轮询到播放结束; 期间若用户开始说话 (barge-in) 或本轮已被新一轮取代, 立即停止。
local interrupted = false
while pb:poll() do
    if not round.is_current(rid) or vc.interrupt_requested() then
        print(TAG .. " barge-in / superseded -> stop playback")
        pb:stop()
        vc.clear_interrupt()
        interrupted = true
        break
    end
    delay.delay_ms(20)
end

pb:close()
-- 被打断时不写状态: 此时 voice_ptt.lua 已开始录音并写了 recording, 别把它覆盖掉。
if not interrupted then
    set_status("idle")
end
print(TAG .. " playback done")
