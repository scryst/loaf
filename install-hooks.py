#!/usr/bin/env python3
"""Merge Loaf's busy hooks into ~/.claude/settings.json (idempotent). Touches only entries whose command contains
'loaf-busy-hook'; writes nothing when ours are already in place, else backs the file up first.
Usage: install-hooks.py [settings.json] (default ~/.claude/settings.json)."""
import json, os, shutil, sys, time

path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.claude/settings.json")
script = os.path.expanduser("~/Library/Application Support/Loaf/loaf-busy-hook.sh")
q = '"' + script + '"'
events = {"UserPromptSubmit": "touch", "PreToolUse": "touch", "PostToolUse": "touch", "Stop": "remove", "SessionEnd": "remove"}

def ours(event):
    return {"type": "command", "command": f"{q} {events[event]}", "timeout": 2}

try:
    data = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    sys.exit(f"{path} is not valid JSON ({e}); nothing written")
hooks = data.setdefault("hooks", {})
def loaf_entries(event):
    return [h for g in hooks.get(event, []) for h in g.get("hooks", []) if "loaf-busy-hook" in h.get("command", "")]
if all(loaf_entries(e) == [ours(e)] for e in events):
    print("loaf busy hooks already installed in", path)
    sys.exit(0)

if os.path.exists(path):
    shutil.copy2(path, f"{path}.bak-loaf-{time.strftime('%Y%m%d-%H%M%S')}")
for event in events:
    groups = hooks.setdefault(event, [])
    for g in groups:   # drop an older copy of ours, keep everything else
        g["hooks"] = [h for h in g.get("hooks", []) if "loaf-busy-hook" not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    groups.append({"hooks": [ours(event)]})
tmp = path + ".tmp-loaf"
json.dump(data, open(tmp, "w"), indent=2); open(tmp, "a").write("\n")
os.replace(tmp, path)
print("loaf busy hooks installed in", path)
