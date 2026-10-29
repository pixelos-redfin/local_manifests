#!/usr/bin/env python3
"""List the source changes between two releases from their manifest snapshots
(repo manifest -r), as Markdown, for writing that release's changelog.

    release_changes.py <previous manifest.xml> <new manifest.xml>

The tree uses shallow clones, so commits come from GitHub (gh api compare).
"""
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

MAX_COMMITS = 40


def projects(path):
    root = ET.parse(path).getroot()
    remotes = {r.get("name"): r.get("fetch", "") for r in root.findall("remote")}
    default = root.find("default")
    default_remote = default.get("remote") if default is not None else None
    out = {}
    for p in root.findall("project"):
        out[p.get("path") or p.get("name")] = {
            "name": p.get("name"),
            "revision": p.get("revision"),
            "remote": p.get("remote") or default_remote,
            "fetch": remotes.get(p.get("remote") or default_remote, ""),
        }
    return out


def compare(name, old, new):
    try:
        res = subprocess.run(
            ["gh", "api", f"repos/{name}/compare/{old}...{new}",
             "--jq", "{status, total: .total_commits, commits: [.commits[] | {sha: .sha[:12], msg: (.commit.message | split(\"\\n\")[0])}]}"],
            capture_output=True, text=True, timeout=60, check=True)
        return json.loads(res.stdout)
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    old, new = projects(sys.argv[1]), projects(sys.argv[2])
    lines = []
    for path in sorted(set(old) | set(new)):
        a, b = old.get(path), new.get(path)
        if a is None:
            lines += [f"### {path}", f"* added ({b['name']})", ""]
            continue
        if b is None:
            lines += [f"### {path}", f"* removed ({a['name']})", ""]
            continue
        if a["revision"] == b["revision"] and a["name"] == b["name"]:
            continue
        lines.append(f"### {path} ({b['name']})")
        if a["name"] != b["name"]:
            lines.append(f"* now from {b['name']} (was {a['name']})")
        cmp = compare(b["name"], a["revision"], b["revision"]) if a["name"] == b["name"] else None
        if cmp is None:
            lines.append(f"* {a['revision'][:12]} -> {b['revision'][:12]} (commit list unavailable)")
        else:
            if cmp["status"] in ("diverged", "behind"):
                lines.append(f"* history rewritten or rolled back ({cmp['status']})")
            for c in cmp["commits"][-MAX_COMMITS:]:
                lines.append(f"* {c['msg']} ({c['sha']})")
            if cmp["total"] > MAX_COMMITS:
                lines.append(f"* … and {cmp['total'] - MAX_COMMITS} older commits")
        lines.append("")
    print("\n".join(lines) if lines else "No source changes.")


if __name__ == "__main__":
    main()
