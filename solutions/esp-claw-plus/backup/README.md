# 清理记录：sdkconfig.rev1_3 / build-rev1_3

- 清理日期：2026-10-18
- 清理位置：`solutions/esp-claw-plus/esp-claw/application/edge_agent/`
- 影响范围：仅构建配置与构建产物，不涉及任何源码

## 清理对象

| 对象 | 大小 | 处置 |
| --- | --- | --- |
| `sdkconfig.rev1_3` | 141,233 B | 已备份为 `backup/sdkconfig.rev1_3.bak`（sha256 `ee0009da44ef4627907e764b187a3031e55efac98ff4dd94f4271ea5e75d44e9`），原文件删除 |
| `build-rev1_3/` | 约 52 MB | 纯 ESP-IDF 构建输出，可再生，未备份，直接删除 |

## 为什么要清理（原因）

该配置由一条不适用于本工程的命令生成：

```bash
idf.py -B build-rev1_3 -D SDKCONFIG=sdkconfig.rev1_3 -D WAVESHARE_REVISION_PROFILE=rev1_3 build
```

`rev1_3` 配置档位（`config/revision_profiles.cmake`）只服务于仓库 `examples/esp-idf/*`，本 solution
**没有** `sdkconfig.defaults.rev1_3`。因此 IDF 在 `-D SDKCONFIG=sdkconfig.rev1_3` 时只能从通用
`sdkconfig.defaults` 全新派生出一份"裸配置"，与工程真实配置无关。

与正式 `sdkconfig` 对比差异达 932 行，且关键项全部是错的：

| 配置项 | `sdkconfig`（正式，正确） | `sdkconfig.rev1_3`（错误） | 后果 |
| --- | --- | --- | --- |
| Flash 大小 | `16MB` | `2MB` | 15.5MB 分区表放不下，**构建立即失败** |
| PSRAM | `CONFIG_SPIRAM=y`（HEX/200M） | `# CONFIG_SPIRAM is not set` | 本板 32MB PSRAM 全废，TTS 数据/模型/LVGL 缓冲不可用 |
| 芯片版本 | `REV_MIN_100`（≥v1.0，兼容 rev1.3） | `REV_MIN_301` / `REV_MAX_399` | 正是不兼容本板 rev1.3 的 rev3.0 档，烧录会被拒 |
| Flash mode | QIO | DIO | 降速 |
| CPU 频率 | 360 MHz | 400 MHz | — |
| mbedtls 内存 | 外部 | 内部 | 内部内存吃紧 |
| 项目组件 | MCP / mDNS / Lua / DSP / Audio Codec / IoT Button / Emote 等齐全 | 大量缺失 | 功能不全 |

结论：该文件对构建、烧录均无价值，且会误导后续使用 `-D SDKCONFIG=sdkconfig.rev1_3` 的人。
`build-rev1_3/` 是同一错误命令留下的半成品构建目录（非 `.gitignore` 覆盖，污染 `git status`）。

## 本工程正确的构建方式

```bash
source /Users/diyvan/.espressif/tools/activate_idf_v6.1.sh
cd solutions/esp-claw-plus/esp-claw/application/edge_agent
idf.py build            # 默认 sdkconfig + build/，16MB / REV_MIN_100，兼容本板 rev1.3
```

默认 `sdkconfig` 的 `CONFIG_ESP32P4_REV_MIN_100=y` 已覆盖 rev1.3，无需 rev 配置档。

## 恢复方案

### 恢复 `sdkconfig.rev1_3`（一般不需要）

```bash
cp solutions/esp-claw-plus/backup/sdkconfig.rev1_3.bak \
   solutions/esp-claw-plus/esp-claw/application/edge_agent/sdkconfig.rev1_3
```

注意：恢复后**不建议用于构建**——它是 2MB flash / 无 PSRAM / rev3.0 配置，构建会因分区表超限失败。

### 恢复 `build-rev1_3/`

构建目录可再生，重新执行构建命令即可：

```bash
idf.py -B build-rev1_3 -D SDKCONFIG=<一份正确的 sdkconfig> build
```

由于本工程不支持 `rev1_3` 档位，正常做法是直接用默认 `idf.py build`（输出到 `build/`），
无需 `build-rev1_3/`。
