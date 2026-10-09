#!/bin/zsh
# Builds "Mini Player.app" (Apple Silicon + Intel) and installs it to ~/Applications (no admin needed).
set -e
cd "$(dirname "$0")"
APP="build/Mini Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14.0 \
    MiniPlayer.swift -o "build/MiniPlayer-$arch"
done
lipo -create build/MiniPlayer-arm64 build/MiniPlayer-x86_64 -output "$APP/Contents/MacOS/MiniPlayer"
rm build/MiniPlayer-arm64 build/MiniPlayer-x86_64
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
if [[ "$1" != "--no-install" ]]; then
  rm -rf "$HOME/Applications/Mini Player.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/Mini Player.app"
fi
