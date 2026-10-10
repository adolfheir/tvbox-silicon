# iOS / iPadOS 17 compatibility fork

This fork keeps Yingxia's native player and on-device plugin runtime, and lowers only the iPhone/iPad deployment target from 26.0 to 17.0. macOS and tvOS still target 26.0. It is an independent fork of [jo32/tvbox-silicon](https://github.com/jo32/tvbox-silicon), with the original license and attribution preserved.

The default subscription is:

```text
https://cdn.jsdelivr.net/gh/adolfheir/tvbox@master/fty.json
```

It serves the separate [adolfheir/tvbox](https://github.com/adolfheir/tvbox) source-configuration fork through jsDelivr. The connected iPad timed out on the GitHub raw host; the CDN response was verified byte-for-byte against the fork file. On first launch, import the default subscription in Settings. Updating an existing app preserves its saved subscription; select the default address and save to switch it.

## Compatibility changes

- iOS 17 uses the classic `TabView` API, `ScrollViewReader` for horizontal source/category strips, and a simple settings group. iOS 18+ retains the newer tab and scrolling APIs.
- iOS 17–25 uses material-backed surfaces and `safeAreaInset` for search. iOS 26+ retains native glass, search bars and tab minimization.
- QuickJS, the DEX interpreter, Java host and static Apple JVM/native bindings are retained. Lowering the deployment target does not make every third-party Android plugin compatible.
- The Java-host build scripts default to JDK 17, matching their Java 17 bytecode target. The Apple JVM script separately downloads its pinned boot JDK.

## Build for a physical device

Use a current Xcode SDK, XcodeGen, JDK 17, Maven, CMake, Autoconf and Python 3. The native-runtime scripts download and verify their pinned dependencies. A full first build needs several gigabytes of free space and can take a while.

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
Scripts/build-java-host.sh
JOBS=4 Scripts/package-apple-runtime.sh ios
# These folders are referenced by the macOS target during project generation.
mkdir -p build/ScriptHost build/PythonHost
xcodegen generate
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData-iOS17 CODE_SIGNING_ALLOWED=NO build
```

The resulting `build/DerivedData-iOS17/Build/Products/Debug-iphoneos/TVBox-iOS.app` is **unsigned**. To install, open `TVBox.xcodeproj`, select your signing team and connected iPad, and run `TVBox-iOS`. Xcode must register the device and issue a provisioning profile containing its UDID. Enable **Settings → Privacy & Security → Developer Mode** on the iPad and complete its restart/confirmation prompts. Devices with a passcode require this confirmation on the device itself.

This flow is development sideloading; it does not submit anything to the App Store. Do not commit signing profiles, certificates, Apple account credentials or device data.

## Verification

As of 2026-10-10:

- The full arm64 iPhone/iPad app builds successfully with deployment target 17.0, including the on-device Java runtime. Both the app's `MinimumOSVersion` and Mach-O minimum OS are 17.0.
- `swift test` passes 95 core tests; `python3 Scripts/check-localizations.py` passes for four languages.
- A real-network **Mac** AVPlayer decoder check plays 瓜子 and 光影 for approximately eight seconds with decoded video frames, and 易听 advances audio playback. This does not establish iPad playback or availability of every source.
- An iPad simulator running iOS 18.2 exercises the debug-forced legacy UI and plays 瓜子 for more than 80 seconds and 光影 for more than 50 seconds with visible video, normal player progress and no reported error. This is not an iPadOS 17 runtime test, and its isolated QA target has no Java runtime.
- On a physical sixth-generation iPad running iPadOS 17.7.11, the full signed app installs successfully and the CDN subscription imports 48 sites and 6 live lists. 瓜子 advances for more than 53 seconds with visible video and no player error. Search returns real results, but individual third-party sources are not all verified; 光影's selected resource returned an unavailable-resource error on this device.
- Optional player danmaku and its verification limits are described in [DANMAKU.md](DANMAKU.md).

Repeat the desktop decoder check with:

```sh
swift run TVBoxProbe --playback-smoke \
  https://cdn.jsdelivr.net/gh/adolfheir/tvbox@master/fty.json \
  build/desktop-playback.json 瓜子 光影 易听
```

The command writes per-source playback time, actual copied video frames, downloaded bytes and failures, and exits unsuccessfully if any selected source fails.

For a Debug app, `-qaLegacyUI 1` selects the iOS 17 UI branches on a newer simulator. `-qaSection home -qaPage play-source:瓜子 -qaMute 1` resolves a real source through `CatalogClient` and opens its first video; playback progress is written to `Library/Caches/qa-playback.json`. These launch arguments do not persist in preferences and the hooks are excluded from Release builds.
