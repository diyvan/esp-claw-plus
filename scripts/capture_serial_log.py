#!/usr/bin/env python
"""Capture ESP32-P4 boot logs over USB-Serial/JTAG, surviving USB re-enumeration."""
import argparse
import sys
import time

import serial

PORT = "/dev/tty.usbmodem5B910423531"
BAUD = 115200
DURATION = 35


def release_lines(port_obj):
    """USB-Serial/JTAG: 系统在打开串口时会拉高 DTR/RTS, 相当于摁住芯片复位,
    必须显式释放, 否则读不到任何日志。"""
    try:
        port_obj.dtr = False
        port_obj.rts = False
    except Exception:
        pass


def reset_chip(port):
    """Pulse RTS (EN) to force a clean reset; ignore errors on close."""
    try:
        p = serial.Serial(port, BAUD, timeout=0.5)
    except Exception as e:
        print("reset: open failed:", e)
        return
    try:
        p.rts = True
        time.sleep(0.1)
        p.rts = False
        time.sleep(0.1)
    except Exception as e:
        print("reset: toggle failed:", e)
    finally:
        try:
            p.close()
        except Exception:
            pass


def read_port(port, duration, buf):
    """Read from port, reconnecting if USB re-enumerates."""
    p = None
    end = time.time() + duration
    while time.time() < end:
        try:
            if p is None:
                p = serial.Serial(port, BAUD, timeout=0.5)
                release_lines(p)
            chunk = p.read(4096)
            if chunk:
                buf.extend(chunk)
        except (serial.SerialException, OSError, ValueError):
            if p is not None:
                try:
                    p.close()
                except Exception:
                    pass
                p = None
                time.sleep(0.5)
    if p is not None:
        try:
            p.close()
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default=PORT, help="serial port (default: %(default)s)")
    parser.add_argument(
        "--duration", type=float, default=DURATION,
        help="capture seconds (default: %(default)s)",
    )
    args = parser.parse_args()

    buf = bytearray()
    reset_chip(args.port)
    time.sleep(1.0)
    read_port(args.port, args.duration, buf)
    text = buf.decode("utf-8", errors="replace")
    # Keep the last 8KB, enough for app_main logs or a panic backtrace
    sys.stdout.write(text[-8192:])
    sys.stdout.write("\n=== CAPTURED %d BYTES ===\n" % len(buf))


if __name__ == "__main__":
    main()
