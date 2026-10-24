#!/bin/sh
# builds dist/Asahiro-<version>.dmg with the themed installer window
set -e
cd "$(dirname "$0")/.."

./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/Asahiro.app/Contents/Info.plist)
OUT="dist/Asahiro-$VERSION.dmg"

# background art is generated, regenerate it when the script is newer than the image
if [ ! -f app/Resources/dmg/background.tiff ] || [ scripts/dmg-background.swift -nt app/Resources/dmg/background.tiff ]; then
    swift scripts/dmg-background.swift
    tiffutil -cathidpicheck app/Resources/dmg/background.png app/Resources/dmg/background@2x.png \
        -out app/Resources/dmg/background.tiff
fi

STAGE=$(mktemp -d)
cp -R dist/Asahiro.app "$STAGE/"
rm -f "$OUT"

# icon positions match appPoint and linkPoint in dmg-background.swift. the window is 28pt taller than the
# art to make room for the title bar
create-dmg \
    --volname "Asahiro" \
    --volicon "dist/Asahiro.app/Contents/Resources/AppIcon.icns" \
    --background "app/Resources/dmg/background.tiff" \
    --window-pos 200 160 \
    --window-size 660 448 \
    --icon-size 112 \
    --text-size 13 \
    --icon "Asahiro.app" 170 175 \
    --hide-extension "Asahiro.app" \
    --app-drop-link 490 175 \
    --no-internet-enable \
    "$OUT" "$STAGE"

rm -rf "$STAGE"
echo "built $OUT"
