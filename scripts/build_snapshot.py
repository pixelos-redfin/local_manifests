#!/usr/bin/env python3
"""Write a compact JSON snapshot of the current build (from buildweb.py's API)
for the claude.ai build artifact.   build_snapshot.py [out.json]"""
import json, sys, urllib.request

out = sys.argv[1] if len(sys.argv) > 1 else "/dev/stdout"
s = json.load(urllib.request.urlopen("http://127.0.0.1:8095/api/status", timeout=10))
keep = ("log", "status", "phase", "pct", "done", "total", "target", "rate", "eta", "started", "updated", "now")
snap = {k: s.get(k) for k in keep}
snap["errors"] = [e[:300] for e in s.get("errors", [])][-5:]
snap["lines"] = [l[:200] for l in s.get("lines", [])][-15:]
chart = s.get("chart", [])
step = max(1, len(chart) // 120)
pts = chart[::step] + (chart[-1:] if chart and len(chart) % step else [])
snap["chart"] = [{"t": t, "d": d} for t, d in pts]
snap["history"] = s.get("history", [])[:10]
with open(out, "w") as f:
    json.dump(snap, f, separators=(",", ":"))
