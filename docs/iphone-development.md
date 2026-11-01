# TrailMind iPhone private-preview development

## Current boundary

The Android app is implemented with Android framework Views, SQLite, location services, sensors, alarms and
Bluetooth. `core` is a **Kotlin/JVM** library, not Kotlin Multiplatform: it uses `java.time`, `java.io`,
`java.security`, `javax.crypto`, JVM XML and other Java APIs. Adding an iOS Gradle target is not a working port.

The [iPhone app](../ios/) is therefore a native SwiftUI application (iOS 17+) that ports the Android app area by
area, so both behave and look the same:

- `ios/TrailMind/Core/` is the `core` library ported line for line to Foundation-only Swift (same maths, thresholds,
  rounding and wording), with the Kotlin unit tests ported to `ios/TrailMindTests/` and run on Linux.
- `Design/` is the Android design system (palette, type, the Android vector icons, cards, pill buttons, chips...).
- `App/` and `Duo/` are the Android map-first shell (narrow capsule, wide rail and pane) plus the iPhone Duo fold
  layouts; `Map/` is MapKit with TrailMind's own tile engine (OS Maps including Explorer/Landranger, offline packs,
  Premium rules); `Features/` holds one folder per Android area.

What is ported and what iOS cannot do is tracked in [iphone-parity-plan.md](iphone-parity-plan.md).

OS Maps need the user's own OS Data Hub key, entered in Settings and kept in the iPhone Keychain (never
bundled). The OS logo and copyright statement are shown on the map, as OS branding requires. Zooms 17 and
closer are OS Premium data: they count against the user's plan and are kept for at most 24 hours.
It deliberately labels itself a **preview**: it is not yet a replacement for the Android hiking app.

Android validation does not validate the Swift files: build and test them with xtool (below) or Xcode.

## Build and install from Windows (WSL) or Linux, no Mac

[omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev) wraps [xtool](https://xtool.sh)
to build SwiftPM iOS apps on Linux, sign them with an Apple ID and install them on a physical iPhone.
`ios/Package.swift`, `ios/xtool.yml` and `ios/Info-xtool.plist` are the xtool build of the same sources
that `project.yml` gives Xcode; keep the Info.plist values in step. The external project is cloned to
`~/omarchy-apple-dev` inside Linux, never into this repository.

What you need:

- WSL 2 (Ubuntu) or Ubuntu/Arch/Fedora, about 25 GB free.
- The Xcode `.xip` matching the Swift toolchain (**Xcode 27.1 or later for Swift 6.4**: the iPhone Duo APIs are in
  the iOS 27.1 SDK), downloaded once with a free Apple ID from <https://developer.apple.com/download/all/?q=Xcode>.
  Full mode is required: the app uses SwiftUI, MapKit, Swift Charts and the iOS 27.1 SDK, which the experimental
  no-Xcode mode does not provide.
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
scripts\ios-wsl.ps1 setup -XcodeXip C:\Users\<you>\Downloads\Xcode_27.1.xip   # registers the iOS SDK
scripts\ios-wsl.ps1 test                     # the ported core tests on Linux (-Filter <name> for some)
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

`ios-xtool.sh test` builds `ios/TrailMind/Core` and `ios/TrailMindTests` as a Linux SwiftPM package (swift-crypto
stands in for CryptoKit; `TM_TEST_DIR` picks its build directory) and runs every ported test. App-layer code
(SwiftUI, MapKit, Core Location...) only compiles against the iOS SDK, so `ios-xtool.sh build` is its check; Xcode
runs the same tests with `xcodebuild test`.

### Testing on iPhone Duo from Windows

pymobiledevice3 (installed by `setup`) reaches iOS 17+ developer services over a no-root userspace tunnel, so the
phone's screens and logs can be checked from WSL. The developer disk image is mounted on demand (Developer Mode on).

```sh
scripts/ios-xtool.sh screenshot --udid <UDID> --display inner inner.png   # the open display
scripts/ios-xtool.sh screenshot --udid <UDID> --display outer cover.png   # the cover display
scripts/ios-xtool.sh logs --udid <UDID>    # TrailMind's log; "display ..." and "layout ..." lines per pose change
```

- iPhone Duo has two displays and a plain screenshot captures the cover display, which is black while the phone is
  open. The phone must be unlocked: locked screens capture black.
- Each fold, unfold or rotation logs one `display` line (window, safe area, status bar, vertical-bar edge, hinge,
  fold and camera regions) and one `layout` line (the shell's mode and every frame), the same facts as More →
  Display & fold. A `layout` line ends `active=false` when iOS laid TrailMind out in the background (for the app
  switcher on the other display) while another app was on screen: don't take screenshots for those, they show the
  other app.
- `run` stops a running TrailMind before installing: installing over a running copy can stall at
  "Installing 100%" on iOS 27.
- If an install ends with `noDevice`, or a phone vanishes from `devices`, close every Apple Devices process and reopen
  the Apple Devices app (see above).
- `pymobiledevice3 developer core-device` also offers `launch-application` (with `--env`), `location` (simulated
  position), `rotate` (turns the interface; the iPhone 12 obeyed, iPhone Duo did not) and `get-display-info`.
- Debug builds read launch settings, so a check can be set up without touching the phone:
  `launch-application --env TM_BASE=osm --env TM_CENTER=54.4542,-3.2116,13 --env TM_TAB=hikes <bundle id>`
  (also `TM_OFFLINE_ONLY`, `TM_HEADING_UP`, `TM_ONBOARDED=1`, `TM_PAGE=display`; see `App/TestLaunch.swift`).
- An idle map should not redraw: `logs` output with a steady stream of VectorKit "Heavy Frame" lines means a layer
  keeps MapKit busy (for example a tile overlay answering without data), which costs battery on a hike.

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

## iPhone Duo and window changes

iPhone Duo (iOS 27.1) runs an app in a legacy compatibility mode unless its binary says it was built with the
iOS 27.1 SDK. SwiftPM on Linux stamps the deployment target there instead, so `ios/Package.swift` links with
`-platform_version ios 17.0 27.1`; check a build with
`llvm-objdump --macho --private-headers TrailMind | grep -A4 LC_BUILD_VERSION` (`sdk 27.1`).

The shell follows Android's layout rules and adds the fold, using only public iOS 27.1 APIs behind
`#available(iOS 27.1, *)` (other iPhones get the Android layout):

- under 600 pt wide: the floating capsule at the bottom, or standing on the side where iOS puts vertical bars
  (`verticalBarEdge`, the closed outer display), kept clear of the camera (`reservedRegions(kind: .occlusion)`);
- 600 pt and wider (open and flat, or landscape): the rail and the side pane over the map;
- a fold (`reservedRegions(kind: .division)`, refreshed by `UIHingeInteraction`): book pose puts the menu on one
  side of the fold and the map on the other; tabletop stands the map above the fold with pages and the capsule below.

The rules are plain geometry in `Core/Shell/ShellGeometry.swift`, tested on Linux (`ShellGeometryTests`). More →
**Display & fold** shows what the phone reports (window, safe area, vertical bars, hinge and angle, fold and camera
regions), which is the first thing to check on a new device. Validate on the device:

- closed, open, book and tabletop poses, in portrait and landscape; fold and unfold while recording a hike
- navigation selection, the page stack and settings survive every change
- map controls, OS branding and the current position remain unobscured by the fold, cameras and capsule
- VoiceOver, large text, increased contrast and reduced transparency
- precise/approximate/denied location, unavailable heading, no signal and stale fixes
- share text contains the original fix time, not the time the Share button was pressed

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

Testers elsewhere can't use the USB install: Apple's free signing covers only devices plugged into this PC, and
only your own. There are two ways to reach them.

### Free: testers install it with their own Apple ID

```powershell
scripts\ios-wsl.ps1 ipa        # dist\TrailMind-<version>.ipa: unsigned release build with its icons (about 2.5 MB)
```

Send the `.ipa` with [iphone-sideload.md](iphone-sideload.md). Each tester installs it with Sideloadly (or AltStore
or SideStore) on their own Windows PC or Mac, which signs it with their own free Apple ID for their own iPhone. The
app uses no capabilities a free Apple ID can't sign. Their copy stops opening after 7 days until they sign it again
(their data stays), and they need Developer Mode on.

Testers give their copy a bundle ID of their own (`com.trailmind.ios.beta.<name>`): bundle IDs are unique across
all Apple accounts, and keeping `com.trailmind.ios.beta` unregistered leaves it free for TestFlight later. With
another bundle ID, offline map downloads on iOS 26+ don't continue in the background (those task names must start
with the bundle ID); everything else works the same.

### Paid: TestFlight

**Invitation-only TestFlight** needs the paid Apple Developer Program (US$99 a year), and in return testers install
from Apple's TestFlight app with no computer, no weekly re-signing and no Developer Mode. It works from Windows/WSL
with no Mac: `ship` builds the App Store package with omarchy-apple-dev (release build, app icon catalog, Xcode build
keys, App Store signing, privacy manifest at the app root) and checks it offline against App Store Connect's rules
before uploading.

```powershell
scripts\ios-wsl.ps1 ship        # dry run: App Store package signed with a test identity, validated offline
```

Once, as the account holder:

1. Join the paid [Apple Developer Program](https://developer.apple.com/programs/enroll/) with the Apple ID that
   signs in to xtool. Enrolment can take a day or two to be approved.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), register
   the App ID `com.trailmind.ios.beta` (explicit; no extra capabilities). It is permanent for the App Store Connect
   record; if Apple says it's taken, change it in `ios/xtool.yml` and `ios/project.yml` together.
3. In [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** → New App: iOS, a name (it must be unique
   on the App Store, for example "TrailMind Hiking"; the name under the icon stays TrailMind), English (UK), the
   bundle ID above, any SKU. The API can't create apps.
4. Users and Access → Integrations → App Store Connect API → Team Keys → **+**: role **App Manager** (with access to
   Certificates, Identifiers & Profiles). Download the `.p8` (only possible once), and note its Key ID and the Issuer
   ID. Keep the `.p8` outside the repository.
5. Publish [privacy-policy-ios.md](privacy-policy-ios.md) at a public web address after filling in its placeholders;
   external testing needs one. The repository is private, so use, for example, a public gist:
   `gh gist create --public docs/privacy-policy-ios.md` prints its address.

Each build (the build number is the UTC date and time, so it always goes up; the version stays 0.2.0 until changed in
`ios/Info-xtool.plist` and `ios/project.yml`):

```powershell
scripts\ios-wsl.ps1 ship -Upload -AscKeyId <Key ID> -AscIssuerId <Issuer ID> -AscKeyPath C:\keys\AuthKey_<Key ID>.p8
```

The first upload creates the distribution certificate (its private key stays in
`~/.config/omarchy-apple-dev/distribution/` in WSL) and the App Store profile. Processing takes 5–30 minutes; App
Store Connect emails if it finds a problem.

Then in App Store Connect → TrailMind → TestFlight:

1. **Test Information:** a beta description (what to try, and that it's a preview not to rely on for safety), a
   feedback email and the privacy policy address.
2. **External Testing → +** a group (for example "Friends"), add the build, then **Add testers** by email. The first
   build of each version goes to Beta App Review, usually within a day; later builds of the same version normally go
   straight out. Leave the public link off.

Each friend then installs **TestFlight** from the App Store, opens the email invitation on their iPhone (or enters
the redeem code in TestFlight) and taps Install. Updates arrive in TestFlight; screenshots taken in TrailMind can be
sent as feedback, and crash reports reach App Store Connect. Each build stops working 90 days after upload, so send
a new one before then. Testers need their own free [OS Data Hub](https://osdatahub.os.uk/) key (Settings) for OS
maps; OpenStreetMap works without one.

- Internal testing skips Beta App Review and the privacy policy, but each tester must be added as a user on your App
  Store Connect team. For friends, external testing is the better fit.
- Ad Hoc distribution (paid) needs each tester's device identifier and a re-signed build for every new device;
  TestFlight avoids both.
- Keep the preview explicitly non-safety-critical until offline maps, route recovery, location ageing, battery use
  and emergency UX have been checked on testers' iPhones.

Sources: [TestFlight](https://developer.apple.com/testflight/),
[Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers),
[omarchy-apple-dev shipping](https://github.com/joshuaswarren/omarchy-apple-dev/blob/main/docs/SHIPPING.md),
[Core Location](https://developer.apple.com/documentation/corelocation),
[MapKit](https://developer.apple.com/documentation/mapkit).
