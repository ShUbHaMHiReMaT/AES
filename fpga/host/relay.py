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

Only one client at a time (a trace capture is a single tight request/reply
loop and must not be interleaved). Nothing here changes the board or its
normal operation -- the same relay works for aes_board_test.py over TCP too.
"""
import argparse
import socket
import sys
import threading

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


def pump(src_read, dst_write, name, stop):
    try:
        while not stop.is_set():
            data = src_read()
            if data:
                dst_write(data)
    except (OSError, serial.SerialException):
        pass
    finally:
        stop.set()


def serve(ser, host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"Relay up: {ser.port} @ {ser.baudrate} baud  <->  TCP {host}:{port}")
    print("Waiting for a client (Ctrl-C to quit)...")
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"  client connected: {addr[0]}:{addr[1]}")
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        stop = threading.Event()
        # serial -> socket
        ser.timeout = 0.02
        t1 = threading.Thread(target=pump,
                              args=(lambda: ser.read(4096), conn.sendall,
                                    "ser->net", stop), daemon=True)

        def sock_read():
            conn.settimeout(0.02)
            try:
                return conn.recv(4096)
            except socket.timeout:
                return b""
            except OSError:
                return b""

        t2 = threading.Thread(target=pump,
                              args=(sock_read, ser.write, "net->ser", stop),
                              daemon=True)
        t1.start()
        t2.start()
        try:
            stop.wait()
        except KeyboardInterrupt:
            print("\nbye")
            conn.close()
            return
        conn.close()
        print("  client disconnected")


def main():
    ap = argparse.ArgumentParser(description="USB-UART <-> TCP relay for the Nexys A7")
    ap.add_argument("--port", help="COM port (default: auto-detect FTDI)")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--listen", default="0.0.0.0:5555", help="host:port to listen on")
    args = ap.parse_args()

    host, _, port = args.listen.partition(":")
    ser = serial.Serial(args.port or find_port(), args.baud, timeout=0.02)
    try:
        serve(ser, host or "0.0.0.0", int(port))
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        ser.close()


if __name__ == "__main__":
    main()
