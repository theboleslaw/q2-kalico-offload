#!/usr/bin/env python3
"""PTY <-> TCP bridge for a remote Klipper MCU serial proxy.

Unlike socat, this keeps one PTY (and its symlink) for the life of the
process and reconnects the TCP side internally.  Klipper can therefore keep
the same serial device open across printer-host reboots; it never sees the
PTY disappear while a bridge reconnects.

Usage: q2-pty-bridge.py <name:port>
Environment:
  Q2_BRIDGE_HOST  remote proxy host (default 192.168.2.210)
  Q2_BRIDGE_DIR   directory for the q2-<name> symlink
                  (default /home/cloud/printer_data/comms)
"""
import errno
import os
import pty
import select
import signal
import socket
import sys
import termios
import time
import tty

HOST = os.environ.get("Q2_BRIDGE_HOST", "192.168.2.210")
LINK_DIR = os.environ.get("Q2_BRIDGE_DIR", "/home/cloud/printer_data/comms")
BUF = 4096

stop = False


def log(msg):
    print(msg, flush=True)


def _stop(signum, frame):
    global stop
    stop = True


def open_pty(link):
    master, slave = pty.openpty()
    os.set_blocking(master, False)
    tty.setraw(slave)
    # Keep our own slave fd open: it keeps the pty alive when Klipper closes
    # or restarts, so the master never starts returning EIO.
    path = os.ttyname(slave)
    try:
        os.unlink(link)
    except FileNotFoundError:
        pass
    os.symlink(path, link)
    log("pty %s -> %s" % (link, path))
    return master, slave, path


def drain(fd):
    """Discard pending bytes so an idle pty cannot fill up."""
    while True:
        try:
            data = os.read(fd, BUF)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno in (errno.EIO, errno.EBADF):
                return
            raise
        if not data:
            return


def write_master(master, data):
    while data and not stop:
        try:
            n = os.write(master, data)
        except BlockingIOError:
            select.select([], [master], [], 0.5)
            continue
        data = data[n:]


def connect(master):
    while not stop:
        try:
            s = socket.create_connection((HOST, PORT), timeout=3)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            log("tcp connected to %s:%d" % (HOST, PORT))
            return s
        except OSError as e:
            log("tcp connect %s:%d failed: %s" % (HOST, PORT, e))
            drain(master)
            time.sleep(1)
    return None


def serve(master, sock):
    # Start each TCP session from a clean pty input queue.
    drain(master)
    while not stop:
        try:
            r, _, _ = select.select([master, sock], [], [], 0.5)
        except InterruptedError:
            continue
        if sock in r:
            try:
                data = sock.recv(BUF)
            except OSError:
                data = b""
            if not data:
                log("tcp peer closed")
                return
            try:
                write_master(master, data)
            except OSError as e:
                log("pty write failed: %s" % e)
                return
        if master in r:
            try:
                data = os.read(master, BUF)
            except BlockingIOError:
                continue
            except OSError as e:
                if e.errno in (errno.EIO, errno.EBADF):
                    log("pty read failed: %s" % e)
                    return
                raise
            if not data:
                return
            try:
                sock.sendall(data)
            except OSError:
                log("tcp send failed")
                return


def main():
    global PORT
    if len(sys.argv) != 2 or ":" not in sys.argv[1]:
        print("usage: %s <name:port>" % sys.argv[0], file=sys.stderr)
        return 2
    name, port = sys.argv[1].split(":", 1)
    PORT = int(port)
    link = os.path.join(LINK_DIR, "q2-" + name)
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    master, slave, path = open_pty(link)
    log("bridging %s <-> %s:%d" % (link, HOST, PORT))
    try:
        while not stop:
            sock = connect(master)
            if sock is None:
                break
            try:
                serve(master, sock)
            finally:
                sock.close()
            if not stop:
                log("reconnecting")
                time.sleep(1)
    finally:
        try:
            if os.readlink(link) == path:
                os.unlink(link)
        except OSError:
            pass
        os.close(master)
        os.close(slave)
    return 0


if __name__ == "__main__":
    sys.exit(main())
