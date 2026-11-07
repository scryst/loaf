#!/usr/bin/env bash
# install.sh must bring Loaf back when launchd is slow to let go of the old job: the first bootstrap of each label fails
# with "5: Input/output error". Stubs build.sh, install-hooks.py, launchctl, sleep. Needs zsh.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app" "$tmp/bin" "$tmp/home/Library/LaunchAgents"
cp "$repo/install.sh" "$repo/loaf-busy-hook.sh" "$repo"/app.loaf.Loaf*.plist "$tmp/app/"
printf '#!/bin/sh\nexit 0\n' > "$tmp/app/build.sh"
printf '#!/bin/sh\nexit 0\n' > "$tmp/app/install-hooks.py"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
cat > "$tmp/bin/launchctl" <<STUB
#!/bin/sh
echo "\$*" >> "$tmp/launchctl.log"
case "\$1" in
  bootstrap) label=\$(basename "\$3" .plist)
             [ -e "$tmp/tried-\$label" ] && { : > "$tmp/up-\$label"; exit 0; }
             : > "$tmp/tried-\$label"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
  print) [ -e "$tmp/up-\$(basename "\$2")" ] && { echo "state = running"; exit 0; }; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$tmp/app/build.sh" "$tmp/app/install-hooks.py" "$tmp/bin/"*
: > "$tmp/launchctl.log"
if ! HOME="$tmp/home" PATH="$tmp/bin:$PATH" zsh "$tmp/app/install.sh" >/dev/null 2>&1; then
  echo "FAIL: install.sh gave up after one failed bootstrap"; exit 1
fi
grep -q '^kickstart ' "$tmp/launchctl.log" || { echo "FAIL: install.sh never kickstarted Loaf"; exit 1; }
n=$(grep -c '^bootstrap ' "$tmp/launchctl.log")
[ "$n" -eq 4 ] || { echo "FAIL: expected 2 bootstraps per label, saw $n"; exit 1; }
echo "ok: a failed bootstrap is retried and Loaf is started"
