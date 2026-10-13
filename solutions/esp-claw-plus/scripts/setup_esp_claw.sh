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
STACK_PATCH="$SOLUTION_DIR/patches/esp-claw-p4-task-stack-internal.patch"
HA_VOICE_PATCH="$SOLUTION_DIR/patches/esp-claw-ha-voice-config.patch"
HA_MCP_PATCH="$SOLUTION_DIR/patches/esp-claw-ha-mcp-token.patch"
ASR_STREAM_PATCH="$SOLUTION_DIR/patches/esp-claw-asr-stream.patch"
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

echo "==> 生成 board manager 配置"
cd "$SRC_DIR/application/edge_agent"
run_idf bmgr -c ./boards -b "$BOARD"

echo
echo "完成。构建:"
echo "  cd $SRC_DIR/application/edge_agent && idf.py build"
echo "烧录流程见 $REPO_ROOT/docs/flash.md (本板 rev1.3)"
