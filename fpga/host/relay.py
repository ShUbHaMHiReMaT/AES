#!/usr/bin/env python3
"""
relay.py -- bridge the board's USB-UART to the network, for the Kali laptop.

Runs on the WINDOWS laptop (the one the Nexys A7 is plugged into). It opens
the board's COM port and a TCP server; every byte from one side is forwarded
verbatim to the other. The relay understands nothing about the AES protocol --
it is a transparent pipe -- so the attack scripts on Kali talk to the board
exactly as if the serial port were local.

    python fpga/host/relay.py                 # COM auto-detect, listen 0.0.0.0:5555
    python fpga/host/relay.py --port COM9 --baud 1000000 --listen 0.0.0.0:5555

Then on Kali:  python fpga/attack/attack.py --server <windows-ip>:5555 ...

It is meant to stay up: the TCP listener never closes, clients are served one
at a time, and if the serial port drops (e.g. the FPGA is reprogrammed) it is
reopened automatically. Nothing here changes the board or its normal
operation -- the same relay works for aes_board_test.py over TCP too.
"""
import argparse
import socket
import sys
import threading
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
        sys.exit(f"no Digilent/FTDI port found (present: {present or 'none'})")
    return sorted(ports, key=lambda p: p.device)[-1].device


class SerialHub:
    """A serial port that reopens itself if the handle goes bad."""

    def __init__(self, port, baud):
        self.port, self.baud = port, baud
        self.ser = None
        self.lock = threading.Lock()
        self._open()

    def _open(self):
        while True:
            try:
                self.ser = serial.Serial(self.port, self.baud, timeout=0.02)
                return
            except serial.SerialException as e:
                print(f"  waiting for {self.port}: {e}")
                time.sleep(1.0)

    def reopen(self):
        with self.lock:
            try:
                if self.ser:
                    self.ser.close()
            except Exception:
                pass
            self._open()
            print(f"  serial {self.port} reopened")

    def read(self, n):
        try:
            return self.ser.read(n)
        except (OSError, serial.SerialException):
            self.reopen()
            return b""

    def write(self, b):
        try:
            self.ser.write(b)
        except (OSError, serial.SerialException):
            self.reopen()

    def reset(self):
        try:
            self.ser.reset_input_buffer()
            self.ser.reset_output_buffer()
        except Exception:
            pass


def pump(src_read, dst_write, stop):
    try:
        while not stop.is_set():
            data = src_read()
            if data:
                dst_write(data)
    except OSError:
        pass
    finally:
        stop.set()


def serve(hub, host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"Relay up: {hub.port} @ {hub.baud} baud  <->  TCP {host}:{port}", flush=True)
    print("Listening (stays up; Ctrl-C to quit)...", flush=True)
    while True:
        try:
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            print("\nbye")
            return
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"  client connected: {addr[0]}:{addr[1]}", flush=True)
        hub.reset()
        stop = threading.Event()
        t1 = threading.Thread(target=pump,
                              args=(lambda: hub.read(4096), conn.sendall, stop),
                              daemon=True)

        def sock_read():
            conn.settimeout(0.02)
            try:
                return conn.recv(4096)
            except socket.timeout:
                return b""
            except OSError:
                return b""

        t2 = threading.Thread(target=pump,
                              args=(sock_read, hub.write, stop), daemon=True)
        t1.start(); t2.start()
        try:
            stop.wait()
        except KeyboardInterrupt:
            print("\nbye")
            conn.close()
            return
        try:
            conn.close()
        except Exception:
            pass
        print("  client disconnected (still listening)", flush=True)


def main():
    ap = argparse.ArgumentParser(description="USB-UART <-> TCP relay for the Nexys A7")
    ap.add_argument("--port", help="COM port (default: auto-detect FTDI)")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--listen", default="0.0.0.0:5555", help="host:port to listen on")
    args = ap.parse_args()

    host, _, port = args.listen.partition(":")
    hub = SerialHub(args.port or find_port(), args.baud)
    try:
        serve(hub, host or "0.0.0.0", int(port))
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
