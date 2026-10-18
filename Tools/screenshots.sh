#!/bin/bash
# Captures App Store and README screenshots from sample data.
#
#   ./Tools/screenshots.sh [out-dir]      (default: build/screenshots)
#
# The ones the README shows are then copied into images/ under the names it uses.
# Builds the Debug apps (the launch arguments that pick a screen only exist in Debug), then
# runs each on sample data with -TracksDemoData YES, which uses an in-memory store and never
# touches real history, iCloud or Last.fm. iPhone shots come out at the size App Store
# Connect wants (1320 × 2868). Mac shots are the main window at its default size; for
# 2880 × 1800 use a Retina display set to "Looks like 1440 × 900". The Mac
# window is found by the demo process's PID, so a copy of Tracks you already have running is
# never captured, and -AppleAccentColor 0 draws the demo in red whatever the Mac's accent is.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-build/screenshots}"
derived="build/screenshots-derived-data"
iphone="${IPHONE_SIMULATOR:-iPhone 18 Pro Max}"
bundle_id="$(xcodebuild -project Tracks.xcodeproj -scheme "Tracks (iOS)" -showBuildSettings 2>/dev/null | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $2; exit}')"
mkdir -p "$out"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

capture_ios() {
  local device="$1" prefix="$2"
  local udid
  udid="$(xcrun simctl list devices available | grep -F "$device (" | head -1 | grep -oE '[0-9A-F-]{36}')"
  [ -n "$udid" ] || { echo "No simulator called $device"; return 1; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl ui "$udid" appearance light

  xcodebuild -project Tracks.xcodeproj -scheme "Tracks (iOS)" -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$derived" build -quiet
  xcrun simctl install "$udid" "$derived/Build/Products/Debug-iphonesimulator/Tracks.app"

  shot() {
    local name="$1"; shift
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle_id" -TracksDemoData YES -statsRange month "$@" >/dev/null
    sleep 5
    xcrun simctl io "$udid" screenshot "$out/$prefix-$name.png" >/dev/null
    echo "  $prefix-$name.png"
  }
  shot 1-summary
  shot 2-charts -TracksTab charts -chartKind songs
  shot 3-rhythm -TracksScroll rhythm
  shot 4-history -TracksTab history
  shot 5-artist -TracksOpen "artist:mara solis"
  shot 6-highlights -TracksScroll highlights
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
}

echo "iPhone"
capture_ios "$iphone" iphone

echo "Mac"
xcodebuild -project Tracks.xcodeproj -scheme "Tracks (macOS)" -configuration Debug \
  -derivedDataPath "$derived" -allowProvisioningUpdates build -quiet
app="$derived/Build/Products/Debug/Tracks.app/Contents/MacOS/Tracks"
window_id() {
  swift -e 'import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}' "$1"
}
mac_shot() {
  local name="$1"; shift
  "$app" -TracksDemoData YES -TracksActivate YES -AppleAccentColor 0 -statsRange month "$@" \
    >/dev/null 2>&1 &
  local pid=$!
  sleep 7
  local wid
  wid="$(window_id "$pid")"
  if [ -n "$wid" ]; then
    screencapture -l "$wid" -o -x "$out/mac-$name.png"
    echo "  mac-$name.png"
  else
    echo "  mac-$name.png: no window found"
  fi
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}
mac_shot 1-summary
mac_shot 2-artists -TracksSidebar topArtists
mac_shot 3-history -TracksSidebar history
mac_shot 4-rhythm -TracksScroll rhythm

echo "Saved to $out"

echo "README"
mkdir -p images
readme() {
  cp "$out/$1.png" "images/screenshot-$2.png"
  echo "  images/screenshot-$2.png"
}
readme iphone-1-summary ios-summary
readme iphone-2-charts ios-charts
readme iphone-3-rhythm ios-rhythm
readme iphone-5-artist ios-artist
readme mac-1-summary mac-summary
readme mac-2-artists mac-charts
