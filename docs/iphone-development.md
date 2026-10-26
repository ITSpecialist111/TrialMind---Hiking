# TrailMind iPhone private-preview development

## Current boundary

The Android app is implemented with Android framework Views, SQLite, location services, sensors, alarms and
Bluetooth. `core` is a **Kotlin/JVM** library, not Kotlin Multiplatform: it uses `java.time`, `java.io`,
`java.security`, `javax.crypto`, JVM XML and other Java APIs. Adding an iOS Gradle target is not a working port.

The [iOS starter](../ios/) is an independent native SwiftUI application (iOS 17+), generated with XcodeGen.
It contains an adaptive navigation layout, a MapKit map with the same online base maps as Android
(**OS Maps Outdoor, Road and Light** from the OS Data Hub raster API in Web Mercator, OpenStreetMap, or Apple
Maps), foreground Core Location, native map heading tracking, a time-stamped location share sheet, opacity
settings and unit tests for location text and tile URLs.

OS Maps need the user's own OS Data Hub key, entered in Settings and kept in the iPhone Keychain (never
bundled). The OS logo and copyright statement are shown on the map, as OS branding requires. Zooms 17 and
closer are OS Premium data: they count against the user's plan and are kept out of the on-disk tile cache.
Apple Maps stays underneath the OS tiles, so zoom levels or areas that OS doesn't cover aren't blank.
OS Explorer/Landranger (`Leisure_27700`) is **not** available yet: it uses the British National Grid, which
needs reprojection or a custom renderer.
It deliberately labels itself **Preview**. It is not a replacement for the Android hiking app.

No Apple SDK, Xcode, signing identity or Mac host was available when this starter was added. Its first
compile, simulator check and device test **must happen on a Mac, or on Linux/WSL with xtool** (below).
Android validation does not validate these Swift files.

## Build and install from Windows (WSL) or Linux, no Mac

[omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev) wraps [xtool](https://xtool.sh)
to build SwiftPM iOS apps on Linux, sign them with an Apple ID and install them on a physical iPhone.
`ios/Package.swift`, `ios/xtool.yml` and `ios/Info-xtool.plist` are the xtool build of the same sources
that `project.yml` gives Xcode; keep the Info.plist values in step. The external project is cloned to
`~/omarchy-apple-dev` inside Linux, never into this repository.

What you need:

- WSL 2 (Ubuntu) or Ubuntu/Arch/Fedora, about 25 GB free.
- The Xcode `.xip` matching the Swift toolchain (**Xcode 27 for Swift 6.4**), downloaded once with a free
  Apple ID from <https://developer.apple.com/download/all/?q=Xcode>. Full mode is required: the app uses
  SwiftUI `NavigationSplitView`, `Form` and MapKit, which the experimental no-Xcode mode does not provide.
- An Apple ID for `xtool auth`. A free account signs 7-day development builds for your own devices;
  TestFlight needs the paid programme (`ship.sh --upload`).
- The iPhone on USB with **Developer Mode** on (Settings > Privacy & Security), unlocked, and Trust tapped.
  The switch only appears after a developer tool has connected; `pymobiledevice3 amfi reveal-developer-mode`
  shows it.
  The bundle id `com.trailmind.ios.beta` must be unique to your team; change it in `xtool.yml` and
  `project.yml` together if Apple refuses it.

From Windows PowerShell at the repository root ([ios-wsl.ps1](../scripts/ios-wsl.ps1) runs
[ios-xtool.sh](../scripts/ios-xtool.sh) in WSL). USB iPhones are reached through Apple's own Windows device
service (the **Apple Devices** app, usbmuxd on `127.0.0.1:27015`), which WSL sees with mirrored networking.
Do not forward the iPhone into WSL with usbipd-win: small requests work, but installs stall because the
phone rejects its 65,536-byte packet bursts (`asyncReadComplete, message was too large`,
[usbipd-win #867](https://github.com/dorssel/usbipd-win/issues/867)).

```powershell
winget install --id 9NP83LWLPZ9K -s msstore  # once: Apple Devices (Apple's iPhone USB service)
# once: in %USERPROFILE%\.wslconfig put "[wsl2]" and "networkingMode=mirrored", then: wsl --shutdown
# once: an Ubuntu 24.04 distro named trailmind-ios (or pass -Distro <name> to every command)
curl.exe -fLo $env:TEMP\noble.tar.gz https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
wsl --import trailmind-ios $env:LOCALAPPDATA\WSL\trailmind-ios $env:TEMP\noble.tar.gz --version 2
# then inside it as root: add a sudo user, and set [user] default=<user> and [boot] systemd=true in /etc/wsl.conf
scripts\ios-wsl.ps1 setup                    # Swift 6.4, libimobiledevice, xtool; stops at the SDK step
scripts\ios-wsl.ps1 setup -XcodeXip C:\Users\<you>\Downloads\Xcode_27.0.xip   # registers the iOS SDK
scripts\ios-wsl.ps1 test                     # LocationText unit tests on Linux
scripts\ios-wsl.ps1 auth                     # once: Apple ID sign-in (interactive)
scripts\ios-wsl.ps1 devices                  # connected iPhones and their UDIDs
scripts\ios-wsl.ps1 run -Udid <UDID>         # build, sign, install, launch (-Udid needed with 2+ phones)
```

The first time a phone is plugged in, unlock it and tap Trust for Windows. `run` starts Apple's device
service if it is not already running. If phones stop appearing in `devices` (for example after a phone
restarts), close every Apple Devices process (`AppleDevices`, `AMPDevicesAgent`, `AppleMobileDevice*`)
and reopen the Apple Devices app; restarting only the device service is not enough.
xtool installs the app as `XTL-<team id>.com.trailmind.ios.beta`.

On Linux run `scripts/ios-xtool.sh setup|test|auth|devices|build|run` directly.

**`xtool auth` fails with HTTP 503 from `GsService2`:** Apple refuses xtool's old client user agent
([xtool #404](https://github.com/xtool-org/xtool/issues/404)), even before credentials are checked. It is
fixed in xtool 1.24.0 ([#406](https://github.com/xtool-org/xtool/pull/406)). Until omarchy-apple-dev pins
1.24+, apply that PR to `~/.cache/omarchy-apple-dev/xtool-<sha>` with `git apply`, rebuild with
`swift build -c release --product xtool -Xswiftc -no-toolchain-stdlib-rpath` (with `PKG_CONFIG_PATH` and
`LD_LIBRARY_PATH` pointing at `~/.local/imobiledevice/lib`), and copy the binary over
`~/.local/lib/omarchy-apple-dev/xtool-<sha>/xtool`. A made-up account then fails with `-20970` instead.
A free Apple ID works; Developer Program enrolment is not needed for your own devices.

Under WSL a checkout on `/mnt/c` is
copied to `~/trailmind-ios` before building (SwiftPM is slow on, and loses permissions from, Windows drives),
so the app is at `~/trailmind-ios/xtool/TrailMind.app`. `setup` exits with code 3 until the Xcode `.xip`
has been registered. The first launch of a free-account build needs Settings > General > VPN & Device
Management > trust your developer certificate; free-account builds expire after 7 days.

**Cable-free installs (iOS 27 only).** Pair once over USB with `scripts\ios-wsl.ps1 pair-network`, then
with the phone on Wi-Fi: `scripts\ios-wsl.ps1 run-network -PhoneIp <phone IP>`. A plain LAN address is
unmeasured upstream (Tailscale is measured); the phone answers RemotePairing on a port from 49152 to 49167.
The pairing record in `~/.local/share/pymobiledevice3/` is a device credential: keep it out of Git.
iOS 26 and older offer no Linux network pairing, so use USB.

`ios/TrailMindTests` still runs only under Xcode (`xcodebuild test`); `ios-xtool.sh test` covers the
Foundation-only `LocationText` and `MapLayer` (tile URLs, keys, zoom limits) on Linux.

## MacinCloud setup

1. Choose a Mac with a current stable Xcode compatible with the testers' iOS versions. Launch Xcode once,
   accept its licence and install iOS platform/simulator support. For a new device use an Xcode/SDK release
   that explicitly supports it.
2. Clone this private repository onto that Mac. Do not put Apple credentials, certificates or API keys in Git.
3. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
4. From the repository root, run these commands in the **Mac terminal**:

   ```sh
   cd ios
   xcodegen generate
   xcodebuild -list -project TrailMind.xcodeproj
   xcodebuild -project TrailMind.xcodeproj -scheme TrailMind \
     -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
   xcrun simctl list devices available
   xcodebuild -project TrailMind.xcodeproj -scheme TrailMind \
     -destination 'platform=iOS Simulator,id=REPLACE_WITH_AVAILABLE_SIMULATOR_UUID' test
   ```

5. Open the generated project, choose your unique bundle identifier and Apple development team under
   Signing & Capabilities, then run on a physical iPhone. Nothing is signed or distributed by the generator.
6. Before sharing externally: supply an original iOS app icon asset catalog, review App Store Connect
   privacy/export-compliance answers for the actual feature set, fix all Xcode diagnostics and complete
   the tests below. The starter has no release app-icon asset or archive/distribution automation yet.

## iPhone and folding/window changes

Use `NavigationSplitView`, safe areas, Dynamic Type and available scene/window size rather than model names,
hinge coordinates or guessed screen dimensions. No private device APIs or assumed "Duo" SDK are used.
Validate on the exact device/simulator profile once it is available in the installed Apple SDK:

- narrow portrait, landscape and wide windows; change size while location updates are running
- navigation selection and settings survive resizing
- map controls, Apple attribution and the current position remain unobscured
- VoiceOver, large text, increased contrast and reduced transparency
- precise/approximate/denied location, unavailable heading, no signal and stale fixes
- share text contains the original fix time, not the time the Share button was pressed

MapKit provides its own native heading tracking in this starter; the Android heading fix is **not** shared
with it. Real walking tests are needed on both platforms.

## Porting order before hiking trials

| Area | Required iOS work / limit |
|---|---|
| Maps | Done: OS Outdoor/Road/Light (Web Mercator) and OpenStreetMap as MapKit tile overlays, key in Keychain, OS logo and attribution, Premium tiles not cached on disk. To do: OS Explorer/Landranger (BNG reprojection), offline packs with expiry, old-map overlays (MapTiler key), custom sources. |
| Routes and hikes | GPX parsing/writing, local persistent library, route guidance, selected/all deletion, recording and recovery tests. Port pure algorithms with matching golden test fixtures; do not copy Android framework code into Swift. |
| Background recording | Core Location background updates and location background mode, explicit permission explanation, battery/lock-screen tests, interrupted-session recovery. The starter intentionally does not request Always access or record in the background. |
| Location sharing | Add OS grid conversion and opt-in what3words HTTPS conversions. Keep coordinates, accuracy and fix time even when three-word conversion fails. Never block an emergency action on the network. |
| Satellites | Public Core Location exposes location, course, accuracy and heading, **not** Android-style per-satellite GNSS status. Do not fabricate counts or a sky plot. Consider Core Motion altimeter pressure only on supported devices. |
| Groups/watch | Android BLE advertising, UWB and Wear OS protocol need separate iOS feasibility work. Core Bluetooth background limits differ; Apple Watch needs a watchOS companion. Do not promise long-range parity. |
| Safety | iOS does not offer Android's unrestricted automatic SMS sending. Use a user-confirmed message composer/share sheet; design fall alerts within iOS notification/background limits. Do not promise a third-party app can invoke emergency satellite SOS. |
| Strava/assistant | Port OAuth using a system authentication session, secure token storage and supported background transfers; evaluate on-device model runtime separately. |

For shared logic later, first isolate platform-neutral maths and models into a Kotlin Multiplatform module
with Android and iOS tests. Move JVM cryptography, XML, time, files and networking behind platform interfaces
one feature at a time. Keep the shipping Android build working during that migration.

## Friends and family without a public release

- **Recommended: invitation-only TestFlight.** Requires Apple Developer Program/App Store Connect setup.
  Invite friends as external testers by email; do not enable a public invitation link. External testing
  normally requires TestFlight Beta App Review. It does not require a public App Store release.
- Internal TestFlight is for App Store Connect team members (up to 100), not a reason to grant friends
  developer/account permissions. External testing supports up to 10,000 testers.
- Ad Hoc distribution is another private option: register tester device identifiers and manage provisioning.
  It requires paid membership and has device limits. A free personal team is useful for your own local
  device development, not reliable family distribution.
- Keep the first preview explicitly non-safety-critical until offline maps, route recovery, location ageing,
  battery use and emergency UX have been checked on physical iPhones.

Sources: [TestFlight](https://developer.apple.com/testflight/),
[Core Location](https://developer.apple.com/documentation/corelocation),
[MapKit](https://developer.apple.com/documentation/mapkit),
[SwiftUI NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview).
