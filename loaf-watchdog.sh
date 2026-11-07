#!/bin/zsh
# Loaf watchdog (LaunchAgent app.loaf.Loaf.watchdog, every 60 s). Loaf holds `pmset disablesleep 1` while keep-awake is on
# and resets it itself on quit, SIGTERM and every launch. This covers the one case left: Loaf is not running at all
# (booted out, deleted) while sleep is still disabled. Needs the sudoers helper; silent without it.
/usr/bin/pgrep -x Loaf >/dev/null && exit 0
/usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || exit 0
if /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then
  mkdir -p ~/Library/Logs/Loaf
  print "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog: Loaf is not running and SleepDisabled was 1; reset to 0" >> ~/Library/Logs/Loaf/events.log
fi
exit 0
