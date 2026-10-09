#!/usr/bin/env python3
"""Fake DroidCam phone app for developing the plugin without a phone.

Serves, on one port like the real app:
  - the HTTP API (/v1/phone/name, /v1/phone/battery_info, /battery,
    /v1/camera/camera_list, /v1/camera/info, PUT camera controls)
  - the video protocol droidcam-cli speaks ("CMD /v3/video/jpg/WxH",
    a 9-byte header, then length-prefixed JPEG frames) and in-band
    controls ("CMD /v1/ctl?N")

Switch behaviour while it runs:
  curl -X POST http://127.0.0.1:4848/mock/scenario/<name>

Scenarios:
  free       streams; camera info is Pro-only (HTTP 550), like the free app
  pro        streams; camera info and PUT controls work
  busy       answers HTTP, but drops every video client at once
  drop       streams for 8 seconds, then ends the stream
  stopped    the app is open but stopped: HTTP 555, no video
  hang       accepts connections and never answers
  flood      endless HTTP replies (checks the size limits)
  lowbat     like free, battery at 9 % and discharging

Run:  python3 dev/mock_droidcam.py [--port 4848] [--scenario free] [--name "Mock Phone"]
"""

import argparse
import json
import socket
import socketserver
import struct
import threading
import time

# A small JPEG-shaped payload. The fake client only reads frame lengths;
# never point the real droidcam-cli at this mock (it would write to a
# real camera device).
JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707070909"
    "080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c2837292c30"
    "313434341f27393d38323c2e333432ffc0000b080008000801011100ffc4001f0000010501"
    "010101010100000000000000000102030405060708090a0bffc400b5100002010303020403"
    "050504040000017d01020300041105122131410613516107227114328191a1082342b1c115"
    "52d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a53"
    "5455565758595a636465666768696a737475767778797a838485868788898a929394959697"
    "98999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8"
    "d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffda0008010100003f00fbd3ffd9"
)

CONTROLS = {1: "exposure lock off", 2: "exposure lock on", 3: "white balance",
            4: "exposure", 6: "zoom in", 7: "zoom out", 8: "autofocus", 9: "torch"}

state = {
    "scenario": "free",
    "name": "Mock Phone",
    "torch": False,
    "zoom": 1.0,
    "ev": 0.0,
    "camera": 1,
    "exposure_lock": 0,
    "wb_lock": 0,
    "streaming": 0,
}
lock = threading.Lock()


def log(msg):
    print(f"[mock] {msg}", flush=True)


def camera_info():
    return {
        "active": state["camera"], "led_on": int(state["torch"]),
        "wbMode": 0, "wbLock": state["wb_lock"], "wbValue": 5000, "wbMin": 2000, "wbMax": 8000,
        "focusMode": 1, "mfValue": -1, "mfMin": -1, "mfMax": -1,
        "zmValue": state["zoom"], "zmMin": 1.0, "zmMax": 8.0,
        "evValue": state["ev"], "evMin": -4.0, "evMax": 4.0,
        "exposure_lock": state["exposure_lock"],
    }


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(10)
        try:
            data = sock.recv(4096)
        except OSError:
            return
        if not data:
            return
        # Hang on everything except scenario changes, so the mock can be
        # switched back.
        if state["scenario"] == "hang" and b"/mock/scenario/" not in data.split(b"\r\n", 1)[0]:
            time.sleep(60)
            return
        if data.startswith(b"CMD "):
            self.video(sock, data.decode("latin-1"))
        else:
            self.http(sock, data)

    # ---------- Video protocol ----------

    def video(self, sock, request):
        scenario = state["scenario"]
        log(f"video request: {request.strip()}")
        if scenario in ("busy", "stopped"):
            log("refusing video client")
            return
        try:
            w, h = request.rsplit("/", 1)[1].split("x")
            width, height = int(w), int(h)
        except ValueError:
            width, height = 640, 480
        sock.sendall(struct.pack(">HH", width, height) + b"\0" * 5)
        with lock:
            state["streaming"] += 1
        started = time.time()
        sock.setblocking(False)
        try:
            while True:
                if state["scenario"] == "drop" and time.time() - started > 8:
                    log("dropping the stream")
                    break
                try:
                    ctl = sock.recv(256)
                    if ctl == b"":
                        break
                    for part in ctl.decode("latin-1").split("CMD ")[1:]:
                        self.control(part.strip())
                except BlockingIOError:
                    pass
                try:
                    sock.sendall(struct.pack("<I", len(JPEG)) + JPEG)
                except (BlockingIOError, InterruptedError):
                    pass
                time.sleep(0.2)
        except OSError:
            pass
        finally:
            with lock:
                state["streaming"] -= 1
            log("video client gone")

    def control(self, cmd):
        try:
            code = int(cmd.split("?", 1)[1].split("=")[0])
        except (IndexError, ValueError):
            log(f"unknown control: {cmd}")
            return
        if code == 9:
            state["torch"] = not state["torch"]
        elif code == 6:
            state["zoom"] = min(8.0, state["zoom"] + 0.5)
        elif code == 7:
            state["zoom"] = max(1.0, state["zoom"] - 0.5)
        log(f"control: {CONTROLS.get(code, code)} ({cmd})")

    # ---------- HTTP API ----------

    def http(self, sock, data):
        try:
            line = data.split(b"\r\n", 1)[0].decode("latin-1")
            method, path, _ = line.split(" ", 2)
        except ValueError:
            return
        scenario = state["scenario"]

        if path.startswith("/mock/scenario/") and method == "POST":
            name = path.rsplit("/", 1)[1]
            state["scenario"] = name
            log(f"scenario: {name}")
            return self.reply(sock, 200, "text/plain", name)

        if scenario == "flood":
            head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
            try:
                sock.sendall(head.encode())
                chunk = b"x" * 65536
                for _ in range(2000):
                    sock.sendall(chunk)
            except OSError:
                pass
            return
        if scenario == "stopped" and path.startswith("/v"):
            return self.reply(sock, 555, "text/plain", "")

        if method == "GET":
            if path == "/":
                return self.reply(sock, 302, "text/plain", "", {"Location": "/remote"})
            if path == "/v1/phone/name":
                return self.reply(sock, 200, "text/plain", state["name"])
            if path == "/v1/phone/battery_info":
                level, st = (9, -1) if scenario == "lowbat" else (82, 1)
                return self.reply(sock, 200, "text/json", json.dumps({"level": level, "state": st}))
            if path == "/battery":
                return self.reply(sock, 200, "text/plain", "9" if scenario == "lowbat" else "82")
            if path == "/v1/camera/camera_list":
                return self.reply(sock, 200, "text/plain", "Front\nBack\nWide")
            if path == "/v1/camera/info":
                if scenario != "pro":
                    return self.reply(sock, 550, "text/plain", "")
                return self.reply(sock, 200, "text/json", json.dumps(camera_info()))
        if method == "PUT" and path.startswith(("/v1/camera/", "/v3/camera/")):
            if scenario != "pro":
                log(f"PUT {path} -> 550 (Pro only)")
                return self.reply(sock, 550, "text/plain", "")
            parts = path.strip("/").split("/")
            name = parts[2] if len(parts) > 2 else ""
            arg = parts[3] if len(parts) > 3 else ""
            if name == "torch_toggle":
                state["torch"] = not state["torch"]
            elif name == "zoom" and arg:
                state["zoom"] = float(arg)
            elif name == "ev" and arg:
                state["ev"] = float(arg)
            elif name == "active" and arg:
                state["camera"] = int(arg)
            elif name == "el_toggle":
                state["exposure_lock"] ^= 1
            elif name == "wbl_toggle":
                state["wb_lock"] ^= 1
            log(f"PUT {path}")
            return self.reply(sock, 200, "text/plain", "")
        return self.reply(sock, 404, "text/plain", "")

    def reply(self, sock, code, ctype, body, headers=None):
        reason = {200: "OK", 302: "Found", 404: "Not Found", 550: "Restricted", 555: "Stopped"}.get(code, "")
        head = f"HTTP/1.1 {code} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {len(body.encode())}\r\n"
        for k, v in (headers or {}).items():
            head += f"{k}: {v}\r\n"
        try:
            sock.sendall((head + "Connection: close\r\n\r\n" + body).encode())
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4848)
    parser.add_argument("--scenario", default="free")
    parser.add_argument("--name", default="Mock Phone", help="phone name the app reports")
    args = parser.parse_args()
    state["scenario"] = args.scenario
    state["name"] = args.name
    with Server((args.host, args.port), Handler) as server:
        log(f"listening on {args.host}:{args.port}, scenario {args.scenario}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
