#!/usr/bin/env python3
"""Stand-in for droidcam-cli, for testing the plugin against the mock phone.

It accepts the same arguments and prints the same messages as droidcam-cli
2.1.5, speaks the same video protocol, but never opens a video device: the
frames are read and thrown away. Like the real client it does not exit when
the stream ends (it closes the socket and idles), and SIGINT exits cleanly.

Point the plugin at it with the "cliPath" setting:
  omarchy-shell io.github.saurasanchezpablo.droidcam configure \
    '{"cliPath":"<repo>/dev/fake_droidcam_cli.py","mode":"wifi","host":"127.0.0.1","port":4848}'

Environment:
  FAKE_DEVICE  device name to report (default /dev/video99)
  FAKE_USB     "ios" or "adb": pretend a phone is plugged in and connect to
               127.0.0.1 instead of failing with the usual USB errors
"""

import os
import select
import signal
import socket
import struct
import sys
import threading
import time

running = True


def err(msg):
    sys.stderr.write(msg)
    sys.stderr.flush()


def on_signal(_sig, _frame):
    global running
    running = False
    sys.exit(0)


def parse(argv):
    opts = {"audio": False, "video": False, "controls": True, "dev": "", "size": "640x480"}
    rest = []
    i = 1
    while i < len(argv) and argv[i].startswith("-") and argv[i] != "-l":
        a = argv[i]
        if a.startswith("-a"):
            opts["audio"] = True
        elif a.startswith("-dev="):
            opts["dev"] = a[5:]
        elif a.startswith("-size="):
            opts["size"] = a[6:]
        elif "nocontrols" in a:
            opts["controls"] = False
        elif a in ("-vflip", "-hflip"):
            pass
        elif a.startswith("-v"):
            opts["video"] = True
        i += 1
    rest = argv[i:]
    if len(rest) < 2:
        err("Usage: droidcam-cli [options] <ip> <port>\n")
        sys.exit(1)
    return opts, rest


def main():
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGHUP, on_signal)
    opts, rest = parse(sys.argv)
    mode, port = rest[0], int(rest[1])
    device = opts["dev"] or os.environ.get("FAKE_DEVICE", "/dev/video99")
    print("Client v2.1.5", flush=True)
    print(f"Video: {device}", flush=True)
    usb = os.environ.get("FAKE_USB", "")
    host = mode
    if mode == "ios":
        if usb != "ios":
            err("Error: No devices detected:\nMake sure usbmuxd service running and this computer is trusted.\n")
            sys.exit(1)
        host = "127.0.0.1"
    elif mode == "adb":
        if usb != "adb":
            err("Error: No devices detected:\nMake sure the device is connected and USB debugging is enabled.\n")
            sys.exit(1)
        host = "127.0.0.1"

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(2)
    try:
        sock.connect((host, port))
    except OSError:
        sock.close()
        err(f"Video: Connect failed to {host}:{port}\n")
        err("Connect failed, please try again.\nCheck IP and Port.\nCheck network connection.\n")
        sys.exit(0)
    sock.settimeout(5)
    w, h = opts["size"].split("x")
    pending = []

    def video():
        try:
            sock.sendall(f"CMD /v3/video/jpg/{w}x{h}".encode())
        except OSError as e:
            err(f"send error ({e.errno}) '{e.strerror}'\n")
            err("Error: Error sending request, DroidCam might be busy with another client.\n")
            sock.close()
            return
        try:
            header = b""
            while len(header) < 9:
                chunk = sock.recv(9 - len(header))
                if not chunk:
                    raise ConnectionResetError(104, "Connection reset by peer")
                header += chunk
        except OSError as e:
            err(f"recv error ({e.errno or 0}) '{e.strerror or e}'\n")
            err("Error: Connection reset!\nIs the app running?\n")
            sock.close()
            return
        try:
            while running:
                while pending:
                    sock.sendall(f"CMD /v1/ctl?{pending.pop(0)}".encode())
                raw = sock.recv(4)
                if len(raw) < 4:
                    break
                size = struct.unpack("<I", raw)[0]
                left = size
                while left > 0:
                    chunk = sock.recv(min(left, 65536))
                    if not chunk:
                        raise OSError("closed")
                    left -= len(chunk)
        except OSError:
            pass
        sock.close()

    threading.Thread(target=video, daemon=True).start()

    keys = {"+": 6, "=": 6, "-": 7, "a": 8, "A": 8, "l": 9, "L": 9}
    stdin_open = opts["controls"]
    while True:
        if stdin_open:
            ready, _, _ = select.select([sys.stdin], [], [], 0.5)
            if ready:
                ch = os.read(sys.stdin.fileno(), 1).decode("latin-1")
                if ch == "":
                    stdin_open = False
                elif ch in keys:
                    pending.append(keys[ch])
        else:
            time.sleep(0.5)


if __name__ == "__main__":
    main()
