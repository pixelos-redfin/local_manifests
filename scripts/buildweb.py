#!/usr/bin/env python3
"""Live web view of Android builds, from their logs (output of `m ... > log 2>&1`).

    buildweb.py [--port 8095] [--bind 127.0.0.1]

Watches the newest of ~/telegram_bot/logs/*.log and ~/logs/build-*.log, like
buildwatch.sh. Listens on localhost only; open it through an SSH tunnel:
    ssh -N -L 8095:127.0.0.1:8095 <user>@<server>   then  http://localhost:8095
"""
import argparse
import glob
import json
import os
import re
import threading
import time
from urllib.parse import unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
LOG_GLOBS = [f"{HOME}/telegram_bot/logs/*.log", f"{HOME}/logs/build-*.log"]
PROGRESS = re.compile(rb"\[ *(\d+)% (\d+)/(\d+)[^\]]*\] ([^\r\n]*)")
ERROR = re.compile(rb"^(FAILED: .*|.*error: .*|ninja: error.*|.*Killed.*|.*OutOfMemoryError.*)$", re.M)
END = re.compile(rb"#### (build completed successfully|failed to build some targets)[^\n]*")
STALE = 300  # seconds without log writes: the build is no longer running


def build_procs():
    """Names of this user's running build processes (soong_ui, soong_build, ninja)."""
    names = set()
    uid = os.getuid()
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if os.stat(f"/proc/{pid}").st_uid != uid:
                continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv0 = f.read().split(b"\0", 1)[0]
        except OSError:
            continue
        name = os.path.basename(argv0).decode(errors="replace")
        if name in ("soong_ui", "soong_build", "ninja", "kati", "ckati"):
            names.add(name)
    return names


def logs():
    files = [f for g in LOG_GLOBS for f in glob.glob(g)]
    return sorted(files, key=os.path.getmtime, reverse=True)


def tail(path, size):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - size))
        return f.read()


def started(path):
    st = os.stat(path)
    birth = getattr(st, "st_birthtime", 0)
    if not birth:
        m = re.search(r"(\d{8})-(\d{4})", os.path.basename(path))
        if m:
            birth = time.mktime(time.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M"))
    return birth or st.st_mtime


def result(path):
    end = END.findall(tail(path, 4000))
    if not end:
        return None
    return "ok" if end[-1].startswith(b"build completed") else "failed"


def summary(path):
    data = tail(path, 4000)
    m = END.search(data)
    took = ""
    if m:
        t = re.search(rb"\((\d+(?::\d+)+)", m.group(0))
        took = t.group(1).decode() if t else ""
    res = result(path)
    age = time.time() - os.path.getmtime(path)
    return {
        "name": os.path.basename(path)[:-4],
        "result": res or ("running" if age < STALE else "stopped"),
        "took": took,
        "started": started(path),
        "ended": os.path.getmtime(path),
    }


class Tracker:
    """Samples the current log every 2 s; keeps per-phase history for the ETA and chart."""

    def __init__(self):
        self.lock = threading.Lock()
        self.log = None
        self.samples = []  # (time, done, total)
        self.state = {}

    def sample(self):
        files = logs()
        if not files:
            with self.lock:
                self.state = {"log": None, "history": []}
            return
        path = files[0]
        now = time.time()
        if path != self.log:
            self.log, self.samples = path, []
        data = tail(path, 300000).replace(b"\r", b"\n")
        prog = PROGRESS.findall(data)
        pct = done = total = 0
        target = ""
        if prog:
            p, d, t, target = prog[-1]
            pct, done, total, target = int(p), int(d), int(t), target.decode(errors="replace")
            if self.samples and self.samples[-1][2] != total:
                self.samples = []  # soong bootstrap, kati and ninja count their own steps
            if not self.samples or self.samples[-1][1] != done or now - self.samples[-1][0] > 30:
                self.samples.append((now, done, total))
                self.samples = self.samples[-2000:]
        res = result(path)
        age = now - os.path.getmtime(path)
        procs = build_procs()
        # soong analysis writes nothing to the log for many minutes
        status = res or ("running" if age < STALE or procs else "stopped")
        eta = rate = None
        recent = [s for s in self.samples if now - s[0] < 600]
        if status == "running" and len(recent) >= 2 and recent[-1][1] > recent[0][1]:
            dt = recent[-1][0] - recent[0][0]
            rate = (recent[-1][1] - recent[0][1]) / dt if dt else None
            if rate:
                eta = (total - done) / rate
        errors = [e.decode(errors="replace")[:400] for e in ERROR.findall(tail(path, 2000000))][-8:]
        lines = [l.decode(errors="replace") for l in data.splitlines() if l.strip()][-40:]
        phase = "ninja" if total > 1000 else ("soong/kati" if prog else "starting")
        if status == "running" and not prog:
            phase = "running"
        if status == "running" and "soong_build" in procs:
            phase = "soong analysis"
        elif status == "running" and procs & {"kati", "ckati"}:
            phase = "kati"
        with self.lock:
            self.state = {
                "log": os.path.basename(path)[:-4],
                "path": path,
                "status": status,
                "phase": phase,
                "pct": pct,
                "done": done,
                "total": total,
                "target": target,
                "rate": rate,
                "eta": eta,
                "started": started(path),
                "updated": os.path.getmtime(path),
                "now": now,
                "errors": errors,
                "lines": lines,
                "chart": [(round(s[0] - self.samples[0][0]), s[1]) for s in self.samples][-600:],
                "history": [summary(f) for f in files[:12]],
            }

    def loop(self):
        while True:
            try:
                self.sample()
            except Exception as e:  # keep serving the last state
                with self.lock:
                    self.state["server_error"] = str(e)
            time.sleep(2)

    def get(self):
        with self.lock:
            return json.dumps(self.state)


tracker = Tracker()
PAGE = open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "buildweb.html"), "rb").read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.send(200, "text/html; charset=utf-8", PAGE)
        elif self.path == "/api/status":
            self.send(200, "application/json", tracker.get().encode())
        elif self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                while True:
                    self.wfile.write(b"data: " + tracker.get().encode() + b"\n\n")
                    self.wfile.flush()
                    time.sleep(2)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path.startswith("/log/"):
            name = os.path.basename(unquote(self.path[5:]))
            match = [f for f in logs() if os.path.basename(f) == name + ".log"]
            if match:
                self.send(200, "text/plain; charset=utf-8", tail(match[0], 1000000))
            else:
                self.send(404, "text/plain", b"no such log")
        else:
            self.send(404, "text/plain", b"not found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8095)
    ap.add_argument("--bind", default="127.0.0.1")
    a = ap.parse_args()
    threading.Thread(target=tracker.loop, daemon=True).start()
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
