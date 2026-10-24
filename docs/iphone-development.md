# TrailMind iPhone private-preview development

## Current boundary

The Android app is implemented with Android framework Views, SQLite, location services, sensors, alarms and
Bluetooth. `core` is a **Kotlin/JVM** library, not Kotlin Multiplatform: it uses `java.time`, `java.io`,
`java.security`, `javax.crypto`, JVM XML and other Java APIs. Adding an iOS Gradle target is not a working port.

The [iOS starter](../ios/) is an independent native SwiftUI application (iOS 17+), generated with XcodeGen.
It contains an adaptive navigation layout, Apple MapKit map, foreground Core Location, native map heading
tracking, a time-stamped location share sheet, opacity settings and location-formatting unit tests.
It deliberately labels itself **Preview**. It is not a replacement for the Android hiking app.

No Apple SDK, Xcode, signing identity or Mac host was available when this starter was added. Its first
compile, XCTest run, simulator check and device test **must happen on the Mac**. Android validation does
not validate these Swift files.

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
| Maps | Port raster camera/tile caching and licensed OS/BNG reprojection using MapKit tile overlays or an independent renderer. Keep keys in Keychain; maintain OS branding, caching expiry and no OSM bulk download rules. Apple Maps is only the starter background. |
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
