#!/usr/bin/env python3
"""Call one tool on the running REA MCP daemon.

usage: rea_call.py <tool> [json-args] [--out FILE] [--timeout SECONDS]
       rea_call.py --method tools/list [--out FILE]
Writes the full JSON-RPC response to --out (default run/last.json) and prints a short summary.
"""
import argparse
import json
import os
import socket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOCK = os.path.join(ROOT, "run", "rea.sock")

ap = argparse.ArgumentParser()
ap.add_argument("tool", nargs="?")
ap.add_argument("args", nargs="?", default="{}")
ap.add_argument("--method")
ap.add_argument("--out", default=os.path.join(ROOT, "run", "last.json"))
ap.add_argument("--timeout", type=float, default=3000)
a = ap.parse_args()

args = json.load(open(a.args)) if os.path.isfile(a.args) else json.loads(a.args)
req = {"method": a.method, "params": args} if a.method else {"tool": a.tool, "args": args}
req["timeout"] = a.timeout

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(SOCK)
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    chunk = s.recv(1 << 20)
    if not chunk:
        break
    buf += chunk
resp = json.loads(buf)
with open(a.out, "w") as f:
    json.dump(resp, f, indent=1)

if "error" in resp:
    print("RPC ERROR:", json.dumps(resp["error"])[:2000])
else:
    r = resp["result"]
    if r.get("isError"):
        print("TOOL ERROR")
    for c in r.get("content", [])[:2]:
        if c.get("type") == "text":
            print(c["text"][:3000])
    print(f"[{len(buf)} bytes -> {a.out}]")
