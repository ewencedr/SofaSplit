#!/bin/bash
# Builds "SofaSplit.app" (plus the diagnostic TestGame.app) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/SofaSplit.app"
mkdir -p "$BUILD"

echo "==> Hook library (universal: arm64 + x86_64 for Rosetta games)"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -dynamiclib -fobjc-arc \
  -framework AppKit -framework GameController -framework IOKit \
  -install_name @rpath/libSofaSplitHook.dylib \
  -o "$BUILD/libSofaSplitHook.dylib" Hook/SofaSplitHook.m Hook/SteamLobbyEmu.m
codesign --force --sign - "$BUILD/libSofaSplitHook.dylib"

echo "==> Swift app + CLI"
# Release products live under build/ so `rm -rf build` removes everything this script makes.
swift build -c release --scratch-path "$BUILD/.swiftpm"
BIN="$(swift build -c release --scratch-path "$BUILD/.swiftpm" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Handlers"
# Distinct names: the file system is case-insensitive, so "SofaSplit" and "sofasplit" would collide.
cp "$BIN/SofaSplitApp" "$APP/Contents/MacOS/SofaSplitApp"
cp "$BIN/sofasplit" "$APP/Contents/MacOS/sofasplit"
cp "$BUILD/libSofaSplitHook.dylib" "$APP/Contents/Resources/"
cp Handlers/*.js "$APP/Contents/Resources/Handlers/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SofaSplit</string>
  <key>CFBundleDisplayName</key><string>SofaSplit</string>
  <key>CFBundleIdentifier</key><string>io.github.ewencedr.sofasplit</string>
  <key>CFBundleExecutable</key><string>SofaSplitApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc, no hardened runtime: the launcher must be allowed to pass DYLD_* variables to games.
codesign --force --deep --sign - "$APP"

echo "==> TestGame.app (diagnostic, signed with hardened runtime to exercise re-signing)"
TG="$BUILD/TestGame.app"
rm -rf "$TG"
mkdir -p "$TG/Contents/MacOS"
swiftc -O TestGame/main.swift -o "$TG/Contents/MacOS/TestGame"
cat > "$TG/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TestGame</string>
  <key>CFBundleIdentifier</key><string>io.github.ewencedr.sofasplit.testgame</string>
  <key>CFBundleExecutable</key><string>TestGame</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --options runtime "$TG"

echo
echo "Done:"
echo "  $APP"
echo "  $TG"
