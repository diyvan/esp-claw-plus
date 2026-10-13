# AGENTS.md

Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5 开发板示例仓库（ESP32-P4 + 3.5" ST7796 SPI 触摸屏 + FT5x06 触摸）。CI 只做编译验证，运行时、显示、触摸均未在真机测试——示例的可信度以真机实测为准。

## 构建与烧录

构建、烧录固件、验证运行、抓串口日志时，先读 [docs/flash.md](docs/flash.md)。本板芯片为 **rev1.3**，默认 `rev3_x` 配置的二进制烧不进去，必须用 `rev1_3` 配置构建。

## 关键事实

- `11_esp_brookesia_phone` 白屏 bug 已在真机调试中修复（`main/main.cpp` 锁回调把 `bsp_display_lock` 的 `bool` 返回值误判为 `esp_err_t`，导致 LVGL 渲染线程死锁），勿回退；其他示例出现同样写法需同样修复。
- 本板禁用 `CONFIG_LOG_DEFAULT_LEVEL=4`（Debug）：PSRAM 调优的 DRAM 日志洪流会拖死启动。
- ESP-IDF v6.1：`source /Users/diyvan/.espressif/tools/activate_idf_v6.1.sh`。
- 串口 `/dev/tty.usbmodem5B910423531`；抓日志用 `scripts/capture_serial_log.py`（处理 USB 重枚举）。
- agent 沙箱**可以**访问串口设备（实测 `esptool flash-id/read-flash/write-flash` 均成功），烧录/抓日志可直接在沙箱内执行；打开串口会触发一次复位，需等启动完成后（约 15s）再交互。

## 仓库结构

- `examples/esp-idf/`、`examples/arduino/`：按编号编号的示例；`config/revision_profiles.cmake` 定义 `rev1_3`/`rev3_x` 配置档位。
- `docs/`：`ci.md`（构建矩阵）、`revisions.md`（芯片版本差异）、`components.md`（BSP 组件）、`flash.md`（烧录步骤）。
- `scripts/`：CI 与辅助脚本。
