#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/.build/Token Calendar.app"
contents="$app/Contents"

mkdir -p "$contents/MacOS"
cp "$binary_dir/TokenCalendar" "$contents/MacOS/TokenCalendar"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Token Calendar</string>
    <key>CFBundleExecutable</key>
    <string>TokenCalendar</string>
    <key>CFBundleIdentifier</key>
    <string>local.tokencalendar.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Token Calendar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
printf '%s\n' "$app"
