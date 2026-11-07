#!/bin/zsh
# One-time, needs root:  sudo ./install-sleep-helper.sh
# Installs /etc/sudoers.d/loaf, which lets your user run exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1`
# without a password, so Loaf can keep the Mac awake with the lid shut while keep-awake is on. Touches no other sudoers rule.
set -eu
if [[ $EUID -ne 0 ]]; then echo "run it with sudo: sudo ${0:A}"; exit 1; fi
user=${SUDO_USER:-}
if [[ -z $user || $user == root ]]; then echo "run it as your own user through sudo (SUDO_USER is empty)"; exit 1; fi
dest=/etc/sudoers.d/loaf
tmp=$(mktemp /tmp/loaf-sudoers.XXXXXX)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<RULE
# Loaf: $user may switch clamshell sleep off and on without a password. Nothing else.
$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
RULE
chmod 0440 "$tmp"
/usr/sbin/visudo -cf "$tmp" >/dev/null || { echo "sudoers text did not validate; nothing installed"; exit 1; }
install -m 0440 -o root -g wheel "$tmp" "$dest"
if ! /usr/sbin/visudo -c >/dev/null; then rm -f "$dest"; echo "sudoers failed the full check; $dest removed"; exit 1; fi
echo "installed $dest"
# prove it as the user, then leave sleep enabled
sudo -u "$user" sudo -n /usr/bin/pmset -a disablesleep 1
echo "set:   $(/usr/bin/pmset -g | /usr/bin/grep SleepDisabled)"
sudo -u "$user" sudo -n /usr/bin/pmset -a disablesleep 0
echo "reset: $(/usr/bin/pmset -g | /usr/bin/grep SleepDisabled)"
sudo -u "$user" launchctl kickstart -k "gui/$(id -u "$user")/app.loaf.Loaf" && echo "Loaf restarted"
