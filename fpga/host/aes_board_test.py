#!/usr/bin/env python3
"""
aes_board_test.py -- verify the AES-128 cores running on the Nexys A7.

Talks to fpga/rtl/aes_uart_bridge.v (protocol v2, 1 Mbaud) over the board's
USB-UART and checks every ciphertext the FPGA returns against
model/aes_golden.py, the same independent reference the simulations use.

    python fpga/host/aes_board_test.py                 # auto-detect port
    python fpga/host/aes_board_test.py -n 1000 --port COM9

Checks, per core: published KATs + random vectors (latency must be 11),
then a hardware benchmark whose XOR checksum is recomputed here.
Exit status 0 only if everything is correct.
"""

import argparse
import os
import random
import struct
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("pyserial is missing:  python -m pip install pyserial")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "model"))
from aes_golden import KAT, enc_hex  # noqa: E402

CORES = {1: "aes128_iterative", 2: "aes128_iterative_ii10", 3: "aes128_pipelined"}
II = {1: 11, 2: 10, 3: 1}
ID_STRING = b"AES128-NEXYSA7v2"
REQ, RESP = 37, 22
WINDOW = 32            # requests in flight; the FPGA's FIFO holds 110
CLK_HZ = 100e6


class BoardError(Exception):
    pass


def find_port():
    ports = [p for p in serial.tools.list_ports.comports() if p.vid == 0x0403]
    if not ports:
        present = ", ".join(p.device for p in serial.tools.list_ports.comports())
        raise BoardError("no Digilent/FTDI serial port found "
                         f"(ports present: {present or 'none'})")
    return sorted(ports, key=lambda p: p.device)[-1].device


def frame(cmd, arg=0, key=b"\0" * 16, data=b"\0" * 16):
    return bytes([cmd]) + struct.pack(">I", arg) + key + data


class Board:
    def __init__(self, port, baud):
        self.ser = serial.Serial(port, baud, timeout=2.0)
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    def set_timeout(self, timeout):
        # On Windows, assigning pyserial's timeout re-applies the whole port
        # configuration, which can glitch bytes already being sent. Only
        # change it when it differs, and only with nothing in flight.
        if self.ser.timeout != timeout:
            self.ser.timeout = timeout

    def read_resp(self, cmd):
        r = self.ser.read(RESP)
        if len(r) != RESP:
            time.sleep(0.05)
            self.ser.reset_input_buffer()
            raise BoardError(f"short response: {len(r)} of {RESP} bytes")
        if r[0] != cmd:
            raise BoardError(f"response 0x{r[0]:02x} to command 0x{cmd:02x} ({r.hex()})")
        status = r[1]
        aux = struct.unpack(">I", r[2:6])[0]
        return status, aux, r[6:]

    def transact(self, cmd, arg=0, key=b"\0" * 16, data=b"\0" * 16, timeout=2.0):
        self.set_timeout(timeout)
        self.ser.write(frame(cmd, arg, key, data))
        return self.read_resp(cmd)

    def encrypt_many(self, core, pairs):
        """Pipelined: keep WINDOW requests in flight. Returns [(ct_hex, latency)]."""
        out, sent = [], 0
        self.set_timeout(2.0)
        while len(out) < len(pairs):
            while sent < len(pairs) and sent - len(out) < WINDOW:
                k, p = pairs[sent]
                self.ser.write(frame(core, 0, bytes.fromhex(k), bytes.fromhex(p)))
                sent += 1
            status, lat, ct = self.read_resp(core)
            out.append((ct.hex(), lat))
        return out


def main():
    ap = argparse.ArgumentParser(description="AES-128 on-board verification")
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("-n", "--num-random", type=int, default=500)
    ap.add_argument("--bench", type=int, default=1 << 20, help="benchmark blocks per core")
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()

    try:
        port = args.port or find_port()
        print(f"Port: {port} @ {args.baud} baud")
        b = Board(port, args.baud)

        st, aux, pl = b.transact(0x00)
        if pl != ID_STRING:
            raise BoardError(f"unexpected ID {pl!r} -- is aes_nexys_a7.bit loaded?")
        print(f"Board: {pl.decode()}  v{aux >> 24}, {(aux >> 16) & 0xff} MHz, "
              f"self-test {'PASS' if (st & 0x7f) == 0x47 else f'0x{st:02x}'}")
        errors = 0 if (st & 0x7f) == 0x47 else 1

        seed = args.seed if args.seed is not None else int(time.time())
        rng = random.Random(seed)
        pairs = [(k, p) for _, k, p, _ in KAT]
        pairs += [("%032x" % rng.getrandbits(128), "%032x" % rng.getrandbits(128))
                  for _ in range(args.num_random)]
        expect = [enc_hex(k, p) for k, p in pairs]
        print(f"Vectors: {len(KAT)} KATs + {args.num_random} random (seed {seed})\n")

        for core, name in CORES.items():
            t0 = time.perf_counter()
            res = b.encrypt_many(core, pairs)
            dt = time.perf_counter() - t0
            bad = [i for i, ((ct, lat), e) in enumerate(zip(res, expect)) if ct != e or lat != 11]
            for i in bad[:3]:
                print(f"    ERROR vector {i}: got {res[i][0]} lat {res[i][1]}, expected {expect[i]}")
            errors += len(bad)

            # hardware benchmark: XOR of E(key, seed + i), recomputed here
            n = args.bench
            key = bytes(rng.getrandbits(8) for _ in range(16))
            ctr0 = rng.getrandbits(128)
            st, cycles, chk = b.transact(0x10 + core, n, key, ctr0.to_bytes(16, "big"),
                                         timeout=n * II[core] / CLK_HZ + 3)
            gbps = n * 128 / (cycles / CLK_HZ) / 1e9
            # checking a full benchmark in pure Python is slow; check a short one
            m = 256
            st2, cyc2, chk2 = b.transact(0x10 + core, m, key, ctr0.to_bytes(16, "big"))
            acc = 0
            for i in range(m):
                acc ^= int(enc_hex(key.hex(), "%032x" % ((ctr0 + i) % (1 << 128))), 16)
            bench_ok = st == 0 and chk2 == acc.to_bytes(16, "big")
            errors += 0 if bench_ok else 1
            print(f"  {name:<24} {len(pairs)} blocks {'OK' if not bad else f'{len(bad)} BAD'}"
                  f" ({len(pairs) / dt:,.0f} blk/s over USB) | bench {n:,} blocks:"
                  f" {cycles:,} cycles = {gbps:.3f} Gbps @100 MHz"
                  f" {'(checksum OK)' if bench_ok else '(CHECKSUM BAD)'}")

        print("\n" + "=" * 62)
        print(" RESULT: ALL CORES CORRECT ON HARDWARE" if errors == 0
              else f" RESULT: {errors} FAILURE(S)")
        print("=" * 62)
        return 0 if errors == 0 else 1

    except (BoardError, serial.SerialException) as e:
        print(f"ERROR: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
