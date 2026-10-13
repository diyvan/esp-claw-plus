#!/usr/bin/env bash
# 回归验证: esp-claw 构建时会**就地给 ESP-IDF 安装目录打补丁**(见
# docs/m0-verification.md §4.1)。本脚本用同一份 IDF 构建仓库既有示例,
# 确认这些补丁没有破坏它们;同时打印当前 IDF 的补丁状态。
#
# 用法:
#   solutions/ha_ai_panel/scripts/check_idf_regression.sh [示例目录名 ...]
#
#   不带参数时默认构建: 02_HelloWorld 11_esp_brookesia_phone
#   传 `all` 时构建 examples/esp-idf/ 下全部 12 个示例(耗时最长, 与 CI 矩阵同面)
#
# 前置: 已 source ESP-IDF v6.1 激活脚本(脚本对 idf.py 有兜底)。
#
# 产出: 日志落盘到 solutions/ha_ai_panel/logs/idf-regression-<时间戳>.log
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTION_DIR/../.." && pwd)"
EX_DIR="$REPO_ROOT/examples/esp-idf"
LOG_DIR="$SOLUTION_DIR/logs"

DEFAULT_EXAMPLES=(02_HelloWorld 11_esp_brookesia_phone)

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

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/idf-regression-$(date +%Y%m%d-%H%M%S).log"
echo "==> 日志文件: $LOG"

# ---------------------------------------------------------------- 补丁状态
# 每项: "名称|IDF 相对路径|补丁生效后的标志文本"
PATCH_CHECKS=(
    "parlio_tx_edge|components/esp_lcd/parl/esp_lcd_panel_io_parl.c|.sample_edge = PARLIO_SAMPLE_EDGE_NEG"
    "usb_iad_desc_size|components/usb/include/usb/usb_types_ch9.h|#define USB_IAD_DESC_SIZE    8"
    "ext_ram_noload_rodata|components/esp_system/ld/ld.ext_ram.sections|MAX(ABSOLUTE(.),"
    "http_client_set_event_handler|components/esp_http_client/esp_http_client.c|esp_err_t esp_http_client_set_event_handler("
)

echo "==> 检查 esp-claw 对 IDF 的就地补丁状态 (IDF_PATH=${IDF_PATH:-未设置})" | tee -a "$LOG"
if [ -z "${IDF_PATH:-}" ]; then
    echo "    跳过: IDF_PATH 未设置" | tee -a "$LOG"
else
    for item in "${PATCH_CHECKS[@]}"; do
        name="${item%%|*}"
        rest="${item#*|}"
        rel="${rest%%|*}"
        marker="${rest#*|}"
        f="$IDF_PATH/$rel"
        if [ ! -f "$f" ]; then
            printf '    %-32s 文件不存在: %s\n' "$name" "$rel" | tee -a "$LOG"
        elif grep -qF -- "$marker" "$f"; then
            printf '    %-32s 已打补丁\n' "$name" | tee -a "$LOG"
        else
            printf '    %-32s 未打补丁(原始 IDF)\n' "$name" | tee -a "$LOG"
        fi
    done
fi

# ---------------------------------------------------------------- 构建回归
if [ "${1:-}" = "all" ]; then
    EXAMPLES=()
    for d in "$EX_DIR"/*/; do
        [ -f "$d/CMakeLists.txt" ] && EXAMPLES+=("$(basename "$d")")
    done
elif [ "$#" -gt 0 ]; then
    EXAMPLES=("$@")
else
    EXAMPLES=("${DEFAULT_EXAMPLES[@]}")
fi

FAILED=()
PASSED=()

for ex in "${EXAMPLES[@]}"; do
    if [ ! -f "$EX_DIR/$ex/CMakeLists.txt" ]; then
        echo "==> 跳过 $ex: 不是示例目录" | tee -a "$LOG"
        FAILED+=("$ex(未找到)")
        continue
    fi

    echo "==> 回归构建 $ex (rev1_3)" | tee -a "$LOG"
    cd "$EX_DIR/$ex"
    if run_idf -B build-rev1_3 -D SDKCONFIG=sdkconfig.rev1_3 \
               -D WAVESHARE_REVISION_PROFILE=rev1_3 set-target esp32p4 >>"$LOG" 2>&1 \
       && run_idf -B build-rev1_3 -D SDKCONFIG=sdkconfig.rev1_3 \
                  -D WAVESHARE_REVISION_PROFILE=rev1_3 build >>"$LOG" 2>&1; then
        echo "    ✅ $ex 构建通过" | tee -a "$LOG"
        PASSED+=("$ex")
    else
        echo "    ❌ $ex 构建失败 (详见日志)" | tee -a "$LOG"
        FAILED+=("$ex")
    fi
done

echo | tee -a "$LOG"
echo "==> 汇总: 通过 ${#PASSED[@]} / 失败 ${#FAILED[@]}" | tee -a "$LOG"
if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '    失败: %s\n' "${FAILED[*]}" | tee -a "$LOG"
    exit 1
fi
