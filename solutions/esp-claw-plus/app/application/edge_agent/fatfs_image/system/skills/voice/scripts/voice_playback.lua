-- 语音播放 owner: 把「开 DAC 输出 -> 惰性建 player -> 播(流式/落盘) -> poll 收尾 -> 打断/释放」
-- 收敛为唯一实现。
--
-- 现状: voice_ptt.lua (流式逐句流水线) 与 voice_reply.lua (整段落盘回退) 各自复制了一份逐字
-- 相同的播放代码 —— 取板级 DAC 参数、开 output、建 player、流式会话 (play_stream /
-- play_stream_append / play_stream_finish)、落盘 play(path)、poll 收尾、barge-in 时 stop、
-- close 释放。两处任一处打补丁都容易走偏 (例如只改一处, 另一处漏掉)。
--
-- 本模块是这些播放约定的唯一 owner: 调用方只关心「播什么」和「何时停」, 不再重复实现播放机制。
-- 设备级所有权 (谁真正持有扬声器、录音到来时如何撤销) 由 C 层 ha_voice_arbiter 的 SPK 方向裁决
-- (见 docs/adr/0003-audio-device-owner.md); 本模块是那次 C 层收敛在调用方侧的对应收敛
-- (见 docs/adr/0004-voice-round-and-playback-owner.md)。
--
-- 用法:
--   local playback = require("voice_playback")
--   local pb, reason = playback.open(cfg)      -- 开 output; 失败返回 nil, reason
--   if not pb then ... end
--   pb:play_stream(tts.stream_request(cfg, text))   -- 或 pb:play_file(path)
--   while pb:poll() do
--       if vc.interrupt_requested() then pb:stop() break end
--       delay.delay_ms(20)
--   end
--   pb:close()
--
-- 调用方与模块同目录 (/system/skills/voice/scripts), package.path 首位即脚本自身目录, 故
-- require("voice_playback") 直接命中, 无需改 package.path。

local audio = require("audio")
local bm = require("board_manager")

local DEFAULT_VOLUME = 80

local M = {}

local Handle = {}
Handle.__index = Handle

-- 惰性建 player: output 已开但还没播过时, 首次播放才建。player 创建失败返回 nil。
function Handle:_ensure_player()
    if self.player then
        return self.player
    end
    if not self.output then
        return nil
    end
    self.player = audio.player({ output = self.output })
    return self.player
end

-- 起一段流式播放 (建立会话)。req 来自 tts.stream_request。
-- 返回 true; 失败返回 false, reason。
function Handle:play_stream(req)
    if not req then
        return false, "无流式请求"
    end
    local player = self:_ensure_player()
    if not player then
        return false, "播放器创建失败"
    end
    if player:play_stream(req) then
        self.streaming = true
        return true
    end
    return false, "播放失败"
end

-- 追加一句到已建立的流式会话。会话未建立或追加失败均返回 false。
function Handle:play_stream_append(req)
    if not req then
        return false, "无流式请求"
    end
    if not (self.streaming and self.player) then
        return false, "会话未建立"
    end
    if self.player:play_stream_append(req) then
        return true
    end
    return false, "追加失败"
end

-- 声明流式会话不再追加 (队列排空后自然收尾)。
function Handle:play_stream_finish()
    if self.player then
        pcall(function() self.player:play_stream_finish() end)
    end
end

-- 播一个落盘音频文件。返回 true; 失败返回 false, reason。
function Handle:play_file(path)
    local player = self:_ensure_player()
    if not player then
        return false, "播放器创建失败"
    end
    if player:play(path) then
        return true
    end
    return false, "播放失败"
end

-- 是否处于已建立的流式会话中 (供调用方判断 append 是否可用)。
function Handle:stream_active()
    return self.streaming == true
end

-- 当前是否有活跃的播放管线 (player 尚在)。播完由 poll() 回收后变 false。
function Handle:idle()
    return self.player == nil
end

-- 推进播放; 返回是否仍在播放。播完自动关闭并回收 player (流式会话一并结束), 但保留 output,
-- 以便同一轮后续句子复用 (无需重开 DAC)。
function Handle:poll()
    if not self.player then
        return false
    end
    local st = self.player:poll()
    if st and st.running then
        return true
    end
    pcall(function() self.player:close() end)
    self.player = nil
    self.streaming = false
    return false
end

-- 停止当前播放 (barge-in / 放弃本轮)。player 保留, 由 poll() 或 close() 收尾。
function Handle:stop()
    if self.player then
        pcall(function() self.player:stop() end)
    end
end

-- 释放 player + output。幂等。
function Handle:close()
    if self.player then
        pcall(function() self.player:close() end)
        self.player = nil
    end
    if self.output then
        pcall(function() self.output:close() end)
        self.output = nil
    end
    self.streaming = false
end

-- 打开 DAC 播放 owner。仅开 output (player 惰性): 取板级 DAC 参数并以运行时配置的音量开。
-- cfg 为运行时配置表 (取 voice_volume); 可为 nil (用默认音量)。
-- 成功返回 handle; 失败返回 nil, reason (中文, 供面板反馈)。
function M.open(cfg)
    local codec, rate, channels, bits = bm.get_audio_codec_output_params("audio_dac")
    if not codec then
        return nil, "扬声器不可用"
    end
    local output = audio.new_output({ codec, rate, channels, bits,
        volume = tonumber(cfg and cfg.voice_volume) or DEFAULT_VOLUME })
    if not output then
        return nil, "扬声器占用"
    end
    return setmetatable({ output = output, player = nil, streaming = false }, Handle)
end

return M
