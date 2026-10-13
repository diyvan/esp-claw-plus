# 烧录指南（本板实测可用的完整流程）

本板（Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5）芯片为 **ESP32-P4 rev1.3**，仓库默认的 `rev3_x` 配置二进制无法烧录（esptool 报 chip rev 不匹配）。所有构建烧录必须走 `rev1_3` 配置。CI 命令见 [ci.md](ci.md)，本文是针对本板的操作步骤。

## 步骤

### 1. 激活 ESP-IDF v6.1

```bash
source /Users/diyvan/.espressif/tools/activate_idf_v6.1.sh
```

完成标准：`idf.py --version` 输出 `v6.1`。（SDK 位于 `~/.espressif/v6.1/esp-idf`，每次新 shell 都要重新激活。）

### 2. 构建（rev1_3 配置）

以 `11_esp_brookesia_phone` 为例（其余示例同理替换目录）：

```bash
cd examples/esp-idf/11_esp_brookesia_phone
idf.py -B build-rev1_3 -D SDKCONFIG=sdkconfig.rev1_3 -D WAVESHARE_REVISION_PROFILE=rev1_3 set-target esp32p4
idf.py -B build-rev1_3 -D SDKCONFIG=sdkconfig.rev1_3 -D WAVESHARE_REVISION_PROFILE=rev1_3 build
```

完成标准：输出 `Project build complete`。

要点：

- 必须用独立构建目录 `build-rev1_3`，与默认 `build`（rev3_x）**互不混用**，二进制不兼容。
- `-D SDKCONFIG=sdkconfig.rev1_3` 生成的主配置文件也是这个名字（由 `sdkconfig.defaults.rev1_3` 派生）；它属于构建产物，临时改 sdkconfig 实验后要记得还原。

### 3. 烧录

```bash
idf.py -B build-rev1_3 -p /dev/tty.usbmodem5B910423531 flash
```

完成标准：`Hash of data verified` + `Hard resetting via RTS pin...`。若 esptool 报 `This chip is ESP32-P4 (revision v1.3) ... not supported`，说明用错了 rev3_x 产物，回到步骤 2。

### 4. 运行验证（抓串口日志）

```bash
/Users/diyvan/.espressif/tools/python/v6.1/venv/bin/python scripts/capture_serial_log.py
```

完成标准：日志出现 `Returned from app_main()`，且无 `Lock failed`、无 panic。脚本处理了 USB-Serial/JTAG 复位时的重枚举（这是 `cat` / 普通后台读取会静默失败的原因），先经 DTR/RTS 复位芯片再抓 35 秒日志。串口号变化时改脚本头部的 `PORT`。

## 恢复原厂固件

原厂固件即仓库自带的 [firmware/ESP32-P4-WiFi6-LCD-3in5.bin](../firmware/ESP32-P4-WiFi6-LCD-3in5.bin)（来自官方 GitHub `waveshareteam/ESP32-P4-WIFI6-Touch-LCD-3.5` main 分支，与线上版本 SHA256 一致）。该镜像头部芯片版本范围为 v0.1~v1.99，**rev1.3 芯片可直接烧录**，无需重新构建。

```bash
/Users/diyvan/.espressif/tools/python/v6.1/venv/bin/python -m esptool \
  --chip esp32p4 -p /dev/tty.usbmodem5B910423531 --baud 460800 \
  write-flash 0x0 firmware/ESP32-P4-WiFi6-LCD-3in5.bin
```

要点：

- 这是**从 flash 0x0 起始的合并镜像**（bootloader 在文件偏移 0x2000），烧写地址必须是 `0x0`，不要再加 `--flash-mode` 等参数覆盖。
- 烧前可先整片擦除：`python -m esptool --chip esp32p4 -p PORT erase-flash`。
- 完成标准：`Wrote 13762560 bytes` + `Hash of data verified`。
- 启动验证：串口日志出现 C6 协处理器 SDIO 握手（`transport: Base transport is set-up`）、`Setting LCD backlight: 100%`、周期性内存统计；`SD card mount failed` 属正常（未插卡）。

## 已知坑

- **日志等级**：本板禁用 `CONFIG_LOG_DEFAULT_LEVEL=4`（Debug）。PSRAM 时序调优上下文中的 `ESP_DRAM_LOGD` 洪流（`MSPI DQS: set to best phase`）会拖死启动，表现为整屏日志被淹没、应用无法启动。Info（默认 3）正常。
- **GUI 锁类型**：本仓库示例存在把 `bsp_display_lock` 的 `bool` 返回值当 `esp_err_t` 判断的通病（成功返回 `true(1)` ≠ `ESP_OK(0)`，误报 Lock failed 且不解锁，主任务永久持有 LVGL 递归锁 → 白屏卡死）。`11_esp_brookesia_phone/main/main.cpp` 已修复，勿回退；其余示例出现同样写法需同样修复。
- **agent 沙箱**：烧录和串口访问系统设备（`/dev/tty.usbmodem*`），沙箱内会失败，需在沙箱外执行。
- **芯片版本判别**：不确定时用 `python -m esptool --chip esp32p4 -p PORT flash-id`，看 `Chip is ESP32-P4 (revision v1.3)`。

## 参考

- [ci.md](ci.md)：CI 全矩阵构建命令（rev1_3 / rev3_x 全示例）。
- [revisions.md](revisions.md)：芯片版本差异与配置档位说明。
