#!/bin/sh
# builds dist/Asahiro.app from the rust core and swift front end
set -e
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=26.0
# ci passes the release version and run number, local builds keep the defaults
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

# the injector runs inside wine, the core embeds the committed exe so mingw is only needed to change it
if command -v x86_64-w64-mingw32-gcc >/dev/null; then
    x86_64-w64-mingw32-gcc -O2 -municode -static -s -Wall -o app/Resources/bin/asahiro-inject.exe app/inject/asahiro-inject.c
fi
# the frame pacer and dock icon hooks load into the x86_64 wine, the core embeds the committed dylib like the injector
xcrun clang -arch x86_64 -O2 -Wall -fno-objc-arc -dynamiclib -lobjc -o app/Resources/bin/libasahiro-hooks.dylib app/hooks/asahiro-hooks.m
cargo build --release --manifest-path core/Cargo.toml
rm -f app/.build/release/Asahiro
swift build -c release --package-path app

APP=dist/Asahiro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --package-path app --show-bin-path)/Asahiro" "$APP/Contents/MacOS/Asahiro"
# compiles the icon composer document into the liquid glass asset catalog plus a legacy icns
xcrun actool app/Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --target-device mac \
    --output-partial-info-plist /dev/null >/dev/null
mkdir -p "$APP/Contents/Resources/Fonts"
cp app/Resources/Fonts/*.ttf app/Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Asahiro</string>
    <key>CFBundleDisplayName</key><string>Asahiro</string>
    <key>CFBundleIdentifier</key><string>com.chair.asahiro</string>
    <key>CFBundleExecutable</key><string>Asahiro</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.chair.asahiro</string>
            <key>CFBundleURLSchemes</key><array><string>asahiro</string></array>
        </dict>
    </array>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
