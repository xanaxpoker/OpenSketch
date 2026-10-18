#!/usr/bin/env python3
"""Open one .sketch file in Sketch and capture any new on-screen window with REA.

usage: probe_variant.py <pid|fresh> <file.sketch> <out-prefix>
With "fresh", any running Sketch is terminated first and the file is opened in a new instance.
Writes <out-prefix>-<window>.json/.png for each new window and prints its title, texts and buttons.
"""
import base64
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REA = os.path.join(ROOT, "tools", "rea-cli", "node_modules", ".bin", "rea")
LIST = os.path.join(ROOT, "tools", "list_windows")
pid, sketch_file, prefix = sys.argv[1], sys.argv[2], sys.argv[3]


def onscreen():
    out = subprocess.run([LIST, pid], capture_output=True, text=True).stdout
    return {line.split()[0]: line for line in out.splitlines() if "onscreen=1" in line}


if pid == "fresh":
    subprocess.run(["pkill", "-TERM", "-f", "Sketch.app/Contents/MacOS/Sketch"])
    time.sleep(2)
    before = {}
    subprocess.run(["open", "-a", "/Applications/Sketch.app", sketch_file], check=True)
    for _ in range(30):
        time.sleep(1)
        found = subprocess.run(["pgrep", "-f", "Sketch.app/Contents/MacOS/Sketch"], capture_output=True, text=True).stdout.split()
        if found:
            pid = found[0]
            break
    print("pid", pid)
    time.sleep(14)
else:
    before = onscreen()
    subprocess.run(["open", "-a", "/Applications/Sketch.app", sketch_file], check=True)
    time.sleep(5)
new = {w: line for w, line in onscreen().items() if w not in before}
if not new:
    print("no new on-screen window")
for wid, line in new.items():
    print("window", line)
    res = subprocess.run([REA, "observe-native-ui", "/Applications/Sketch.app", "--pid", pid,
                          "--window-id", wid, "--max-nodes", "400", "--format", "json"],
                         capture_output=True, text=True)
    open(f"{prefix}-{wid}.json", "w").write(res.stdout)
    try:
        cap = json.loads(res.stdout)["normalized_result"]["initial"]
    except (ValueError, KeyError):
        print("  capture failed:", res.stdout[:400])
        continue
    if cap.get("screenshot"):
        open(f"{prefix}-{wid}.png", "wb").write(base64.b64decode(cap["screenshot"]["base64"]))
    nodes = cap["nodes"]
    print("  AX window title:", nodes[0].get("title"), "| subrole/role:", nodes[0]["role"])
    print("  texts:", [n.get("value") or n.get("title") for n in nodes if n["role"] == "AXStaticText"][:8])
    print("  buttons:", [(n["path"], n.get("title")) for n in nodes if n["role"] == "AXButton" and n.get("title")][:10])
