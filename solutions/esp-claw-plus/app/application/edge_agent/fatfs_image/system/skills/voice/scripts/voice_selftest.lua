-- 语音自检: 录音 -> 回放, 用于在不按 BOOT 键的情况下验证麦克风/扬声器通路。
--
-- 手动运行 (串口 REPL):
--   lua --run --path /system/skills/voice/scripts/voice_selftest.lua
--
-- 说明: 先录制 RECORD_MS 毫秒到 /fatfs/voice_selftest.wav, 再原样回放,
-- 用于确认 ES8311 输入(ADC)/输出(DAC)通路正常。录音/回放失败会打印原因。

local bm = require("board_manager")
local audio = require("audio")
local storage = require("storage")

local TAG = "[voice_selftest]"
local RECORD_MS = 3000

local function record(path)
    local codec, rate, channels, bits = bm.get_audio_codec_input_params("audio_adc")
    if not codec then
        print(TAG .. " get_audio_codec_input_params(audio_adc) failed")
        return nil
    end

    local input = audio.new_input({ codec, rate, channels, bits, volume = 80 })
    if not input then
        print(TAG .. " open audio input failed")
        return nil
    end

    local recorder = audio.recorder({ input = input })
    local ok, info, err = pcall(function()
        return recorder:record(path, { duration_ms = RECORD_MS })
    end)

    recorder:close()
    input:close()

    if not ok then
        print(TAG .. " record error: " .. tostring(info))
        return nil
    end
    if not info then
        print(TAG .. " record failed: " .. tostring(err))
        return nil
    end

    print(string.format("%s recorded %s bytes=%s encoding=%s",
        TAG, tostring(info.path), tostring(info.bytes), tostring(info.encoding)))
    return info.path
end

local function play(path)
    local codec, rate, channels, bits = bm.get_audio_codec_output_params("audio_dac")
    if not codec then
        print(TAG .. " get_audio_codec_output_params(audio_dac) failed")
        return
    end

    local output = audio.new_output({ codec, rate, channels, bits, volume = 80 })
    if not output then
        print(TAG .. " open audio output failed")
        return
    end

    local player = audio.player({ output = output })
    local ok, err = pcall(function()
        return player:play(path, { wait = true })
    end)
    if not ok then
        print(TAG .. " play error: " .. tostring(err))
    else
        print(TAG .. " playback done: " .. tostring(path))
    end

    player:close()
    output:close()
end

local path = storage.join_path(storage.get_root_dir(), "voice_selftest.wav")
print(TAG .. " start, recording " .. RECORD_MS .. "ms (请对着麦克风说话)")
local rec_path = record(path)
if rec_path then
    play(rec_path)

    -- 自清理: /fatfs 分区仅 3MB, 不留临时 wav 残留。
    local ok, err = pcall(storage.remove, rec_path)
    if ok then
        print(TAG .. " cleaned up " .. rec_path)
    else
        print(TAG .. " cleanup failed: " .. tostring(err))
    end
else
    print(TAG .. " FAILED: no recording produced")
end