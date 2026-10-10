#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
clang -Wall -Wextra -Werror Tests/Native/RuntimeMemoryBudgetProbe.c -o build/runtime-memory-budget-probe
build/runtime-memory-budget-probe
swift test
for entry in 'macOS|platform=macOS|mac' 'iOS|generic/platform=iOS|ios' 'tvOS|generic/platform=tvOS|tv'; do
  IFS='|' read -r platform destination folder <<< "$entry"
  xcodebuild -project TVBox.xcodeproj -scheme "TVBox-$platform" \
    -destination "$destination" -derivedDataPath "build/Verify-$folder" \
    CODE_SIGNING_ALLOWED=NO build > "build/verify-$folder.log" 2>&1
  echo "$platform build passed (build/verify-$folder.log)"
done
