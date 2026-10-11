#!/bin/bash
# Unified acceptance in a separate simulator bundle. Never installs a stub
# runtime into the user's device app. Real-service danmaku + fixture playback.
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR_ID="${1:?Usage: Scripts/test-playback-ui.sh <iPad simulator UUID>}"
shift
OUT=build/PlaybackUI
mkdir -p "$OUT"
if lsof -tiTCP:8776 -sTCP:LISTEN >/dev/null; then
  echo 'Port 8776 is occupied; stop the previous QA server first.' >&2
  exit 1
fi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=2' \
  -f lavfi -i 'anullsrc=r=44100:cl=stereo' -t 300 -c:v libx264 -preset ultrafast \
  -g 2 -c:a aac -movflags +faststart "$OUT/clip.mp4"
python3 Scripts/qa-server.py --port 8776 --media "$OUT/clip.mp4" > "$OUT/server.log" 2>&1 &
QA_SERVER_PID=$!
trap 'kill "$QA_SERVER_PID" 2>/dev/null || true' EXIT
cat > "$OUT/RuntimeUnavailable.c" <<'C'
#include <stdlib.h>
#include <string.h>
char *TVAppleRuntimeRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"JAR runtime excluded from isolated UI acceptance\"}");
}
C
cat > "$OUT/project.yml" <<'YAML'
name: PlaybackUI
options:
  deploymentTarget:
    iOS: '17.0'
packages:
  TVCore:
    path: ../..
targets:
  PlaybackUI:
    type: application
    platform: iOS
    sources:
      - path: ../../App
      - path: ../../Config/iOS/Assets.xcassets
      - path: RuntimeUnavailable.c
    dependencies:
      - package: TVCore
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.playback
      TARGETED_DEVICE_FAMILY: '1,2'
      ENABLE_DEBUG_DYLIB: NO
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Playback UI QA
        UILaunchScreen: {}
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
  PlaybackUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: ../../UITests
    dependencies:
      - target: PlaybackUI
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.playback-tests
      GENERATE_INFOPLIST_FILE: YES
schemes:
  PlaybackAcceptance:
    build:
      targets:
        PlaybackUI: all
        PlaybackUITests: [test]
    test:
      targets: [PlaybackUITests]
YAML
xcodegen generate --spec "$OUT/project.yml"
xcodebuild -project "$OUT/PlaybackUI.xcodeproj" -scheme PlaybackAcceptance \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never test "$@"
