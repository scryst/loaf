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
</dict></plist>
PLIST
codesign --force --sign - "$dest.new"
if [[ -d "$dest" ]]; then trash "$dest"; fi
mv "$dest.new" "$dest"
echo "built $dest"
