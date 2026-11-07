#!/bin/bash
# Captures the raw iPhone, CarPlay and Mac screens that the App Store frames are built from.
#
#   ./Tools/AppStoreScreenshots/capture.sh          (writes to build/raw2 and build/raw3)
#   python3 Tools/AppStoreScreenshots/render.py     (then builds the framed sets)
#
# Every app runs on sample data (-TracksDemoData YES), so no real history, iCloud or Last.fm
# is touched. The iPhone shots are 1206 x 2622 (a 402 x 874 pt iPhone at 3x), the CarPlay
# shots 720 x 480, and the Mac shots 2880 x 1800 window captures with their rounded corners.
# The Mac window is found by the demo process's PID, so a copy of Tracks you already have
# running is never captured. The Mac shots need Screen Recording permission for your terminal.
# The Mac draws its own accent only while the Mac's accent colour is Multicolor.
set -euo pipefail
cd "$(dirname "$0")/../.."

derived="build/screenshots-derived-data"
out="build/raw2"
out3="build/raw3"
iphone="${IPHONE_SIMULATOR:-iPhone 17 Pro}"
mkdir -p "$out/iphone" "$out/carplay" "$out/mac" "$out3/iphone"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
bundle_id="$(xcodebuild -project Tracks.xcodeproj -scheme "Tracks (iOS)" -showBuildSettings 2>/dev/null | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $2; exit}')"

echo "iPhone"
udid="$(xcrun simctl list devices available | grep -F "$iphone (" | head -1 | grep -oE '[0-9A-F-]{36}')"
[ -n "$udid" ] || { echo "No simulator called $iphone"; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" clear
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 100 \
  --operatorName ""

xcodebuild -project Tracks.xcodeproj -scheme "Tracks (iOS)" -configuration Debug \
  -destination "id=$udid" -derivedDataPath "$derived" build -quiet
xcrun simctl install "$udid" "$derived/Build/Products/Debug-iphonesimulator/Tracks.app"

# Opening another app first stops the status bar showing a "back to" link.
xcrun simctl launch "$udid" com.apple.Preferences >/dev/null
sleep 2
xcrun simctl terminate "$udid" com.apple.Preferences

# shot <folder> <name> <light|dark> [launch arguments...]
shot() {
  local folder="$1" name="$2" look="$3"; shift 3
  xcrun simctl ui "$udid" appearance "$look"
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle_id" -TracksDemoData YES -statsRange month "$@" >/dev/null
  sleep 6
  xcrun simctl io "$udid" screenshot "$folder/iphone/$name.png" >/dev/null 2>&1
  echo "  $name"
}
shot "$out" play light -TracksTab play
shot "$out" play-dark dark -TracksTab play -TracksDemoPlaying station
shot "$out" nowplaying light -TracksDemoPlaying station -TracksNowPlaying YES
shot "$out" nowplaying-dark dark -TracksDemoPlaying YES -TracksNowPlaying YES
shot "$out" queue light -TracksDemoPlaying station -TracksNowPlaying YES -TracksQueue YES
shot "$out" summary light -TracksTab summary
shot "$out" summary-dark dark -TracksTab summary
shot "$out" charts light -TracksTab charts -chartKind songs
shot "$out" rhythm light -TracksTab summary -TracksScroll rhythm
shot "$out" history light -TracksTab history
shot "$out" artist light -TracksOpen "artist:mara solis"
shot "$out" records light -TracksTab summary -TracksScroll records
shot "$out" search light -TracksTab search -TracksSearchText "Mara"

# The newer shots: Tracks Radio, moods and genres, Party and Stage.
stage=(-TracksDemoPlaying YES -TracksNowPlaying YES -TracksStage YES)
shot "$out3" play-dark dark -TracksTab play
shot "$out3" radio-queue dark -TracksDemoPlaying station -TracksNowPlaying YES -TracksQueue YES
shot "$out3" mood-chill dark -TracksTab play -TracksMood chill
shot "$out3" mood-light light -TracksTab play -TracksMood feelGood
shot "$out3" genre dark -TracksTab play -TracksGenre jazz
shot "$out3" party light -TracksTab play -TracksParty YES
# History filtered to Radio, so every row carries the radio glyph.
shot "$out3" history-radio light -TracksTab history -TracksHistoryFilter radio
shot "$out3" stage-orb dark "${stage[@]}" -stageLayout visualizer -stageVisualizer halo -stageOrientation portrait
read -r -p "  Turn the simulator to landscape (Device > Rotate Left), then press Return. "
shot "$out3" stage-bars dark "${stage[@]}" -stageLayout cover -stageVisualizer waveform -stageOrientation landscape
shot "$out3" stage-poster dark "${stage[@]}" -stageLayout poster -stageVisualizer waveform -stageOrientation landscape
read -r -p "  Turn the simulator back to portrait, then press Return. "
xcrun simctl ui "$udid" appearance light

echo "CarPlay"
# CarPlay draws on the simulator's external display. Open it once from Simulator's menu,
# I/O > External Displays > CarPlay, then Tracks puts its own scene there.
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl launch "$udid" "$bundle_id" -TracksDemoData YES >/dev/null
read -r -p "  Open Tracks on the CarPlay screen at Listen Now, then press Return. "
xcrun simctl io "$udid" screenshot --display=external "$out/carplay/listen-now.png" >/dev/null 2>&1
echo "  listen-now"
read -r -p "  Tap Library on the CarPlay screen, then press Return. "
xcrun simctl io "$udid" screenshot --display=external "$out/carplay/library.png" >/dev/null 2>&1
echo "  library"
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true

echo "Mac"
xcodebuild -project Tracks.xcodeproj -scheme "Tracks (macOS)" -configuration Debug \
  -derivedDataPath "$derived" -allowProvisioningUpdates build -quiet
app="$derived/Build/Products/Debug/Tracks.app/Contents/MacOS/Tracks"

window_of() {
  swift -e 'import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}' "$1"
}

# The window is sized to 1440 x 900 pt so the capture comes out at 2880 x 1800 on a Retina
# display, and the Mac is dark for every shot, the way the frames are drawn.
mac_shot() {
  local name="$1"; shift
  "$app" -TracksDemoData YES -TracksActivate YES -AppleInterfaceStyle Dark "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep 8
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set {position, size} of window 1 to {{40, 40}, {1440, 900}}" >/dev/null 2>&1 || true
  sleep 2
  local wid
  wid="$(window_of "$pid")"
  if [ -n "$wid" ]; then
    screencapture -l "$wid" -o -x "$out/mac/$name.png"
    echo "  $name"
  else
    echo "  $name: no window found"
  fi
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}
mac_shot listen-now -TracksSidebar listenNow
mac_shot full-player -TracksSidebar listenNow -TracksDemoPlaying YES -TracksNowPlaying YES
mac_shot summary -statsRange month -TracksSidebar summary
mac_shot history -TracksSidebar history
mac_shot radio -TracksSidebar radio
mac_shot mood-chill -TracksSidebar radio -TracksMood chill
mac_shot top-artists -TracksSidebar topArtists -chartSpan week
mkdir -p "$out3/mac"
for name in history radio mood-chill top-artists; do mv "$out/mac/$name.png" "$out3/mac/$name.png"; done

# Stage runs full screen, so it's captured as the whole display rather than a window.
"$app" -TracksDemoData YES -TracksActivate YES -AppleInterfaceStyle Dark -TracksDemoPlaying YES -TracksStage YES \
  -stageLayout cover -stageVisualizer waveform >/dev/null 2>&1 &
pid=$!
read -r -p "  Put the Stage window in full screen on the built-in display, then press Return. "
screencapture -x -m "$out3/mac/stage.png"
echo "  stage"
kill "$pid"; wait "$pid" 2>/dev/null || true

echo "Saved to $out"
