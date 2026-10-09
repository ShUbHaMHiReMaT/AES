#!/usr/bin/env python3
"""
uart_echo_test.py -- check the USB-UART link against fpga/smoke/smoke_top.v.

Sends every byte value 0x00..0xFF a few times and expects each one back.

    python fpga/host/uart_echo_test.py [--port COM7]
"""

import argparse
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("pyserial is missing:  python -m pip install pyserial")


def find_port():
    ports = [p for p in serial.tools.list_ports.comports() if p.vid == 0x0403]
    if not ports:
        present = ", ".join(p.device for p in serial.tools.list_ports.comports())
        sys.exit("no Digilent/FTDI serial port found "
                 f"(ports present: {present or 'none'})")
    return sorted(ports, key=lambda p: p.device)[-1].device


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--rounds", type=int, default=4)
    args = ap.parse_args()

    port = args.port or find_port()
    print(f"Port: {port} @ {args.baud} baud")
    with serial.Serial(port, args.baud, timeout=1.0) as ser:
        time.sleep(0.05)
        ser.reset_input_buffer()

        msg = b"hello nexys"
        ser.write(msg)
        back = ser.read(len(msg))
        print(f"  sent {msg!r}  got {back!r}")
        if back != msg:
            print("RESULT: FAIL -- echo did not match (is smoke.bit loaded?)")
            return 1

        payload = bytes(range(256)) * args.rounds
        t0 = time.perf_counter()
        ser.write(payload)
        back = ser.read(len(payload))
        dt = time.perf_counter() - t0
        bad = sum(1 for a, b in zip(payload, back) if a != b) + abs(len(payload) - len(back))
        print(f"  {len(payload)} bytes, {bad} wrong, {len(back) / dt:.0f} bytes/s")
        print("RESULT: PASS" if bad == 0 else "RESULT: FAIL")
        return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
