#!/usr/bin/env python
"""把语音路由规则安装到设备的 /fatfs/router_rules/router_rules.json。

设备端 `event_router --add-rule-json` 会把新规则插入到规则数组**最前面**, 因此语音规则
会排在默认规则 `agent_out_message_send_message` 之前, 从而优先被匹配。

用法 (需要 pyserial, 建议用 ESP-IDF 的 python 环境):
    python install_voice_rules.py
    python install_voice_rules.py --port /dev/tty.usbmodem5B910423531
    python install_voice_rules.py --rules ../app/router_rules/voice_rules.json ../app/router_rules/local_rules.json

注意: 打开串口会让芯片复位一次, 脚本会等待 REPL 提示符 "app> " 后再下命令。
"""

import argparse
import json
import os
import sys
import time

import serial

DEFAULT_PORT = "/dev/tty.usbmodem5B910423531"
BAUD = 115200
PROMPT = b"app> "

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_RULES = [
    os.path.join(SCRIPT_DIR, "..", "app", "router_rules", "voice_rules.json"),
    os.path.join(SCRIPT_DIR, "..", "app", "router_rules", "local_rules.json"),
]


def wait_for_prompt(port, timeout_s):
    deadline = time.time() + timeout_s
    buf = bytearray()
    next_probe = 0.0
    while time.time() < deadline:
        # 主动敲回车逼出提示符: 设备可能已经启动完毕并在等待输入, 此时不会自发打印 "app> "。
        if time.time() >= next_probe:
            try:
                port.write(b"\r\n")
                port.flush()
            except Exception:
                pass
            next_probe = time.time() + 2.0
        chunk = port.read(4096)
        if chunk:
            buf.extend(chunk)
            if PROMPT in bytes(buf):
                return True
    sys.stderr.write("等待 REPL 提示符超时, 已收到 %d 字节\n" % len(buf))
    return False


def send_command(port, line, wait_s=6.0, retries=4):
    # 逐字节慢速下发: 设备控制台在忙(持续打印日志)时会丢/拆长输入行, 导致长规则的 JSON
    # 被截断而报 "invalid rule_json structure" 或 "Unrecognized command"。逐字节 + 小幅
    # 延时给 RX 队列留出排空时间; 若仍失败(响应里出现损坏特征)则重试。
    payload = (line + "\r\n").encode()
    text = ""
    for attempt in range(retries):
        port.reset_input_buffer()
        for byte in payload:
            port.write(bytes([byte]))
            port.flush()
            time.sleep(0.004)

        deadline = time.time() + wait_s
        buf = bytearray()
        while time.time() < deadline:
            chunk = port.read(4096)
            if chunk:
                buf.extend(chunk)
                if PROMPT in bytes(buf):
                    break
        text = buf.decode("utf-8", errors="replace")
        low = text.lower()
        if "unrecognized command" not in low and "invalid rule_json" not in low:
            return text
        time.sleep(0.3)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default=DEFAULT_PORT, help="serial port (default: %(default)s)")
    parser.add_argument("--rules", nargs="+", default=DEFAULT_RULES,
                        help="one or more rules json files (default: %(default)s)")
    parser.add_argument(
        "--boot-wait", type=float, default=30.0,
        help="seconds to wait for the REPL prompt (default: %(default)s)",
    )
    args = parser.parse_args()

    rules = []
    for rules_path in args.rules:
        with open(rules_path, "r", encoding="utf-8") as fp:
            loaded = json.load(fp)
        if not isinstance(loaded, list) or not loaded:
            sys.stderr.write("规则文件必须是非空 JSON 数组: %s\n" % rules_path)
            return 1
        rules.extend(loaded)

    port = serial.Serial(args.port, BAUD, timeout=0.5)
    # USB-Serial/JTAG: 打开串口会拉高 DTR/RTS(相当于复位), 必须显式释放
    try:
        port.dtr = False
        port.rts = False
    except Exception:
        pass

    if not wait_for_prompt(port, args.boot_wait):
        port.close()
        return 1

    rc = 0
    for rule in rules:
        compact = json.dumps(rule, ensure_ascii=False, separators=(",", ":"))
        line = "event_router --add-rule-json '%s'" % compact
        out = send_command(port, line)
        print("--- %s ---" % rule.get("id", "(no id)"))
        print(out.strip())
        if "invalid" in out.lower() or "error" in out.lower():
            rc = 1

    print("--- event_router --rules ---")
    print(send_command(port, "event_router --rules", wait_s=8.0).strip())

    port.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())