#!/usr/bin/env python3
"""Hold one `rea mcp` stdio session open and expose it on a Unix socket.

Each client connection sends one JSON line: {"tool": str, "args": dict, "timeout": seconds}
or {"method": str, "params": dict} for raw JSON-RPC, and receives one JSON line back.
Server notifications (progress, logs) are appended to run/notifications.jsonl.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN = os.path.join(ROOT, "run")
SOCK = os.path.join(RUN, "rea.sock")
REA = os.path.join(ROOT, "tools", "rea-cli", "node_modules", ".bin", "rea")

os.makedirs(RUN, exist_ok=True)
env = dict(os.environ)
env.setdefault("GHIDRA_INSTALL_DIR", os.path.join(ROOT, "tools", "ghidra_12.1.4_PUBLIC"))
env.setdefault("JAVA_HOME", "/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home")
env.setdefault("REA_GHIDRA_STARTUP_TIMEOUT_MS", "2700000")

stderr_log = open(os.path.join(RUN, "server-stderr.log"), "ab")
proc = subprocess.Popen([REA, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=stderr_log, env=env, cwd=ROOT)

lock = threading.Lock()
pending = {}  # id -> [event, response]
next_id = [0]
notif_log = open(os.path.join(RUN, "notifications.jsonl"), "a")


def send(msg):
    data = (json.dumps(msg) + "\n").encode()
    with lock:
        proc.stdin.write(data)
        proc.stdin.flush()


def reader():
    for line in proc.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "id" in msg and ("result" in msg or "error" in msg):
            slot = pending.get(msg["id"])
            if slot:
                slot[1] = msg
                slot[0].set()
        elif "id" in msg and "method" in msg:
            # Server-to-client request: answer roots/list, refuse everything else.
            if msg["method"] == "roots/list":
                send({"jsonrpc": "2.0", "id": msg["id"],
                      "result": {"roots": [{"uri": "file://" + ROOT, "name": "sketch-re"},
                                           {"uri": "file:///Applications/Sketch.app", "name": "Sketch"}]}})
            else:
                send({"jsonrpc": "2.0", "id": msg["id"],
                      "error": {"code": -32601, "message": "not supported by this client"}})
        else:
            notif_log.write(json.dumps({"t": time.time(), **msg}) + "\n")
            notif_log.flush()
    for slot in list(pending.values()):
        slot[1] = {"error": {"code": -1, "message": "server exited"}}
        slot[0].set()


def request(method, params, timeout):
    with lock:
        next_id[0] += 1
        rid = next_id[0]
    slot = [threading.Event(), None]
    pending[rid] = slot
    params = dict(params or {})
    params.setdefault("_meta", {})["progressToken"] = rid
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    if not slot[0].wait(timeout):
        send({"jsonrpc": "2.0", "method": "notifications/cancelled",
              "params": {"requestId": rid, "reason": "client timeout"}})
        pending.pop(rid, None)
        return {"error": {"code": -2, "message": f"client timeout after {timeout}s"}}
    pending.pop(rid, None)
    return slot[1]


threading.Thread(target=reader, daemon=True).start()
init = request("initialize", {"protocolVersion": "2025-06-18",
                              "capabilities": {"roots": {"listChanged": False}},
                              "clientInfo": {"name": "sketch-re-daemon", "version": "0.1"}}, 120)
if "error" in init:
    sys.exit(f"initialize failed: {init}")
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

if os.path.exists(SOCK):
    os.unlink(SOCK)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK)
os.chmod(SOCK, 0o600)
srv.listen(4)
print(f"ready pid={proc.pid} server={init['result'].get('serverInfo')}", flush=True)


def handle(conn):
    with conn:
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                return
            buf += chunk
        req = json.loads(buf)
        timeout = req.get("timeout", 3000)
        if "tool" in req:
            resp = request("tools/call", {"name": req["tool"], "arguments": req.get("args", {})}, timeout)
        else:
            resp = request(req["method"], req.get("params", {}), timeout)
        conn.sendall((json.dumps(resp) + "\n").encode())


while proc.poll() is None:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
