#!/bin/zsh
# Builds Loaf into an app bundle: ./build.sh [dest dir, default ~/Applications]. install.sh does the whole install.
set -euo pipefail
cd "${0:A:h}"
dest="${1:-$HOME/Applications}/Loaf.app"
mkdir -p .build
swiftc -O main.swift -o .build/Loaf -framework AppKit -framework IOKit -framework SwiftUI -framework AVFoundation -framework CoreAudio
rm -rf "$dest.new"; mkdir -p "$dest.new/Contents/MacOS" "$dest.new/Contents/Resources"
cp .build/Loaf "$dest.new/Contents/MacOS/"
cp -R loaf "$dest.new/Contents/Resources/"
cp art/AppIcon.icns loaf-watchdog.sh "$dest.new/Contents/Resources/"
cat > "$dest.new/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.loaf.Loaf</string>
<key>CFBundleName</key><string>Loaf</string>
<key>CFBundleDisplayName</key><string>Loaf</string>
<key>CFBundleExecutable</key><string>Loaf</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$dest.new"
# the old bundle goes to the Trash where this macOS has `trash`, and is removed where it does not
if [[ -d "$dest" ]]; then if command -v trash >/dev/null; then trash "$dest"; else rm -rf "$dest"; fi; fi
mv "$dest.new" "$dest"
echo "built $dest"
