#!/usr/bin/env python3
"""Print the normalized_result of a saved rea_call.py response, trimmed. usage: show.py <file> [maxchars]"""
import json
import sys

r = json.load(open(sys.argv[1]))
if "error" in r:
    print("RPC ERROR", r["error"]); sys.exit()
res = r["result"]
sc = res.get("structuredContent") or json.loads(res["content"][0]["text"])
out = sc.get("normalized_result", sc)
print(json.dumps(out, indent=1)[: int(sys.argv[2]) if len(sys.argv) > 2 else 4000])
