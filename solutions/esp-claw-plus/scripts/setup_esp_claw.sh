#!/usr/bin/env bash
# 获取 esp-claw 上游源码, 叠加本板板级适配与 IDF v6 兼容补丁, 并生成板级配置。
#
# 用法:
#   solutions/ha_ai_panel/scripts/setup_esp_claw.sh
#
# 前置:
#   1. 已 export ESP-IDF (本仓库为 v6.1: source /Users/diyvan/.espressif/tools/activate_idf_v6.1.sh)
#   2. 已安装 board manager 辅助包: pip install esp-bmgr-assist
#
# 注意: esp-claw 的构建脚本会就地修改 ESP-IDF 安装目录(~/.espressif/*/esp-idf),
#       运行环境需允许写入该路径(否则 CMake 配置阶段会报 touching file 失败)。
set -euo pipefail

ESP_CLAW_TAG="v0.1.0"
BOARD="waveshare_esp32_p4_wifi6_touch_lcd_3_5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTION_DIR/../.." && pwd)"

SRC_DIR="$SOLUTION_DIR/esp-claw"
BOARD_DST="$SRC_DIR/application/edge_agent/boards/waveshare/$BOARD"
PATCH="$SOLUTION_DIR/patches/esp-claw-idf6.patch"
PANEL_PATCH="$SOLUTION_DIR/patches/esp-claw-m1-panel.patch"
HA_PATCH="$SOLUTION_DIR/patches/esp-claw-ha-config.patch"
DISPLAY_PATCH="$SOLUTION_DIR/patches/esp-claw-display-owner.patch"
SR_PATCH="$SOLUTION_DIR/patches/esp-claw-esp-sr.patch"
VOICE_WAKE_PATCH="$SOLUTION_DIR/patches/esp-claw-voice-wake.patch"
AUDIO_OWNER_PATCH="$SOLUTION_DIR/patches/esp-claw-audio-owner.patch"
STACK_PATCH="$SOLUTION_DIR/patches/esp-claw-p4-task-stack-internal.patch"
HA_VOICE_PATCH="$SOLUTION_DIR/patches/esp-claw-ha-voice-config.patch"
PANEL_SETTINGS_PATCH="$SOLUTION_DIR/patches/esp-claw-panel-settings.patch"
HA_MCP_PATCH="$SOLUTION_DIR/patches/esp-claw-ha-mcp-token.patch"
ASR_STREAM_PATCH="$SOLUTION_DIR/patches/esp-claw-asr-stream.patch"
VOICE_LATENCY_PATCH="$SOLUTION_DIR/patches/esp-claw-voice-latency.patch"
LLM_STREAM_PATCH="$SOLUTION_DIR/patches/esp-claw-llm-stream.patch"
TTS_STREAM_PATCH="$SOLUTION_DIR/patches/esp-claw-tts-stream.patch"
TTS_STREAM_PIPELINE_PATCH="$SOLUTION_DIR/patches/esp-claw-tts-stream-pipeline.patch"
DIRECT_REPLY_PATCH="$SOLUTION_DIR/patches/esp-claw-direct-reply.patch"
TTS_STREAM_CONFIG_PATCH="$SOLUTION_DIR/patches/esp-claw-tts-stream-config.patch"
HTTP_REUSE_PATCH="$SOLUTION_DIR/patches/esp-claw-http-reuse.patch"
TTS_LOCAL_PATCH="$SOLUTION_DIR/patches/esp-claw-tts-local.patch"
TTS_SB_STATIC_PATCH="$SOLUTION_DIR/patches/esp-claw-tts-stream-sb-static.patch"
VOICE_SEND_MODE_PATCH="$SOLUTION_DIR/patches/esp-claw-voice-send-mode.patch"
APP_OVERLAY="$SOLUTION_DIR/app/application/edge_agent/main"
FS_OVERLAY="$SOLUTION_DIR/app/application/edge_agent/fatfs_image"
UI_OVERLAY="$SOLUTION_DIR/app/application/edge_agent/components/http_server/frontend_source"

# eim 方式激活 IDF 时 idf.py 只是当前 shell 的函数, 子进程不可见, 故做兜底
run_idf() {
    if command -v idf.py >/dev/null 2>&1; then
        idf.py "$@"
    elif [ -n "${IDF_PYTHON_ENV_PATH:-}" ] && [ -n "${IDF_PATH:-}" ]; then
        "$IDF_PYTHON_ENV_PATH/bin/python" "$IDF_PATH/tools/idf.py" "$@"
    else
        echo "错误: 未找到 idf.py, 请先 source ESP-IDF v6.1 激活脚本" >&2
        exit 1
    fi
}

if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> 克隆 esp-claw $ESP_CLAW_TAG"
    git clone --depth 1 --branch "$ESP_CLAW_TAG" \
        https://github.com/espressif/esp-claw "$SRC_DIR"
fi

echo "==> 应用 IDF v6 兼容补丁"
if git -C "$SRC_DIR" apply --check "$PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 叠加本板板级适配"
mkdir -p "$BOARD_DST"
cp "$SOLUTION_DIR/boards/$BOARD"/* "$BOARD_DST"/

echo "==> 叠加应用层 LVGL 面板 (M1)"
if git -C "$SRC_DIR" apply --check "$PANEL_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$PANEL_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$PANEL_PATCH" 2>/dev/null; then
    echo "    面板补丁已应用, 跳过"
else
    echo "    错误: 面板补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
mkdir -p "$SRC_DIR/application/edge_agent/main"
cp "$APP_OVERLAY"/* "$SRC_DIR/application/edge_agent/main/"
echo "    注意: 新增 main/*.c 后首次构建需先 idf.py reconfigure(CMake glob 缓存)"

echo "==> 叠加 Home Assistant 配置项 (M1 设置页)"
if git -C "$SRC_DIR" apply --check "$HA_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$HA_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$HA_PATCH" 2>/dev/null; then
    echo "    HA 配置补丁已应用, 跳过"
else
    echo "    错误: HA 配置补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 修复 Lua display 模块误释放屏幕 (M1 面板独占显示)"
if git -C "$SRC_DIR" apply --check "$DISPLAY_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$DISPLAY_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$DISPLAY_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 接入 esp-sr 本地唤醒词 (依赖 + model 分区)"
if git -C "$SRC_DIR" apply --check "$SR_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$SR_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$SR_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 接入唤醒词监听 + 麦克风仲裁 (ha_voice_arbiter 组件 + lua audio 分时复用)"
if git -C "$SRC_DIR" apply --check "$VOICE_WAKE_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$VOICE_WAKE_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$VOICE_WAKE_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 音频设备所有权 (ADC/DAC 共用 codec: 录音撤销播放 + 排空, codec 引用计数, 48k 采集降采样)"
if git -C "$SRC_DIR" apply --check "$AUDIO_OWNER_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$AUDIO_OWNER_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$AUDIO_OWNER_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: ha_voice_arbiter 增 SPK 方向 (撤销 + 等待排空); lua_module_audio 增 codec 引用计数、"
echo "          采集恒定 48k + C 侧降采样 (asr_rate/asr_channels); 播放侧轮询 spk_revoked 协作停机。"

echo "==> 强制任务栈走内部 RAM (P4 flash/PSRAM 共享 MSPI, 避免 flash 事务 assert)"
if git -C "$SRC_DIR" apply --check "$STACK_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$STACK_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$STACK_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 叠加语音技能 (写入 system 分区: /system/skills/voice)"
mkdir -p "$SRC_DIR/application/edge_agent/fatfs_image"
cp -R "$FS_OVERLAY"/. "$SRC_DIR/application/edge_agent/fatfs_image/"

echo "==> 叠加 HA 启用开关 + 语音配置项 (C 侧 app_config / http_server)"
if git -C "$SRC_DIR" apply --check "$HA_VOICE_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$HA_VOICE_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$HA_VOICE_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 叠加面板设置项 (音量/亮度持久化: app_config 新增 voice_volume/lcd_brightness)"
if git -C "$SRC_DIR" apply --check "$PANEL_SETTINGS_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$PANEL_SETTINGS_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$PANEL_SETTINGS_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 叠加 Web 配置前端 (HA + 语音助手页, 含已构建 dist)"
cp -R "$UI_OVERLAY"/. "$SRC_DIR/application/edge_agent/components/http_server/frontend_source/"

echo "==> MCP client 支持 bearer_token (HA 长令牌认证, M2)"
if git -C "$SRC_DIR" apply --check "$HA_MCP_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$HA_MCP_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$HA_MCP_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 新增流式语音识别能力 cap_asr_stream (WebSocket + 火山 sauc 协议)"
if git -C "$SRC_DIR" apply --check "$ASR_STREAM_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$ASR_STREAM_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$ASR_STREAM_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    注意: 新增 cap_asr_stream 组件后首次构建需先 idf.py reconfigure(idf_component.yml 缓存)"

echo "==> 语音链路延迟优化 (voice 渠道提示词限长 + HTTP base64 字段流式解码下沉)"
if git -C "$SRC_DIR" apply --check "$VOICE_LATENCY_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$VOICE_LATENCY_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$VOICE_LATENCY_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 语音链路延迟优化 (LLM 流式 SSE + voice 渠道 delta 落盘桥接)"
if git -C "$SRC_DIR" apply --check "$LLM_STREAM_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$LLM_STREAM_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$LLM_STREAM_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi

echo "==> 语音链路延迟优化 (TTS 真·边收边播: cap_tts_stream + audio.player raw:// 流式输入)"
if git -C "$SRC_DIR" apply --check "$TTS_STREAM_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$TTS_STREAM_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$TTS_STREAM_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    注意: 新增 cap_tts_stream 组件后首次构建需先 idf.py reconfigure(idf_component.yml 缓存)"
echo "    开关: 运行时配置 voice_tts_strm (默认 false), 网页面板『语音助手』页可切换"

echo "==> 语音链路延迟优化 (TTS 分句流水线: 多句音频无缝拼接, 消除句间静音断层)"
if git -C "$SRC_DIR" apply --check "$TTS_STREAM_PIPELINE_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$TTS_STREAM_PIPELINE_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$TTS_STREAM_PIPELINE_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: cap_tts_stream 支持 begin/append/finish 段队列, 同会话环形缓冲追加解码音频;"
echo "          audio.player 新增 play_stream_append/play_stream_finish; voice_ptt 边切句边入流"

echo "==> 语音回复模式开关 (direct 单轮直答 / agent 智能体; 设备面板与网页面板可切换)"
if git -C "$SRC_DIR" apply --check "$DIRECT_REPLY_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$DIRECT_REPLY_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$DIRECT_REPLY_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: 模式存 NVS voice_reply_mode (默认 agent); direct 时语音请求改走 chat_id=voice_llm"

echo "==> 边收边播开关提升为运行时配置 (voice_tts_stream 存 NVS, 网页面板可切换)"
if git -C "$SRC_DIR" apply --check "$TTS_STREAM_CONFIG_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$TTS_STREAM_CONFIG_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$TTS_STREAM_CONFIG_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: 开关存 NVS voice_tts_strm (默认 false); 网页面板『语音助手』页可切换"

echo "==> 语音链路延迟优化 (HTTP 连接复用池: 多轮 LLM 往返 / 非流式 TTS 复用 TCP+TLS)"
if git -C "$SRC_DIR" apply --check "$HTTP_REUSE_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$HTTP_REUSE_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$HTTP_REUSE_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: 启用 CONFIG_HTTP_REUSE_ENABLE=y (上游因 issue #101 默认关闭; 本板 P4 可接受),"
echo "          caller 侧 opt-in (keep_alive_enable): LLM transport + cap_http_request;"
echo "          cap_tts_stream 走 open/read 不走 perform, 不入池"
echo "    注意: 改动 sdkconfig.defaults 后需重新生成 sdkconfig (删 application/edge_agent/sdkconfig 或重跑 bmgr),"
echo "          且 LINK_OPTIONS 变更后需 idf.py reconfigure"

echo "==> 设备端本地 TTS (esp-tts 中文, 压低『LLM 首字 → 首字播放』延迟)"
if git -C "$SRC_DIR" apply --check "$TTS_LOCAL_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$TTS_LOCAL_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$TTS_LOCAL_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: cap_tts_stream 增本地模式 (mmap voice_data 分区 + esp_tts_voice_xiaole + 16kHz/单声道 PCM),"
echo "          lua audio.player 请求带 local=true 时走 raw://tts/stream.pcm; 语音设置页『TTS 引擎』可选本地/云。"
echo "    注意: 分区表新增 voice_data 且 ota_0 扩至 5MB(去掉 ota_1), 首次构建需 idf.py reconfigure;"
echo "          语音数据由 esptool_py_flash_to_partition 随 idf.py flash 一起烧录, 无需单独烧录。"

echo "==> TTS 边收边播环形缓冲改静态常驻 (修复 e2e 收尾偶发 tlsf_free double free 崩溃)"
if git -C "$SRC_DIR" apply --check "$TTS_SB_STATIC_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$TTS_SB_STATIC_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$TTS_SB_STATIC_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: cap_tts_stream 环形缓冲由每次会话 heap 分配/释放 48KB PSRAM 改为启动期静态常驻"
echo "          (EXT_RAM_BSS_ATTR 落 PSRAM bss + xStreamBufferCreateStatic), 会话间仅 xStreamBufferReset 清空;"
echo "          读取/重置加静态互斥锁串行化。消除 player:close() 收尾时偶发的"
echo "          tlsf_free 'block already marked as free' 崩溃 (该 48KB 块被堆上其他活动波及)。"

echo "==> 语音发送模式开关 (voice_send_mode: auto 识别即发送 / manual 按 BOOT 确认)"
if git -C "$SRC_DIR" apply --check "$VOICE_SEND_MODE_PATCH" 2>/dev/null; then
    git -C "$SRC_DIR" apply "$VOICE_SEND_MODE_PATCH"
elif git -C "$SRC_DIR" apply --reverse --check "$VOICE_SEND_MODE_PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
else
    echo "    错误: 补丁无法应用, 请确认 esp-claw 版本为 $ESP_CLAW_TAG" >&2
    exit 1
fi
echo "    说明: app_config 增 voice_send_mode (NVS voice_send_md, 默认 auto) 并下发运行 JSON;"
echo "          网页面板『语音助手』页可切换; manual 时识别完成后等 BOOT 轻点确认 (按住重录, 15s 超时作废)。"

echo "==> 生成 board manager 配置"
cd "$SRC_DIR/application/edge_agent"
run_idf bmgr -c ./boards -b "$BOARD"

echo
echo "完成。构建:"
echo "  cd $SRC_DIR/application/edge_agent && idf.py build"
echo "烧录流程见 $REPO_ROOT/docs/flash.md (本板 rev1.3)"
