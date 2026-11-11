#!/bin/zsh
# Every Loaf check that is safe while the real Loaf runs: build into a temp dir, the install and hook script tests, then the built
# binary's headless prefs and background-scan checks. Leaves out --test-hold and --test-chime: they set and release
# `pmset disablesleep`, which drops the live hold for up to a minute. Run those by hand when nothing needs the Mac awake.
set -euo pipefail
cd "${0:A:h}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
./build.sh "$tmp" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: build"; exit 1; }
echo "ok: build"
zsh tests/install-order.test.sh
bash tests/install-retry.test.sh
bash tests/install-bootout-wait.test.sh
python3 tests/test_install_hooks.py 2>&1 | tail -1
bin="$tmp/Loaf.app/Contents/MacOS/Loaf"
"$bin" --test-prefs get | grep PASS
"$bin" --scan-bg | sed 's/^/ok: scan-bg /'
"$bin" --test-holders
"$bin" --test-interrupt
"$bin" --test-idle-sleep | grep -c PASS | sed 's/^/ok: idle-sleep passes: /'
"$bin" --test-idle-sleep | grep -q FAIL && { echo "FAIL: idle-sleep"; exit 1; } || true
"$bin" --test-power
"$bin" --holders | tail -1 | sed 's/^/ok: live holders /'
"$bin" --notify-status | sed 's/^/ok: /'
echo "all checks passed"
