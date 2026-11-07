#!/usr/bin/env bash
# install.sh must not bootstrap a label until launchd has let go of the old job: with Loaf and its watchdog loaded,
# each label still answers `launchctl print` for 3 calls after bootout. Every bootout must come first and every
# bootstrap only after print stopped answering. Stubs build.sh, install-hooks.py, launchctl, sleep.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app" "$tmp/bin" "$tmp/state" "$tmp/home/Library/LaunchAgents"
cp "$repo/install.sh" "$repo/loaf-busy-hook.sh" "$repo"/app.loaf.Loaf*.plist "$tmp/app/"
printf '#!/bin/sh\nexit 0\n' > "$tmp/app/build.sh"
printf '#!/bin/sh\nexit 0\n' > "$tmp/app/install-hooks.py"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
labels="app.loaf.Loaf app.loaf.Loaf.watchdog"
for l in $labels; do echo up > "$tmp/state/$l"; done
# state/<label>: "up" (loaded), a number (bootout pending: print answers that many more times), or absent (gone)
cat > "$tmp/bin/launchctl" <<STUB
#!/bin/sh
s="$tmp/state"
case "\$1" in
  bootout) l=\$(basename "\$2"); echo "bootout \$l" >> "$tmp/launchctl.log"; echo 3 > "\$s/\$l" ;;
  print) l=\$(basename "\$2"); [ -e "\$s/\$l" ] || { echo "print \$l gone" >> "$tmp/launchctl.log"; exit 1; }
         v=\$(cat "\$s/\$l")
         if [ "\$v" = up ]; then :; elif [ "\$v" -le 1 ]; then rm "\$s/\$l"; else echo \$((v - 1)) > "\$s/\$l"; fi
         echo "print \$l answers" >> "$tmp/launchctl.log"; echo "state = running" ;;
  bootstrap) l=\$(basename "\$3" .plist); echo "bootstrap \$l" >> "$tmp/launchctl.log"
             [ -e "\$s/\$l" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
             echo up > "\$s/\$l" ;;
  *) echo "\$1" >> "$tmp/launchctl.log" ;;
esac
STUB
chmod +x "$tmp/app/build.sh" "$tmp/app/install-hooks.py" "$tmp/bin/"*
: > "$tmp/launchctl.log"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" zsh "$tmp/app/install.sh" >/dev/null 2>&1 || { echo "FAIL: install.sh failed"; cat "$tmp/launchctl.log"; exit 1; }
log="$tmp/launchctl.log"
# awk, not grep: under pipefail a grep with no match would end the test silently before its FAIL line
first_bootstrap=$(awk '/^bootstrap /{print NR; exit}' "$log")
[ -n "$first_bootstrap" ] || { echo "FAIL: install.sh never bootstrapped"; cat "$log"; exit 1; }
for l in $labels; do
  b=$(awk -v w="bootout $l" '$0 == w {print NR; exit}' "$log")
  [ -n "$b" ] || { echo "FAIL: $l was loaded but never booted out"; exit 1; }
  [ "$b" -lt "$first_bootstrap" ] || { echo "FAIL: $l booted out after a bootstrap began"; exit 1; }
  gone=$(awk -v w="print $l gone" '$0 == w {print NR; exit}' "$log")
  [ -n "$gone" ] || { echo "FAIL: install.sh never waited for $l to be gone"; exit 1; }
  first=$(awk -v w="bootstrap $l" '$0 == w {print NR; exit}' "$log")
  [ -n "$first" ] || { echo "FAIL: $l was never bootstrapped"; cat "$log"; exit 1; }
  [ "$gone" -lt "$first" ] || { echo "FAIL: $l bootstrapped before launchd let go of it"; exit 1; }
done
[ "$(grep -c '^bootstrap ' "$log")" -eq 2 ] || { echo "FAIL: expected one bootstrap per label after the wait"; cat "$log"; exit 1; }
echo "ok: install.sh waits for each booted-out label to be gone before bootstrapping"
