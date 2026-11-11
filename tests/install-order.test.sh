#!/usr/bin/env bash
# install.sh must not stop Loaf or its watchdog when the build fails (a failed build would leave both down).
# Runs install.sh against a stub build.sh that exits 1, with launchctl/trash stubbed on PATH. Needs zsh.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app" "$tmp/bin" "$tmp/home/Library/LaunchAgents"
cp "$repo/install.sh" "$tmp/app/"
printf '#!/bin/sh\nexit 1\n' > "$tmp/app/build.sh"
printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\nexit 0\n' "$tmp" > "$tmp/bin/launchctl"   # every label looks loaded
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/trash"
chmod +x "$tmp/app/build.sh" "$tmp/bin/launchctl" "$tmp/bin/trash"
touch "$tmp/launchctl.log"
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" zsh "$tmp/app/install.sh" >/dev/null 2>&1; then
  echo "FAIL: install.sh succeeded with a failing build"; exit 1
fi
if grep -E 'bootout .*/app\.loaf\.Loaf(\.watchdog)?$' "$tmp/launchctl.log"; then
  echo "FAIL: install.sh booted out Loaf before the build succeeded"; exit 1
fi
echo "ok: a failed build leaves Loaf and its watchdog running"

# the same for the hook step: a bad settings.json makes install-hooks.py exit 1, and that must not leave Loaf down
printf '#!/bin/sh\nexit 0\n' > "$tmp/app/build.sh"
printf '#!/bin/sh\nexit 1\n' > "$tmp/app/install-hooks.py"
cp "$repo/loaf-busy-hook.sh" "$tmp/app/" 2>/dev/null || touch "$tmp/app/loaf-busy-hook.sh"
chmod +x "$tmp/app/build.sh" "$tmp/app/install-hooks.py"
: > "$tmp/launchctl.log"
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" zsh "$tmp/app/install.sh" >/dev/null 2>&1; then
  echo "FAIL: install.sh succeeded with failing hooks"; exit 1
fi
if grep -E 'bootout .*/app\.loaf\.Loaf(\.watchdog)?$' "$tmp/launchctl.log"; then
  echo "FAIL: install.sh booted out Loaf before the hook step succeeded"; exit 1
fi
echo "ok: a failed hook step leaves Loaf and its watchdog running"
