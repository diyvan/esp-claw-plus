/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5 board setup.
 *
 * 本板无需额外外设供电时序:
 * - SD 卡由 P4 片上 LDO 通道 4 供电(board_devices.yaml 中 ldo_chan_id: 4),
 *   与 p4_nano 的 GPIO46 SD_EN 不同, 勿复制其 SD 电源控制代码。
 * - 外设电源轨由 AXP2101 PMIC 管理, 出厂默认全部使能, 无需显式初始化。
 *
 * 唯一必须做的时序: 触摸控制器 FT6336 的复位线(GPIO29)。
 * board manager 在创建触摸设备前会先 i2c_master_probe 探测地址, 而 FT6336 的复位
 * 脉冲是 esp_lcd_touch_new_i2c_ft5x06 内部才做的 —— 即探测发生在复位之前。上电后
 * GPIO29 为浮空输入, 触摸芯片可能一直处于复位态而不应答, 探测失败:
 *   E DEV_LCD_TOUCH_SUB_I2C: No LCD touch found on I2C bus: i2c_master
 * 故在板级 early init(构造函数, 早于 app_main/board manager)里先给一次复位脉冲并释放,
 * 使芯片先进入可应答状态。
 *
 * display_lcd(sub_type: spi) 与 lcd_touch(sub_type: i2c) 设备由 board manager
 * 通用代码驱动, 但面板/触摸控制器驱动由板级自身提供, 故须在此实现两个工厂钩子:
 *   lcd_panel_factory_entry_t -> esp_lcd_new_panel_st7796 (ST7796 SPI 控制器)
 *   lcd_touch_factory_entry_t -> esp_lcd_touch_new_i2c_ft5x06 (FT6336, FT5x06 家族)
 * mirror/invert/swap_xy 由 board manager 依据 board_devices.yaml 统一施加。
 */
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_lcd_st7796.h"
#include "esp_lcd_touch_ft5x06.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "P4_WIFI6_LCD35_SETUP";

/* 与 board_devices.yaml 中 lcd_touch.touch_config.rst_gpio_num 保持一致 */
#define BOARD_LCD_TOUCH_RST_GPIO 29

static void p4_wifi6_lcd35_touch_reset_release(void)
{
    const gpio_config_t io_config = {
        .pin_bit_mask = 1ULL << BOARD_LCD_TOUCH_RST_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io_config));

    /* FT6336 复位低有效: 拉低 -> 释放(拉高) -> 等待内部启动 */
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

esp_err_t lcd_panel_factory_entry_t(esp_lcd_panel_io_handle_t io,
                                    const esp_lcd_panel_dev_config_t *panel_dev_config,
                                    esp_lcd_panel_handle_t *ret_panel)
{
    esp_err_t ret = esp_lcd_new_panel_st7796(io, panel_dev_config, ret_panel);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create ST7796 panel: %s", esp_err_to_name(ret));
    }
    return ret;
}

esp_err_t lcd_touch_factory_entry_t(esp_lcd_panel_io_handle_t io,
                                    const esp_lcd_touch_config_t *touch_dev_config,
                                    esp_lcd_touch_handle_t *ret_touch)
{
    esp_err_t ret = esp_lcd_touch_new_i2c_ft5x06(io, touch_dev_config, ret_touch);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create FT5x06 touch driver: %s", esp_err_to_name(ret));
    }
    return ret;
}
