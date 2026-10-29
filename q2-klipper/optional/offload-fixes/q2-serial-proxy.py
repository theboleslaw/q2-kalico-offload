#!/usr/bin/env python3
# TCP <-> printer MCU serial proxy for offload mode.
# Opens the serial device once and keeps it open; serves one allowed client at a time.
import ipaddress
import os
import select
import socket
import sys
import time

import serial

DEVICE = os.environ["DEVICE"]
PORT = int(os.environ["PORT"])
ALLOW = ipaddress.ip_network(os.environ.get("ALLOW", "0.0.0.0/0"), strict=False)
BAUD = int(os.environ.get("BAUD", "500000"))


def log(msg):
    print(msg, flush=True)


def open_serial():
    while True:
        try:
            ser = serial.Serial(DEVICE, baudrate=BAUD, timeout=0, exclusive=True)
            ser.rts = True
            ser.dtr = True
            log("serial open: %s" % DEVICE)
            return ser
        except (OSError, serial.SerialException) as e:
            log("waiting for %s: %s" % (DEVICE, e))
            time.sleep(2)


def serve(conn, ser):
    while True:
        readable, _, _ = select.select([conn, ser], [], [], 0.5)
        if conn in readable:
            data = conn.recv(4096)
            if not data:
                return
            ser.write(data)
        if ser in readable:
            data = ser.read(4096)
            if data:
                conn.sendall(data)


def main():
    ser = open_serial()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(4)
    log("listening on %d, allow %s" % (PORT, ALLOW))
    while True:
        conn, addr = srv.accept()
        if ipaddress.ip_address(addr[0]) not in ALLOW:
            log("refused %s" % (addr,))
            conn.close()
            continue
        log("client %s" % (addr,))
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            serve(conn, ser)
        except (OSError, serial.SerialException) as e:
            log("session error: %s" % e)
            ser.close()
            ser = open_serial()
        finally:
            conn.close()
            log("client %s gone" % (addr,))


if __name__ == "__main__":
    sys.exit(main())
