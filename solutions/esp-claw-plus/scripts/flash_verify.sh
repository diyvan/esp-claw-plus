#!/usr/bin/env bash
# M0/M1 真机验证一条龙: 构建 edge_agent → 烧录 → 抓串口日志。
#
# 用法:
#   solutions/ha_ai_panel/scripts/flash_verify.sh [build|flash|log|all]   # 默认 all
#
# 环境变量:
#   PORT      串口设备, 默认 /dev/tty.usbmodem5B910423531
#   DURATION  抓日志秒数, 默认 35
#
# 前置:
#   1. 已 source ESP-IDF v6.1 激活脚本(脚本对 idf.py 有兜底, 见下)
#   2. 首次运行先执行 solutions/ha_ai_panel/scripts/setup_esp_claw.sh
#   3. 必须在沙箱外执行: 烧录与串口访问 /dev/tty.usbmodem* 会被沙箱拒绝
#
# 产出: 完整日志落盘到 solutions/ha_ai_panel/logs/flash-verify-<时间戳>.log
set -euo pipefail

ACTION="${1:-all}"
PORT="${PORT:-/dev/tty.usbmodem5B910423531}"
DURATION="${DURATION:-35}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTION_DIR/../.." && pwd)"

APP_DIR="$SOLUTION_DIR/esp-claw/application/edge_agent"
LOG_DIR="$SOLUTION_DIR/logs"
CAPTURE="$REPO_ROOT/scripts/capture_serial_log.py"

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

python_bin() {
    if [ -n "${IDF_PYTHON_ENV_PATH:-}" ] && [ -x "$IDF_PYTHON_ENV_PATH/bin/python" ]; then
        printf '%s' "$IDF_PYTHON_ENV_PATH/bin/python"
    else
        printf '%s' "python3"
    fi
}

if [ ! -d "$APP_DIR" ]; then
    echo "错误: 未找到 $APP_DIR" >&2
    echo "      请先运行 solutions/ha_ai_panel/scripts/setup_esp_claw.sh" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/flash-verify-$(date +%Y%m%d-%H%M%S).log"
echo "==> 日志文件: $LOG"

cd "$APP_DIR"

if [ "$ACTION" = "build" ] || [ "$ACTION" = "all" ]; then
    echo "==> 构建 edge_agent"
    run_idf build 2>&1 | tee -a "$LOG"
fi

if [ "$ACTION" = "flash" ] || [ "$ACTION" = "all" ]; then
    echo "==> 烧录 (port=$PORT)"
    run_idf -p "$PORT" flash 2>&1 | tee -a "$LOG"
fi

if [ "$ACTION" = "log" ] || [ "$ACTION" = "all" ]; then
    echo "==> 抓串口日志 (port=$PORT, duration=${DURATION}s)"
    "$(python_bin)" "$CAPTURE" --port "$PORT" --duration "$DURATION" 2>&1 | tee -a "$LOG"
fi

echo
echo "==> 完成。请核对日志中的下列项(见 docs/m0-verification.md §7):"
echo "    - 启动无 panic / 无 'Lock failed'"
echo "    - heap / PSRAM 水位"
echo "    - Agent 经 IM 或本地渠道对话成功"
echo "    - 一条 Lua 规则被事件触发并执行"
