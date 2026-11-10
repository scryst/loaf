#!/usr/bin/env python3
"""Merge Loaf's busy hooks into ~/.claude/settings.json (idempotent). Touches only entries whose command contains
'loaf-busy-hook'; writes nothing when ours are already in place, else backs the file up first.
Usage: install-hooks.py [--remove] [settings.json] (default ~/.claude/settings.json). --remove takes ours out
and leaves every other hook as it was."""
import json, os, shutil, sys, time

args = [a for a in sys.argv[1:] if a != "--remove"]
remove = len(args) < len(sys.argv) - 1
path = os.path.expanduser(args[0] if args else "~/.claude/settings.json")
script = os.path.expanduser("~/Library/Application Support/Loaf/loaf-busy-hook.sh")
q = '"' + script + '"'
events = {"UserPromptSubmit": "touch", "PreToolUse": "touch", "PostToolUse": "touch", "Stop": "remove", "SessionEnd": "remove"}

def ours(event):
    return {"type": "command", "command": f"{q} {events[event]}", "timeout": 2}

try:
    data = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    sys.exit(f"{path} is not valid JSON ({e}); nothing written")
hooks = data.get("hooks", {})
def loaf_entries(event):
    return [h for g in hooks.get(event, []) for h in g.get("hooks", []) if "loaf-busy-hook" in h.get("command", "")]
def strip(event):
    """Drop every copy of ours from one event, and any group or event that leaves empty; keep everything else."""
    groups = hooks.get(event, [])
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if "loaf-busy-hook" not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    if remove and event in hooks and not groups: del hooks[event]   # an install appends ours back in place
if remove and not any(loaf_entries(e) for e in hooks):
    print("no loaf busy hooks in", path)
    sys.exit(0)
if not remove and all(loaf_entries(e) == [ours(e)] for e in events):
    print("loaf busy hooks already installed in", path)
    sys.exit(0)

if os.path.exists(path):
    shutil.copy2(path, f"{path}.bak-loaf-{time.strftime('%Y%m%d-%H%M%S')}")
for event in list(hooks) if remove else events:
    strip(event)   # an older copy of ours goes either way
    if not remove: hooks.setdefault(event, []).append({"hooks": [ours(event)]})
if hooks: data["hooks"] = hooks
else: data.pop("hooks", None)
tmp = path + ".tmp-loaf"
json.dump(data, open(tmp, "w"), indent=2); open(tmp, "a").write("\n")
os.replace(tmp, path)
print("loaf busy hooks", "removed from" if remove else "installed in", path)
