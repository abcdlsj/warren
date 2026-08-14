#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import plistlib
import socket
import subprocess
import time

token = ""
for domain in ("com.abcdlsj.warren", "WarrenNext"):
    try:
        token = subprocess.check_output(
            ["defaults", "read", domain, "webRelay.token"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        continue
    if token:
        break
if not token:
    raise SystemExit("missing webRelay.token")

# HTTP page must answer Cloudflare health checks.
http = socket.create_connection(("127.0.0.1", 8788), timeout=5)
http.sendall(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
chunks = []
while True:
    chunk = http.recv(65536)
    if not chunk:
        break
    chunks.append(chunk)
http_data = b"".join(chunks)
http.close()
assert b"200 OK" in http_data, http_data[:200]
assert b"X-Warren: ok" in http_data, "health marker missing"
assert b"/assets/app.js" in http_data, "Vite entry asset missing"
print("http ok", flush=True)

# WebSocket handshake + auth + roster.
s = socket.create_connection(("127.0.0.1", 8788), timeout=5)
s.settimeout(10)
key = base64.b64encode(os.urandom(16)).decode()
request = (
    "GET /ws HTTP/1.1\r\n"
    "Host: 127.0.0.1:8788\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n"
)
s.sendall(request.encode())
data = s.recv(4096)
assert b"101 Switching Protocols" in data, data[:200]
print("ws handshake ok", flush=True)

def send_text(text):
    payload = text.encode()
    mask = os.urandom(4)
    header = bytes([0x81, 0x80 | len(payload)]) + mask
    s.sendall(header + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

def read_frame():
    header = s.recv(2)
    while len(header) < 2:
        header += s.recv(2 - len(header))
    opcode = header[0] & 0x0F
    length = header[1] & 0x7F
    if length == 126:
        length = int.from_bytes(s.recv(2), "big")
    elif length == 127:
        length = int.from_bytes(s.recv(8), "big")
    payload = b""
    while len(payload) < length:
        payload += s.recv(length - len(payload))
    return opcode, payload

def read_text_frame():
    while True:
        opcode, payload = read_frame()
        if opcode == 1:
            return json.loads(payload.decode())

send_text(json.dumps({"t": "auth", "token": token, "version": "1.0"}))
roster = read_text_frame()
assert roster.get("t") == "roster", roster
assert isinstance(roster.get("state"), dict), roster
print("auth/roster ok", flush=True)

attached = False
sessions = [
    session for session in roster["state"].get("sessions", [])
    if session.get("lifecycle") == "running"
]
if sessions:
    session_id = sessions[0]["id"]
    attached_msg = None
    request_id = "verify-web-attach"
    send_text(json.dumps({
        "t": "request",
        "id": request_id,
        "method": "session.attach",
        "params": {"id": session_id},
    }))
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            s.settimeout(deadline - time.time())
            candidate = read_text_frame()
            if candidate.get("t") == "response" and candidate.get("id") == request_id:
                assert candidate.get("ok") is True, candidate
                continue
            if candidate.get("t") == "attached":
                attached_msg = candidate
                break
            if candidate.get("t") == "error":
                raise AssertionError(candidate)
        except socket.timeout:
            break
    assert attached_msg is not None, "attach timed out"
    assert attached_msg.get("t") == "attached", attached_msg
    print("attach ok", flush=True)
    attached = True
    send_text(json.dumps({"t": "input", "data": base64.b64encode(b"printf web-smoke\n").decode()}))
    got_echo = False
    deadline = time.time() + 5
    while time.time() < deadline:
        s.settimeout(deadline - time.time())
        opcode, payload = read_frame()
        if b"printf" in payload:
            got_echo = True
            break
    assert got_echo, "web input echo not observed"
    print("input/output ok", flush=True)

s.close()
print("web relay OK: http page + ws auth + roster" + (" + attach/input/echo" if attached else " (no sessions to attach)"))
