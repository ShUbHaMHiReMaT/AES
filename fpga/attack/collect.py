#!/usr/bin/env python3
"""
collect.py -- capture power traces from the board (local serial or over TCP).

Speaks the trace-capture extension of the host protocol (command 0x50) added
to fpga/rtl/aes_uart_bridge.v. For each plaintext it asks the FPGA to encrypt
one block while the on-chip TDC sensor records TRACE_LEN samples, then reads
back the ciphertext and the raw trace.

Transport is either a local COM port or the relay.py TCP bridge, so the same
code runs on the Windows laptop or on Kali:

    from collect import connect
    dev = connect(server="192.168.1.20:5555")   # via relay on the Windows PC
    dev = connect(port="COM9")                   # local

Nothing here changes the board's normal behaviour; 0x50 is an added command.
"""
import socket
import struct
import sys
import time

import numpy as np

CMD_CAPTURE = 0x50
RESP = 22
CORE_NAMES = {1: "iterative", 2: "ii10", 3: "pipelined"}


class Transport:
    """Minimal read-exactly / write byte pipe over serial or TCP."""

    def __init__(self, ser=None, sock=None):
        self.ser, self.sock = ser, sock

    def write(self, b):
        (self.ser.write if self.ser else self.sock.sendall)(b)

    def read_exact(self, n, timeout=5.0):
        buf = bytearray()
        t0 = time.time()
        while len(buf) < n:
            if time.time() - t0 > timeout:
                raise TimeoutError(f"got {len(buf)} of {n} bytes")
            if self.ser:
                chunk = self.ser.read(n - len(buf))
            else:
                try:
                    chunk = self.sock.recv(n - len(buf))
                except socket.timeout:
                    chunk = b""
            if chunk:
                buf += chunk
        return bytes(buf)

    def flush_input(self):
        if self.ser:
            self.ser.reset_input_buffer()
        else:
            self.sock.settimeout(0.05)
            try:
                while self.sock.recv(4096):
                    pass
            except OSError:
                pass
            self.sock.settimeout(5.0)


def connect(port=None, server=None, baud=1_000_000):
    if server:
        host, _, p = server.partition(":")
        s = socket.create_connection((host, int(p or 5555)), timeout=5.0)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.settimeout(5.0)
        return Transport(sock=s)
    import serial
    import serial.tools.list_ports
    if not port:
        ftdi = [p for p in serial.tools.list_ports.comports() if p.vid == 0x0403]
        if not ftdi:
            sys.exit("no FTDI port found; pass --port or run via --server")
        port = sorted(ftdi, key=lambda p: p.device)[-1].device
    return Transport(ser=serial.Serial(port, baud, timeout=2.0))


def capture(dev, core, plaintext, key, protected=False):
    """Capture one trace. Returns (ciphertext bytes, trace np.uint8[TRACE_LEN])."""
    arg = (core & 0xFF) | ((1 << 8) if protected else 0)
    req = bytes([CMD_CAPTURE]) + struct.pack(">I", arg) + bytes(key) + bytes(plaintext)
    dev.write(req)
    r = dev.read_exact(RESP)
    if r[0] != CMD_CAPTURE:
        raise IOError(f"bad reply 0x{r[0]:02x} to capture (is 0x50 in the bitstream?)")
    trace_len = struct.unpack(">I", r[2:6])[0]
    ct = r[6:22]
    trace = np.frombuffer(dev.read_exact(trace_len), dtype=np.uint8)
    return ct, trace


def capture_set(dev, core, plaintexts, key, protected=False, progress=True):
    """Capture a trace per plaintext. plaintexts: (n,16) uint8. Returns traces (n,L)."""
    traces, n = [], len(plaintexts)
    for i, pt in enumerate(plaintexts):
        _, tr = capture(dev, core, bytes(pt), key, protected)
        traces.append(tr)
        if progress and (i % 200 == 0 or i == n - 1):
            print(f"\r  captured {i + 1}/{n} traces", end="", flush=True)
    if progress:
        print()
    L = min(len(t) for t in traces)
    return np.stack([t[:L] for t in traces]).astype(np.float64)


def save(path, traces, plaintexts, key=None, meta=None):
    np.savez_compressed(path, traces=traces, plaintexts=plaintexts,
                        key=(np.frombuffer(bytes(key), np.uint8) if key else np.array([])),
                        meta=np.array([str(meta or {})]))
    print(f"saved {traces.shape} traces -> {path}")


def load(path):
    d = np.load(path, allow_pickle=True)
    key = bytes(d["key"]) if d["key"].size else None
    return d["traces"], d["plaintexts"].astype(np.uint8), key
