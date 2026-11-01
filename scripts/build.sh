#!/bin/bash
# Builds SofaSplit.app (and the diagnostic TestGame.app) into ./build
#
#   VERSION=1.2.0   version shown in the app (default: 0.0.0-dev)
#   UNIVERSAL=1     build the app for Apple Silicon and Intel (needs Xcode, not just the Command Line Tools)
#   NO_TESTGAME=1   skip TestGame.app
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/SofaSplit.app"
VERSION="${VERSION:-0.0.0-dev}"
mkdir -p "$BUILD"

echo "==> Hook library (universal: arm64 + x86_64, also for Rosetta games)"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -dynamiclib -fobjc-arc \
  -framework AppKit -framework GameController -framework IOKit \
  -install_name @rpath/libSofaSplitHook.dylib \
  -o "$BUILD/libSofaSplitHook.dylib" Hook/SofaSplitHook.m Hook/SteamLobbyEmu.m Hook/DualShock4Bluetooth.m
codesign --force --sign - "$BUILD/libSofaSplitHook.dylib"

echo "==> Swift app + CLI"
SWIFT_FLAGS=(-c release --scratch-path "$BUILD/.swiftpm")
if [ "${UNIVERSAL:-0}" = 1 ]; then SWIFT_FLAGS+=(--arch arm64 --arch x86_64); fi
# Release products live under build/ so `rm -rf build` removes everything this script makes.
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP ($VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Handlers"
# Distinct names: the file system is case-insensitive, so "SofaSplit" and "sofasplit" would collide.
cp "$BIN/SofaSplitApp" "$APP/Contents/MacOS/SofaSplitApp"
cp "$BIN/sofasplit" "$APP/Contents/MacOS/sofasplit"
cp "$BUILD/libSofaSplitHook.dylib" "$APP/Contents/Resources/"
for h in Handlers/*.js; do
  # TestGame.js drives the diagnostic TestGame.app: only for development builds.
  if [ "$(basename "$h")" = TestGame.js ] && [ "${NO_TESTGAME:-0}" = 1 ]; then continue; fi
  cp "$h" "$APP/Contents/Resources/Handlers/"
done
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # drawn by scripts/make-icon.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SofaSplit</string>
  <key>CFBundleDisplayName</key><string>SofaSplit</string>
  <key>CFBundleIdentifier</key><string>io.github.ewencedr.sofasplit</string>
  <key>CFBundleExecutable</key><string>SofaSplitApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Valve or Nucleus Co-op.</string>
</dict></plist>
PLIST
# Ad-hoc, no hardened runtime: the launcher must be allowed to pass DYLD_* variables to games.
codesign --force --deep --sign - "$APP"

if [ "${NO_TESTGAME:-0}" != 1 ]; then
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
fi

echo
echo "Done: $APP"
