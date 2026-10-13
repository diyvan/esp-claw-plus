# M0 验证记录 — esp-claw 基座可行性

> 对应 [README.md](../README.md) §7 里程碑 M0。记录时间:2026-09-30(开发机 + 首次烧录);
> **2026-10-08 第二次真机复测更新**(触摸修复 §5.3、记忆修复 §5.4、功能汇总 §5.5)。

## 1. 环境

| 项 | 值 |
|---|---|
| ESP-IDF | **v6.1.0**(`/Users/diyvan/.espressif/v6.1/esp-idf`) |
| esp-claw | **v0.1.0**(仓库唯一 tag) |
| 目标板 | `waveshare_esp32_p4_wifi6_touch_lcd_3_5`(rev1.3) |
| 新增工具依赖 | `pip install esp-bmgr-assist`(0.8.3,提供 `idf.py bmgr`) |

## 2. 结论速览

| # | M0 验证项 | 结果 |
|---|---|---|
| 1 | esp-claw 能在 IDF v6.1 下构建 | ✅ **通过**(仅需 1 处修复) |
| 2 | 本板板级适配(仿 p4_nano)被 board manager 接受 | ✅ **通过**(M0 4 外设 / 4 设备;M1 扩到 6 外设 / 7 设备,见 §5.1) |
| 3 | esp-sr 能加入 esp-claw 工程编译(P4) | ✅ **通过**(须用 esp-sr master,见 §4.3) |
| 4 | 固件体积是否放得下 16MB Flash / 4MB app 分区 | ✅ **通过**(app 3.22MB,余 20%) |
| 5 | 真机运行 / 内存水位 | ✅ **通过**(见 §5.2–§5.4;仅"目视确认屏/触摸"与 C6 协处理器固件版本待办) |

**总体判断:路线 B 的基座风险显著低于方案文档预期。** 原 README 风险 3("IDF 版本兼容性未实测")已可降级。

## 3. 构建方法与结果

```bash
source /Users/diyvan/.espressif/tools/activate_idf_v6.1.sh
cd solutions/ha_ai_panel/esp-claw/application/edge_agent
idf.py bmgr -c ./boards -b waveshare_esp32_p4_wifi6_touch_lcd_3_5
idf.py build
```

board manager 生成结果(M0 基线):

```text
✅ Successfully validated 4 peripherals   (i2c_master / i2s_audio_out / i2s_audio_in / gpio_pa_control)
✅ Successfully validated 4 devices       (audio_dac / audio_adc / fs_sdcard / buttons)
```

M1 扩展显示/触摸后(bmgr 仍全绿):

```text
✅ Successfully validated 6 peripherals   (+ spi_display / ledc_backlight)
✅ Successfully validated 7 devices       (+ display_lcd / lcd_brightness / lcd_touch)
```

构建结果:

```text
Bootloader binary size 0x5eb0 bytes.  0x1150 bytes (15%) free.
edge_agent.bin binary size 0x338080 bytes (≈3.22 MiB).
Smallest app partition is 0x400000 bytes (4 MiB). 0xc7f80 bytes (20%) free.
Project build complete.
```

## 4. 关键发现

### 4.1 esp-claw 会就地修改 ESP-IDF 安装目录 ⚠️

`application/edge_agent/tools/cmake/esp_idf_patch.cmake` 会在 CMake 配置阶段对
`$IDF_PATH` **打补丁**(改动 esp_http_client、linker script、parlio 等源文件),
即修改 `~/.espressif/v6.1/esp-idf` 本身,**不再局限于本工程**。

- 影响:同一 IDF 安装下的**其他示例**(如本仓库 `examples/esp-idf/*`)共享被改过的 IDF。
- 另一处副作用:构建过程对 `components/esp_system/ld/esp32s31/sections.ld.in` 做
  `file(TOUCH_NOCREATE)`,该操作**要求对 IDF 目录有写权限**,否则 CMake 配置直接失败
  (报 `file problem touching file`)。在受限沙箱/只读 IDF 环境下会失败。

#### 实际足迹(已实测,IDF v6.1)

IDF 安装目录本身是 git 仓库,`git -C $IDF_PATH status` 给出**权威答案**:

```text
 M components/esp_system/ld/ld.ext_ram.sections
```

即 **4 个补丁点里只有 1 个真正落地**,且只改了 1 行:

```diff
   .ext_ram.dummy (NOLOAD) :
   {
     HIDDEN(_ext_ram_on_same_bus = ORIGIN(ext_ram_seg) == ORIGIN(flash_rodata_seg));
-    . = _ext_ram_on_same_bus ? ORIGIN(ext_ram_seg) + (_rodata_reserved_end - _flash_rodata_dummy_start) : 0;
+    . = _ext_ram_on_same_bus ? MAX(ABSOLUTE(.), ORIGIN(ext_ram_seg) + (_rodata_reserved_end - _flash_rodata_dummy_start)) : 0;
     . = ALIGN(_ext_ram_on_same_bus ? _esp_mmu_page_size : 0);
   } > ext_ram_seg
```

另外 3 个补丁在 v6.1 上均为 **no-op**(原因已逐个核实):

| 补丁点 | v6.1 上的结果 | 原因 |
|---|---|---|
| parlio `.sample_edge` | 未修改 | v6.1 已是上游修复形态(`.shift_edge = PARLIO_SHIFT_EDGE_NEG`),esp-claw 判定为"已修复" |
| `usb_types_ch9.h` 的 `USB_IAD_DESC_SIZE` | 未修改 | v6.1 **已无 `components/usb` 目录**(USB 栈移出 IDF),文件不存在 → 跳过 |
| `esp_http_client_set_event_handler` | 未修改 | v6.1 已在上游提供该 API(头/源文件均已有) |

补丁状态可随时用脚本复查:

```bash
solutions/ha_ai_panel/scripts/check_idf_regression.sh
```

#### 回归结论:不需要独立 IDF 安装

用同一份被改过的 IDF 构建仓库既有示例(rev1_3 档):

| 示例 | 是否压到被改的 linker 路径 | 结果 |
|---|---|---|
| `02_HelloWorld` | 否(基础冒烟) | ✅ 构建通过 |
| `11_esp_brookesia_phone` | **是**(`CONFIG_SPIRAM=y` + `SPIRAM_XIP_FROM_PSRAM=y`,ext_ram 与 flash rodata 同总线) | ✅ 构建通过 |

**结论:改动是收紧约束(把当前地址与计算值取 `MAX`),且唯一载荷落在 PSRAM 同总线场景,
而该场景最重的示例 `11_esp_brookesia_phone` 构建通过 → 无需为路线 B 建独立 IDF。**

留一条后路(升级/重装 IDF 后 esp-claw 会重新打补丁;若要还原):

```bash
git -C "$IDF_PATH" checkout -- components/esp_system/ld/ld.ext_ram.sections
```

### 4.2 IDF v6 移除了内置 `json` 组件

esp-claw v0.1.0 的 `mcp_mdns`、`cap_mcp_client` 两个组件 `REQUIRES json`,而 IDF v6 已把
cJSON 移出 IDF、改由组件管理器以 `espressif/cjson` 提供(组件名 `cjson`)。

修复(已固化为 [patches/esp-claw-idf6.patch](../patches/esp-claw-idf6.patch)):

- `components/common/mcp_mdns/CMakeLists.txt`:`json` → `cjson`
- `components/claw_capabilities/cap_mcp_client/CMakeLists.txt`:`json` → `cjson`
- `components/common/mcp_mdns/idf_component.yml`:补 `espressif/cjson: "*"`

### 4.3 esp-sr 尚未发布支持 IDF v6 的版本

- 组件注册表**已发布**的 esp-sr(≤2.5.5)仍 `REQUIRES json`,且 idf 版本约束不含 v6 →
  在 IDF v6.1 下**无法解析**(`no versions match` / `Failed to resolve component 'json'`)。
- **master 分支已适配**:`idf: ">=5.0"`(无上限)+ 依赖改为 `espressif/cjson`。
- 验证方法:直接下载 master 源码包(codeload tar.gz,约 183MB),
  以 `path:` 依赖接入后构建 →

```text
[2712/2721] Linking C static library esp-idf/esp-sr/libesp-sr.a
edge_agent.bin binary size 0x336730 bytes.  (含 esp-sr, 仍余 20%)
Project build complete.
```

**结论:esp-sr 与 esp-claw / IDF v6.1 / P4 可共存编译。** 待官方发布适配 v6 的版本后切回注册表依赖即可。

> 注意:用 `git:` 依赖拉 master 会全量克隆该仓库(约 426MB、历史更大),
> 实测速度约 0.09MB/s,极慢;M3 正式引入时建议锁具体 commit 或用镜像。

### 4.4 分区表缺 `model` 分区

`partitions_16MB.csv` 分区为:nvs / otadata / phy_init / ota_0(4M) / ota_1(4M) /
emote(3M) / system(1M) / storage(3M),**没有 esp-sr 唤醒模型所需的 `model` 分区**,
且剩余空隙仅约 0.9MB。M3 引入 WakeNet 前需要调整分区表(例如压缩 `ota_1` 或 `emote`)。

### 4.5 esp-claw 已自带 UI/音频模块,M1 上屏有现成路径

仓库内已存在 `lua_module_lvgl`、`lua_module_lcd`、`lua_module_lcd_touch`、
`lua_module_display`、`lua_module_image`、`lua_module_audio`、`display_arbiter`、
以及 `espressif2022/esp_emote_*` 表情框架。esp-claw 参照板虽无屏,但**显示栈是平台级能力**,
M1 不需要从零搭 LVGL。这降低了 README 风险 4 的等级。

## 5. 本板适配要点(与 p4_nano 的差异)

| 项 | p4_nano | 本板 | 处理 |
|---|---|---|---|
| I2C | SDA=7 / SCL=8 | 同左 | 直接沿用 |
| I2S DOUT/DIN | dout=11 / din=9 | **dout=9 / din=11(相反)** | 已按 BSP 修正 |
| PA 使能 | GPIO53 | GPIO53 | 沿用 |
| SD 供电 | GPIO46 外部使能 | **P4 片上 LDO 通道 4** | 不写 SD 电源控制代码 |
| Console | UART0 | **UART0(板载 USB-UART 桥)** | 主 console 必须用 UART,副 `USB_SERIAL_JTAG`;配成 JTAG 主 console 会完全静默(见 §5.2) |
| 芯片 rev | < v3 | rev1.3 | `CONFIG_ESP32P4_SELECTS_REV_LESS_V3=y` |
| LCD | 无 | ST7796 320×480 SPI | M1 接入(`display_lcd` + `spi_display` + `ledc_backlight`) |
| 触摸 | 无 | FT6336 (FT5x06 家族), I2C 0x38 | M1 接入(`lcd_touch`, 8-bit 地址填 `0x70`) |

板级产出:`boards/waveshare_esp32_p4_wifi6_touch_lcd_3_5/`
(`board_info.yaml` / `board_devices.yaml` / `board_peripherals.yaml` /
`sdkconfig.defaults.board` / `setup_device.c`)。

显示/触摸参数取自 Waveshare BSP v2.0.2:80MHz SPI mode3、`LCD_RGB_ELEMENT_ORDER_BGR`、
`LCD_RGB_DATA_ENDIAN_BIG`、16bpp、`invert_color`、`mirror(x=true, y=false)`、
触摸不做 swap/mirror。

### 5.1 M1 板级扩展:显示/触摸接入(开发机已完成的部分)

M1 起步把 ST7796 屏 + FT6336 触摸接进板级 YAML,新增 2 外设 3 设备
(bmgr 校验:6 外设 / 7 设备):

| 类型 | 名称 | 要点 |
|---|---|---|
| 外设 `spi` | `spi_display` | `SPI2_HOST`,MOSI=20/CLK=21,`miso_io_num: -1`(只写),`max_transfer_sz` 按整屏一行 |
| 外设 `ledc` | `ledc_backlight` | GPIO28,10-bit,默认 duty 1023 |
| 设备 `display_lcd` | `display_lcd` | `chip: st7796`,`sub_type: spi`;`dependencies: espressif/esp_lcd_st7796` |
| 设备 `ledc_ctrl` | `lcd_brightness` | `default_percent: 100`,引用 `ledc_backlight` |
| 设备 `lcd_touch` | `lcd_touch` | `chip: ft5x06`,`sub_type: i2c`;`dependencies: espressif/esp_lcd_touch(+_ft5x06)`;8-bit 地址 `0x70` |

#### 关键发现:面板/触摸驱动必须由板级提供工厂钩子

board manager 的 `dev_display_lcd_sub_spi.c` / `dev_lcd_touch_sub_i2c.c` 是**通用总线胶水**,
它们把控制器创建委托给两个**弱约定符号**:

```c
extern esp_err_t lcd_panel_factory_entry_t(esp_lcd_panel_io_handle_t, const esp_lcd_panel_dev_config_t *, esp_lcd_panel_handle_t *);
extern esp_err_t lcd_touch_factory_entry_t(esp_lcd_panel_io_handle_t, const esp_lcd_touch_config_t *, esp_lcd_touch_handle_t *);
```

这两个符号**不在 board manager 里定义**,必须由板级 `setup_device.c` 实现 —— 否则链接期报

```text
undefined reference to `lcd_panel_factory_entry_t'
undefined reference to `lcd_touch_factory_entry_t'
```

(所有带屏板卡如 `m5stack_cores3` / `dfrobot_firebeetle_2_ESP32_S3` /
`dfrobot_k10` 的 `setup_device.c` 都实现了它们。)

本板 `setup_device.c` 已按此补齐:

```c
esp_err_t lcd_panel_factory_entry_t(...) { return esp_lcd_new_panel_st7796(io, panel_dev_config, ret_panel); }
esp_err_t lcd_touch_factory_entry_t(...) { return esp_lcd_touch_new_i2c_ft5x06(io, touch_dev_config, ret_touch); }
```

`mirror/invert/swap_xy` 无需在钩子里做,board manager 会依据 YAML 统一施加。

> 该文件由 `setup_esp_claw.sh` 从 `boards/.../setup_device.c` 复制到
> `esp-claw/application/edge_agent/boards/waveshare/<board>/`,改完须重跑脚本(或手工 `cp`)再 build。

#### 构建验证状态

`idf.py bmgr` 已通过(6 外设 / 7 设备),**完整 `idf.py build` 已在本机跑通**(见 §5.2)。

esp-claw 会就地修改 IDF 安装目录(见 §4.1)。受限沙箱对部分 IDF 路径写入被拒,导致
`tools/cmake/esp_idf_patch.cmake` 里那句 `file(TOUCH_NOCREATE .../esp32s31/sections.ld.in)`
在配置阶段直接报 `CMake Error` 并让 configure 失败。已改成容错写法(该 touch 只是 Ninja
重跑提示,S31 片段在 P4 构建中无关):

```cmake
execute_process(COMMAND ${CMAKE_COMMAND} -E touch_nocreate ".../sections.ld.in"
                RESULT_VARIABLE _edge_agent_touch_rc OUTPUT_QUIET ERROR_QUIET)
```

该改动已并入 `patches/esp-claw-idf6.patch`,重跑 `setup_esp_claw.sh` 即可复现。

### 5.2 真机烧录与启动验证(已完成)

第一次烧录后 **bootloader 之后完全静默**。逐步隔离后定位根因并修复:

- 对照实验:同一根串口线烧仓库现成的 `02_HelloWorld`(UART 主 console),bootloader +
  app 日志完整输出 → 证明串口链路与板子都正常。
- 隔离实验:只烧 esp-claw 的 `bootloader.bin` + `partition-table.bin`,芯片反复
  `rst:0x3 (SW_SYS_RESET)`(bootloader 在跑、发现 app 无效即复位)但**零日志** →
  bootloader 运行但 console 被静音。
- 根因:板级 `sdkconfig.defaults.board` 把主 console 配成了 `CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG`,
  日志被送到 **P4 原生 USB 口(未接主机)**;而本板串口是 **接 UART0(GPIO37/38)的
  USB-UART 桥**(`ioreg`: `USB Single Serial` / `Vendor 0x1A86` / SN `5B91042353`)。
- 修复:`CONFIG_ESP_CONSOLE_UART_DEFAULT=y` + `ESP_CONSOLE_UART_NUM=0` +
  `ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG=y`,与仓库其它已验证示例一致。
  改完须重跑 `bmgr`(它把板级 defaults 复制成 `gen_bmgr_codes/board_manager.defaults`)
  并丢弃旧 `sdkconfig` 重新生成。

修复后真机启动日志确认(节选,`build` = `18:47` / `18:48`):

```text
I (25) boot: ESP-IDF v6.1-dirty 2nd stage bootloader
I (28) boot: chip revision: v1.3
I (1154) cpu_start: GPIO 38 and 37 are used as console UART I/O pins
I esp_psram: Found 32MB PSRAM device  /  Speed: 200MHz
I (1824) DEV_DISPLAY_LCD: Successfully initialized LCD display: display_lcd, chip: st7796
I (1883) DEV_LCD_TOUCH_SUB_I2C: Successfully initialized LCD touch: lcd_touch, addr: 0x70
I (1441) DEV_AUDIO_CODEC: Successfully initialized codec: audio_dac (es8311)  # + audio_adc
I (4146) H_SDIO_DRV: Card init success  /  Identified slave [esp32c6]
I (4817) wifi_manager: *** Provisioning AP active: esp-claw-000000 @ 192.168.4.1 ***
I (6002) app_capabilities: Register MCP client cap ok (groups=11, caps=51)
I (6127) claw_core_agent_0: Started worker task  /  claw_agent_mgr: Created root agent id=0
I (6841) main_task: Returned from app_main()
```

功能结论:**屏/触摸/音频 codec/背光全部初始化成功,ESP-Hosted 与 C6 协处理器建链成功,
Wi-Fi 进入配网 AP 模式,Agent Loop 起来并进入 CLI REPL**。

启动日志中的非致命告警(不影响启动,后续里程碑处理):

| 日志 | 含义 | 处置 |
|---|---|---|
| `sdmmc_init_ocr: send_op_cond (1) returned 0x107` | 未插 SD 卡,`fs_sdcard` 初始化失败 | 已自动回退 flash fatfs,预期行为 |
| `transport: Version mismatch: Host [2.12.0] > Co-proc [0.0.0]` | C6 协处理器固件版本读不到,可能需升级 C6 slave 固件 | M2 联 Wi-Fi STA 前确认 |
| `system_api: 1/0 mac type is incorrect (not found)` | 读不到 Wi-Fi MAC,配网 SSID 后缀显示 `000000` | M2 处理 |
| `gpio: conflict found for GPIO[53]` | PA 使能脚在 I2S 与 GPIO 外设间复用告警 | 功能正常,留观 |
| `claw_memory: Async memory extract disabled: LLM config incomplete` | 未配 LLM | 配网/配置后验证 |

### 5.3 触摸初始化回归与修复:board manager 的 probe 早于复位 ⚠️→✅

第二次真机复测(用户已配好 Wi-Fi STA + LLM)时,触摸初始化**稳定失败**(冷启动 3/3):

```text
E (1865) DEV_LCD_TOUCH_SUB_I2C: No LCD touch found on I2C bus: i2c_master
E (1885) DEV_LCD_TOUCH: Failed to initialize LCD touch sub device: i2c
E (1891) BOARD_DEVICE: Failed to init device: lcd_touch
```

而同一固件在**上一次**启动中却成功过(`Successfully initialized LCD touch: lcd_touch, addr: 0x70`),
即结果与上电状态相关 —— 属时序问题而非配置错误。

排查与定位:

- 引脚复核:BSP(`esp32_p4_wifi6_touch_lcd_3_5.h`)为 `BSP_LCD_TOUCH_RST = GPIO_NUM_29`、
  `BSP_LCD_TOUCH_INT = GPIO_NUM_50`、`BSP_LCD_RST = GPIO_NUM_27`,与板级 YAML **完全一致** → 排除配错引脚。
  (BSP 里 `bsp_touch_new()` 那句 `// Shared with LCD reset` 是过时注释,实际是独立 GPIO29。)
- I2C 地址复核:7-bit `0x38` → board manager 用 8-bit `0x70`,与探测到的地址一致 → 排除地址问题。
- **根因**:board manager 的 `dev_lcd_touch_sub_i2c.c` 在创建触摸驱动**之前**先做
  `i2c_master_probe()` 探地址;而 FT6336 的复位脉冲只在 `esp_lcd_touch_new_i2c_ft5x06()` **内部**才发。
  上电后 GPIO29 浮空,芯片可能一直处于复位态而不应答 → 探测失败。

```c
/* dev_lcd_touch_sub_i2c.c: 探测在驱动创建之前 */
uint16_t candidate_runtime_addr = candidate >> 1;
ret = i2c_master_probe(i2c_bus_handle, candidate_runtime_addr, 200);
if (ret == ESP_OK) { ... }
...
if (effective_addr == 0) {
    ESP_LOGE(TAG, "No LCD touch found on I2C bus: %s", ...);   /* 复位尚未发生 */
}
```

**修复**:在板级 `setup_device.c` 的 early init(构造函数,早于 `app_main`/board manager)
里先给一次显式复位脉冲并释放,使芯片先进入可应答状态:

```c
#define BOARD_LCD_TOUCH_RST_GPIO 29      /* 与 board_devices.yaml rst_gpio_num 一致 */

static void p4_wifi6_lcd35_touch_reset_release(void)
{
    const gpio_config_t io_config = { .pin_bit_mask = 1ULL << BOARD_LCD_TOUCH_RST_GPIO,
                                      .mode = GPIO_MODE_OUTPUT, ... };
    ESP_ERROR_CHECK(gpio_config(&io_config));
    gpio_set_level(BOARD_LCD_TOUCH_RST_GPIO, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
    gpio_set_level(BOARD_LCD_TOUCH_RST_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(200));
}

static void __attribute__((constructor)) p4_wifi6_lcd35_board_early_init(void)
{
    ESP_LOGI(TAG, "Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5 board early init");
    p4_wifi6_lcd35_touch_reset_release();
}
```

**验证**:只烧 `0x20000 edge_agent.bin`(保留用户 nvs / /fatfs 配置),复位 3 次,**3/3 成功**:

```text
I (1284) P4_WIFI6_LCD35_SETUP: Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5 board early init
I (1892) DEV_LCD_TOUCH_SUB_I2C: Successfully initialized LCD touch: lcd_touch, addr: 0x70
I (1892) DEV_LCD_TOUCH: Successfully initialized LCD touch: lcd_touch, chip: ft5x06, sub_type: i2c
```

> `W (1865) gpio: conflict found for GPIO[29]` 是板级 early init 与触摸驱动都配置同一引脚所致,
> 属预期告警(功能正常)。
>
> 上游改进建议:`dev_lcd_touch_sub_i2c.c` 应在 `i2c_master_probe` 失败后先调用一次
> 触摸复位回调再重试探测,而不是直接判定"No LCD touch found"。

### 5.4 长时记忆索引空文件导致记忆子系统失效(已修复)

启动及每次请求均刷屏:

```text
E claw_memory: Failed to parse memory index: /fatfs/memory/memory_index.json
W claw_core: context provider collect failed provider=Long-term Memory err=ESP_FAIL
E claw_core: request=1000000 failed: ESP_FAIL
```

用 `cap call` 逐一读文件定位:`MEMORY.md` 可正常读出,而 `memory_index.json` 与
`memory_records.jsonl` **读出为空** —— 即两个文件是 0 字节,`cJSON_Parse("")` 必然失败。

对照源码,`claw_memory.c` 的初始化只在**文件缺失**时写入默认内容,文件存在则原样保留:

```c
ensure_file_with_default(s_memory.records_path, "");
ensure_file_with_default(s_memory.index_path, default_index);   /* 不存在才写 */
```

而 `claw_memory_storage.c` 对"文件不存在"会重建索引、对"存在但解析失败"则直接报错:

```c
err = read_file_dup(s_memory.index_path, &raw);
if (err == ESP_ERR_NOT_FOUND) { root = claw_memory_new_index_root(); return ESP_OK; }
...
if (!root || !cJSON_IsObject(root)) { ESP_LOGE(TAG, "Failed to parse memory index: %s", ...); }
```

→ 空文件造成**死锁**:记忆写入失败 → 索引不被重写 → 索引永远解析失败。
推测空文件来自一次被中断/失败的写入(非首次初始化产物,首次应写入 `default_index`)。

**修复**:删除这两个空文件,由下次初始化的 `ensure_file_with_default` 重建 `default_index`。

```text
cap call delete_file {"path":"/fatfs/memory/memory_index.json"}   -> OK: deleted
cap call delete_file {"path":"/fatfs/memory/memory_records.jsonl"} -> OK: deleted
```

**验证**:复位后启动日志**不再出现** `Failed to parse memory index`,
`cap call memory_list {}` 返回 `{"ok":true,"action":"memory_list","items":[]}`。

> 该问题只需在已损坏的设备上一次性处理;若复现,说明存在写入被中断的路径,后续里程碑可加
> "解析失败 → 备份并重建索引"的自愈逻辑。

### 5.5 真机功能验证汇总(第二次复测)

| 验证项 | 手段 | 结果 |
|---|---|---|
| 触摸初始化 | 复位 3 次看日志 | ✅ 3/3 `Successfully initialized LCD touch` |
| 显示 / 背光 | 启动日志 | ✅ `st7796_general: LCD panel create success`;`ledc_ctrl: channel=0, default_percent=100%, duty=1023` |
| 音频 codec | 启动日志 | ✅ `audio_dac` / `audio_adc` 均 `Successfully initialized codec`(es8311) |
| C6 建链 | 启动日志 | ✅ `Identified slave [esp32c6]` / `Transport active`(但有版本告警,见 §7) |
| Wi-Fi STA | `wifi` / 日志 | ✅ 已连 `guest-it`,STA IP `172.16.103.225`;配网 AP `esp-claw-000000 @ 192.168.4.1` 同时在线 |
| LLM / Agent | 启动日志 | ✅ `Starting root agent backend=openai_compatible base_url=https://api.deepseek.com model=deepseek-flash token=configured` |
| 内存水位(`mem-dump`) | 运行时 | ✅ 内部堆 当前 392,995 B / 历史最低 351,728 B;PSRAM 当前 28,488,636 B / 历史最低 28,464,536 B |
| Lua 引擎 | `cap_lua` | ✅ `lua --run --path /system/skills/builtin_lua_modules/scripts/builtin/test/json_roundtrip.lua` → `json_roundtrip ok` |
| 事件驱动链路 | `event_router` | ✅ 见下 |
| 长时记忆 | `memory_list` | ✅ 修复后 `ok:true`(见 §5.4) |

事件驱动链路验证(临时规则,**验完即删**,不动用户配置):

```text
event_router --add-rule-json {"id":"m0_smoke_rule","enabled":true,"ack":"m0 trigger ok",
  "match":{"event_type":"m0_smoke","event_key":"smoke1"},"actions":[{"type":"drop"}]}
  -> {"ok":true,"id":"m0_smoke_rule"}
event_router --emit-trigger --source-cap app_claw --event-type m0_smoke --event-key smoke1 --payload-json {"n":1}
  -> claw_event_router: event=evt-… type=m0_smoke source=app_claw
     claw_event_router: matched rule=m0_smoke_rule actions=1
event_router --last
  -> matched=true matched_rules=1 action_count=1 failed_actions=0 route=1
     first_rule_id=m0_smoke_rule  ack=m0 trigger ok  last_error=ESP_OK
event_router --delete-rule m0_smoke_rule   -> {"ok":true,"id":"m0_smoke_rule"}
```

> 设备上已加载 8 条路由规则(`/fatfs/router_rules/router_rules.json`)与 3 条调度项
> (`/fatfs/scheduler/schedules.json`);其中 `startup_run_led_strip_dim_white` 是一条
> **Lua 驱动的规则**(`run_script` → `/fatfs/skills/light_switch/scripts/led_strip_switch.lua`),
> 默认 `enabled: false`,证明 "规则 → Lua" 通路在规则集中已具备。
> Lua 脚本在设备上的实际根为 `/system/skills/builtin_lua_modules/scripts/builtin/test/`
> (`lua --run` 只接受**绝对** `.lua` 路径)。


## 6. 复现方式

```bash
source /Users/diyvan/.espressif/tools/activate_idf_v6.1.sh
solutions/ha_ai_panel/scripts/setup_esp_claw.sh   # 克隆 esp-claw + 应用补丁 + 叠加板级 + bmgr
cd solutions/ha_ai_panel/esp-claw/application/edge_agent && idf.py build
```

脚本一览(`solutions/ha_ai_panel/scripts/`):

| 脚本 | 作用 | 是否需沙箱外 |
|---|---|---|
| `setup_esp_claw.sh` | 拉上游 + 打补丁 + 叠加板级 + 生成 bmgr 配置 | 否(但需可写 IDF 目录) |
| `flash_verify.sh` | 构建 + 烧录 + 抓串口日志一条龙 | **是** |
| `check_idf_regression.sh` | 报告 IDF 补丁状态 + 用既有示例做回归构建 | 否 |

补丁以 `git apply` 方式应用,可重复执行(已应用则跳过)。上游源码克隆后由
[.gitignore](../../../.gitignore) 排除,不入库。

> 脚本自带 `idf.py` 兜底:本机 eim 激活脚本把 `idf.py` 定义为**当前 shell 的函数**,
> 子进程(脚本)不可见;脚本在找不到可执行的 `idf.py` 时会回退为
> `$IDF_PYTHON_ENV_PATH/bin/python $IDF_PATH/tools/idf.py`,故只需在当前 shell 里
> `source` 过激活脚本(环境变量已导出)即可运行本脚本,无需额外包装。

首次运行前需 `pip install esp-bmgr-assist`。构建 esp-claw 会**就地修改 IDF 安装目录**
(见 §4.1),受限沙箱/只读 IDF 下需在沙箱外执行。

## 7. 待办

### 已完成(开发机)

- [x] 回归构建:esp-claw 就地改过 IDF 后,`examples/esp-idf/` 既有示例仍可构建
      (`02_HelloWorld` + `11_esp_brookesia_phone` 均通过,见 §4.1)
- [x] 决定是否为路线 B 使用独立 IDF 安装 —— **不需要**(见 §4.1)
- [x] M1 板级扩展:ST7796 + FT6336 写入 YAML,bmgr 校验收口(6 外设 / 7 设备)
- [x] 定位并修复 `lcd_panel_factory_entry_t` / `lcd_touch_factory_entry_t` 链接错误
      (板级 `setup_device.c` 补两个工厂钩子,见 §5.1)

### 已完成(真机)

- [x] **M1 构建收尾**:链接错误消失,`idf.py build` 绿灯(edge_agent.bin 0x381680,占 16MB
      应用分区 88%,余 0x7e980)
- [x] **烧录本固件**:7 镜像全部 `Hash of data verified` 并成功启动
      (bootloader → 板级外设 → LCD/触摸 → ESP-Hosted/C6 → 配网 AP → Agent Loop → `Returned from app_main()`)
- [x] **修复「bootloader 后完全静默」**:console 主口由 USB-JTAG 改回 UART0(见 §5.2)
- [x] **修复触摸初始化回归**:板级 early init 补 GPIO29 复位释放,复位 3/3 通过(见 §5.3)
- [x] **修复长时记忆失效**:删除空的 `memory_index.json` / `memory_records.jsonl`,
      初始化自动重建,`memory_list` 恢复(见 §5.4)
- [x] **记录 heap / PSRAM 水位**(`mem-dump`):内部堆当前 384 KiB / 最低 343 KiB;
      PSRAM 当前 27.2 MB / 最低 27.1 MB(见 §5.5)
- [x] **执行 Lua + 事件驱动链路**:`json_roundtrip ok`;临时触发器规则命中
      `matched=true route=1 failed_actions=0`(见 §5.5)
- [x] **配 LLM 后可对话 + Wi-Fi STA 已连通**:`guest-it` → STA IP `172.16.103.225`(见 §5.5)

### 待办(真机,后续里程碑)

- [ ] 目视确认屏能亮、背光可控、触摸有坐标(日志已确认三者初始化成功,缺肉眼确认)
- [ ] 确认 C6 协处理器固件版本(`transport: Version mismatch: Host [2.12.0] > Co-proc [0.0.0]`)

烧录流程见 [docs/flash.md](../../../docs/flash.md);本板 rev1.3,串口
`/dev/tty.usbmodem5B910423531`(可用 `PORT=...` 覆盖)。
