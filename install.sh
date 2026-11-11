#!/bin/zsh
# Build, install and (re)start Loaf under its LaunchAgent (app.loaf.Loaf) and its watchdog (app.loaf.Loaf.watchdog).
# KeepAlive only on a crash: Quit exits 0, so Loaf stays quit until the next login or `launchctl kickstart gui/$UID/app.loaf.Loaf`.
set -euo pipefail
cd "${0:A:h}"
uid=$(id -u)
agents=~/Library/LaunchAgents
labels=(app.loaf.Loaf app.loaf.Loaf.watchdog)

# build first: build.sh swaps the bundle in only after swiftc succeeds, so a failed build leaves the running Loaf up
./build.sh
# and the hooks next, still before anything is stopped: a bad settings.json aborts here with Loaf and its watchdog up
# the busy-signal hook lives outside the app bundle so a rebuild never leaves Claude Code pointing at a missing file
mkdir -p "$HOME/Library/Application Support/Loaf/busy"
cp loaf-busy-hook.sh "$HOME/Library/Application Support/Loaf/loaf-busy-hook.sh"
./install-hooks.py
# then stop the current Loaf and watchdog by label so the new bundle starts under launchd. bootout returns before launchd
# has let go of the job, and bootstrapping too soon fails with "5: Input/output error", so
# wait up to 5 s for each label to be gone.
for l in $labels; do
  if launchctl print "gui/$uid/$l" >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$l"
    for i in {1..50}; do launchctl print "gui/$uid/$l" >/dev/null 2>&1 || break; sleep 0.1; done
  fi
done

for l in $labels; do
  sed "s|__HOME__|$HOME|" $l.plist > $agents/$l.plist
  # and retry the bootstrap for up to 5 s in case launchd is still busy with the old job; the last try's error stands
  ok=0
  for i in {1..20}; do launchctl bootstrap "gui/$uid" $agents/$l.plist 2>/dev/null && { ok=1; break; }; sleep 0.25; done
  (( ok )) || launchctl bootstrap "gui/$uid" $agents/$l.plist
done
launchctl kickstart "gui/$uid/app.loaf.Loaf"
sleep 2
launchctl print "gui/$uid/app.loaf.Loaf" | grep -E "state =|pid ="
