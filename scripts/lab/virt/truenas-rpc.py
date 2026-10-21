#!/usr/bin/env python3
"""Minimal JSON-RPC 2.0 over WebSocket client (standard library only) for the L1 TrueNAS fixture.

It talks to two endpoints, both on the lab guest only:
  * the installer of the live ISO     ws://<ip>/ws            (no TLS, no auth; `adopt` is open)
  * the installed TrueNAS middleware  wss://<ip>/api/current  (self-signed TLS, auth.login_ex)

Usage:  truenas-rpc.py URL < calls.json
  calls.json is a JSON array of [method, params] pairs, run in order on ONE connection.
  Environment: TRUENAS_RPC_USER + TRUENAS_RPC_PASSWORD log in first (auth.login_ex PASSWORD_PLAIN);
               TRUENAS_RPC_API_KEY logs in with an API key instead.
  A method written "job:pool.create" is a middleware job: the call returns a job id and this client
  polls core.get_jobs until it finishes, then returns the job result (or fails with its error).
  Prints a JSON array of results on stdout. Server notifications are reported on stderr as progress.
  Exits 1 on the first JSON-RPC error (the error is printed on stderr) or a transport failure.
"""
import base64
import json
import os
import socket
import ssl
import struct
import sys
import urllib.parse


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    return buf


class WS:
    def __init__(self, url, timeout):
        u = urllib.parse.urlparse(url)
        if u.scheme not in ("ws", "wss"):
            raise ValueError("URL must be ws:// or wss://")
        port = u.port or (443 if u.scheme == "wss" else 80)
        raw = socket.create_connection((u.hostname, port), timeout=15)
        if u.scheme == "wss":
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE  # the fixture serves a self-signed certificate
            raw = ctx.wrap_socket(raw, server_hostname=u.hostname)
        self.sock = raw
        key = base64.b64encode(os.urandom(16)).decode()
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError("websocket upgrade refused: " + head.split(b"\r\n", 1)[0].decode(errors="replace"))
        self.sock.settimeout(timeout)

    def send(self, text):
        data = text.encode()
        n = len(data)
        hdr = bytes([0x81])
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        msg = b""
        while True:
            b1, b2 = _recv_exact(self.sock, 2)
            op, fin, n = b1 & 0x0F, b1 & 0x80, b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", _recv_exact(self.sock, 2))[0]
            elif n == 127:
                n = struct.unpack(">Q", _recv_exact(self.sock, 8))[0]
            payload = _recv_exact(self.sock, n) if n else b""
            if op == 0x8:
                raise ConnectionError("server closed the websocket")
            if op == 0x9:  # ping -> pong
                self.sock.sendall(bytes([0x8A, 0x80 | len(payload)]) + b"\0\0\0\0" + payload)
                continue
            if op in (0x0, 0x1, 0x2):
                msg += payload
                if fin:
                    return msg.decode()


class Rpc:
    def __init__(self, url, timeout=3600):
        self.ws = WS(url, timeout)
        self.next_id = 1

    def job(self, method, params):
        import time
        jid = self.call(method, params)
        while True:
            rows = self.call("core.get_jobs", [[["id", "=", jid]]])
            state = rows[0]["state"] if rows else "MISSING"
            if state == "SUCCESS":
                return rows[0].get("result")
            if state in ("FAILED", "ABORTED", "MISSING"):
                raise RuntimeError(f"{method}: job {state}: {str(rows[0].get('error') if rows else '')[:600]}")
            time.sleep(2)

    def call(self, method, params):
        rid = self.next_id
        self.next_id += 1
        self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if isinstance(msg, dict) and msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(f"{method}: {json.dumps(msg['error'])[:600]}")
                return msg["result"]
            if isinstance(msg, dict) and msg.get("method"):
                p = msg.get("params")
                if isinstance(p, list) and p and isinstance(p[0], dict) and "progress" in p[0]:
                    print(f"   install {p[0]['progress'] * 100 if p[0]['progress'] <= 1 else p[0]['progress']:.0f}% {p[0].get('message', '')}", file=sys.stderr, flush=True)


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    calls = json.load(sys.stdin)
    rpc = Rpc(sys.argv[1])
    user, pw, key = (os.environ.get(k) for k in ("TRUENAS_RPC_USER", "TRUENAS_RPC_PASSWORD", "TRUENAS_RPC_API_KEY"))
    try:
        if key:
            ok = rpc.call("auth.login_with_api_key", [key])
            if ok is not True:
                raise RuntimeError("API key login refused")
        elif user and pw:
            res = rpc.call("auth.login_ex", [{"mechanism": "PASSWORD_PLAIN", "username": user, "password": pw}])
            if not isinstance(res, dict) or res.get("response_type") != "SUCCESS":
                raise RuntimeError("password login refused: " + str(res.get("response_type") if isinstance(res, dict) else res))
        out = [rpc.job(m[4:], p) if m.startswith("job:") else rpc.call(m, p) for m, p in calls]
    except (RuntimeError, ConnectionError, OSError) as e:
        print(f"truenas-rpc: {e}", file=sys.stderr)
        return 1
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
