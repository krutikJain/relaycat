#!/bin/zsh
# Builds Relaycat.app as a universal (Apple silicon + Intel) app for macOS 14 or later.
#   ./build.sh            build into ./build
#   ./build.sh --install  build and copy to /Applications
#   ./build.sh --debug    include the screenshot and test hooks
# The app icon in Resources/AppIcon.icns is drawn by SwapCatLogo in Sources/Mochi.swift. To redraw it:
#   ./build.sh --debug && RELAYCAT_ICON=build/AppIcon.iconset build/Relaycat.app/Contents/MacOS/Relaycat
#   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
set -e
cd "$(dirname "$0")"

BUNDLE_ID=${BUNDLE_ID:-app.relaycat.mac}
VERSION=${VERSION:-1.0.0}
MIN_MACOS=14.0
BUILD=build
APP=$BUILD/Relaycat.app
FLAGS=(-O -swift-version 5 -parse-as-library)
[[ " $* " == *" --debug "* ]] && FLAGS+=(-D DEBUG)

rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $BUILD/arch
for ARCH in arm64 x86_64; do
  swiftc "${FLAGS[@]}" -target $ARCH-apple-macos$MIN_MACOS Sources/*.swift -o $BUILD/arch/Relaycat-$ARCH
done
lipo -create $BUILD/arch/Relaycat-arm64 $BUILD/arch/Relaycat-x86_64 -output $APP/Contents/MacOS/Relaycat

# A content-hashed icon name and a fresh build number keep macOS from showing a cached icon.
ICON_ID=AppIcon-$(shasum Resources/AppIcon.icns | cut -c1-8)
BUILD_NUMBER=$(date +%Y%m%d%H%M%S)
cp Resources/AppIcon.icns $APP/Contents/Resources/$ICON_ID.icns

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Relaycat</string>
  <key>CFBundleDisplayName</key><string>Relaycat</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Relaycat</string>
  <key>CFBundleIconFile</key><string>$ICON_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

# Ad-hoc signature pinned to the bundle id, so macOS keeps Accessibility access across rebuilds.
codesign --force --deep --sign - --identifier $BUNDLE_ID -r="designated => identifier \"$BUNDLE_ID\"" $APP

if [[ " $* " == *" --install "* ]]; then
  pkill -x Relaycat 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Relaycat.app
  cp -R $APP /Applications/Relaycat.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Relaycat.app
  echo "Installed /Applications/Relaycat.app"
fi
echo "Built $APP ($(lipo -archs $APP/Contents/MacOS/Relaycat))"
