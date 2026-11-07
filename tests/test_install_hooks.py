#!/usr/bin/env python3
"""install-hooks.py: adds Loaf's busy hooks, keeps other hooks, and writes nothing when they are already in place.
A no-op rerun must leave the file byte-identical.
Run: python3 tests/test_install_hooks.py (stdlib only)."""
import glob, json, os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "install-hooks.py")
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
GATE = {"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/budget_caps.py"}]}


class InstallHooks(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.home.name, ".claude")
        os.makedirs(self.dir)
        self.path = os.path.join(self.dir, "settings.json")

    def tearDown(self):
        self.home.cleanup()

    def run_script(self):
        env = dict(os.environ, HOME=self.home.name)
        return subprocess.run([sys.executable, "-I", SCRIPT, self.path], env=env, capture_output=True, text=True)

    def write(self, data):
        with open(self.path, "w") as f:
            json.dump(data, f, indent=2)

    def read_bytes(self):
        with open(self.path, "rb") as f:
            return f.read()

    def backups(self):
        return glob.glob(self.path + ".bak-loaf-*")

    def loaf_commands(self, data, event):
        return [h["command"] for g in data["hooks"][event] for h in g["hooks"] if "loaf-busy-hook" in h["command"]]

    def test_first_run_adds_entries_and_keeps_other_hooks(self):
        self.write({"model": "x", "hooks": {"PreToolUse": [GATE], "Stop": [GATE]}})
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.read_bytes())
        self.assertEqual(data["model"], "x")
        for event in EVENTS:
            self.assertEqual(len(self.loaf_commands(data, event)), 1, event)
        self.assertEqual(data["hooks"]["PreToolUse"][0], GATE)
        self.assertEqual(data["hooks"]["Stop"][0], GATE)
        self.assertIn("busy hooks installed in", r.stdout)
        self.assertEqual(len(self.backups()), 1)

    def test_second_run_writes_nothing(self):
        self.write({"hooks": {"PreToolUse": [GATE]}})
        self.assertEqual(self.run_script().returncode, 0)
        for b in self.backups():  # backups are named to the second, so clear them to see a new one
            os.remove(b)
        before = self.read_bytes()
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read_bytes(), before)
        self.assertEqual(self.backups(), [])
        self.assertIn("already installed", r.stdout)

    def test_gate_added_after_loaf_keeps_its_place(self):
        # a later gate lands after Loaf's group; a rerun must not move Loaf to the end (that would rewrite the file for nothing)
        self.write({"hooks": {}})
        self.run_script()
        data = json.loads(self.read_bytes())
        data["hooks"]["PreToolUse"].append(GATE)
        self.write(data)
        for b in self.backups():
            os.remove(b)
        before = self.read_bytes()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.read_bytes(), before)
        self.assertEqual(self.backups(), [])

    def test_stale_entry_is_replaced(self):
        old = {"hooks": [{"type": "command", "command": '"/old/loaf-busy-hook.sh" touch', "timeout": 2}]}
        self.write({"hooks": {"PreToolUse": [GATE, old]}})
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.read_bytes())
        cmds = self.loaf_commands(data, "PreToolUse")
        self.assertEqual(len(cmds), 1)
        self.assertNotIn("/old/", cmds[0])
        self.assertIn("busy hooks installed in", r.stdout)
        self.assertNotIn("already", r.stdout)

    def test_invalid_json_writes_nothing(self):
        with open(self.path, "w") as f:
            f.write("{not json")
        r = self.run_script()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.read_bytes(), b"{not json")
        self.assertEqual(sorted(os.listdir(self.dir)), ["settings.json"])


if __name__ == "__main__":
    unittest.main()
