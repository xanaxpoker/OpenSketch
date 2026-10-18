#!/usr/bin/env python3
"""Write .sketch variants of a sample that exercise each MSDocumentZippedJSONReader -validate branch.

usage: make_variants.py <sample.sketch> <out-dir>
"""
import json
import os
import sys
import zipfile

src, out_dir = sys.argv[1], sys.argv[2]

VARIANTS = {
    # name: (meta.json overrides, members to drop, decompiled prediction)
    "v5-newer-compat": ({"compatibilityVersion": 140}, set(), "status 5: 'created with a newer version of Sketch' error"),
    "v4-newer-version": ({"version": 140}, set(), "status 4: handleNewerDocument:error:"),
    "v3-old-version": ({"version": 87}, set(), "status 3: corrupt-metadata prompt"),
    "v2-no-user-json": ({}, {"user.json"}, "status 2: corrupt-metadata prompt, repair synthesizes {}"),
    # -share falls back to user.json and feeds nil data to NSJSONSerialization only when user.json is absent,
    # so a missing meta.json should still reach -validate and prompt.
    "v6-no-meta-json": ({}, {"meta.json"}, "status 2: corrupt-metadata prompt (share lookup succeeds)"),
}

# Read every member up front: writestr() mutates the ZipInfo it is given.
with zipfile.ZipFile(src) as zin:
    members = [(item.filename, zin.read(item.filename)) for item in zin.infolist()]
meta = json.loads(dict(members)["meta.json"])

for name, (overrides, drop, prediction) in VARIANTS.items():
    path = os.path.join(out_dir, name + ".sketch")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zout:
        for filename, data in members:
            if filename in drop:
                continue
            if filename == "meta.json":
                data = json.dumps({**meta, **overrides}).encode()
            zout.writestr(filename, data)
    print(f"{name}: {prediction} -> {path}")
