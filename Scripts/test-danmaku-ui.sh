#!/bin/bash
# Opt-in live-network test in a separate simulator app; never targets the real app container.
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR_ID="${1:?Usage: Scripts/test-danmaku-ui.sh <iPad simulator UUID>}"
OUT=build/DanmakuUI
mkdir -p "$OUT"
cat > "$OUT/RuntimeUnavailable.c" <<'C'
#include <stdlib.h>
#include <string.h>
/* Isolated UI smoke only. The distributable app links the complete Apple runtime. */
char *TVAppleRuntimeRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"JAR runtime excluded from isolated UI acceptance\"}");
}
C
cat > "$OUT/project.yml" <<'YAML'
name: DanmakuUI
options:
  deploymentTarget:
    iOS: '17.0'
packages:
  TVCore:
    path: ../..
targets:
  DanmakuUI:
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
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.danmaku
      TARGETED_DEVICE_FAMILY: '1,2'
      ENABLE_DEBUG_DYLIB: NO
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Danmaku UI QA
        UILaunchScreen: {}
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
  DanmakuUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: ../../UITests
    dependencies:
      - target: DanmakuUI
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.danmaku-tests
      GENERATE_INFOPLIST_FILE: YES
schemes:
  DanmakuAcceptance:
    build:
      targets:
        DanmakuUI: all
        DanmakuUITests: [test]
    test:
      targets: [DanmakuUITests]
YAML
xcodegen generate --spec "$OUT/project.yml"
xcodebuild -project "$OUT/DanmakuUI.xcodeproj" -scheme DanmakuAcceptance \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO test
