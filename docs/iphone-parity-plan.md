# TrailMind on iPhone (including iPhone Duo): parity plan

This is the plan for bringing the iPhone app level with the Android app, written after researching the Android code,
the iOS 27.1 SDK and Apple's iPhone Duo documentation. Status is tracked at the end.

## What was wrong with the first iPhone build

1. **It ran in compatibility mode on iPhone Duo.** The xtool/SwiftPM link step stamped the binary with the
   deployment target as its SDK version (`LC_BUILD_VERSION sdk 17.0`). iOS 27.1 therefore treated it as an old app:
   Apple's docs say such apps "don't extend under the status bar and camera" on iPhone Duo. Fixed in
   `ios/Package.swift` by linking with `-platform_version ios 17.0 27.1` (checked with `llvm-objdump`: `sdk 27.1`),
   plus the `DT*` Info.plist keys Xcode would add.
2. **It was a different, minimal app**: Apple Maps, three list items and a settings form. It now uses the Android design
   system and structure, and the Android features are being ported one area at a time.

## iPhone Duo: what the SDK provides and how TrailMind uses it

| iOS 27.1 API (verified in the SDK headers) | Use in TrailMind |
|---|---|
| `UIHinge`, `UIHingeInteraction` (status, angle) | `Duo/DuoState.swift` probe; shown on More → Display & fold; refreshes the fold layout. |
| `UIView.reservedRegions(kind: .division)` / SwiftUI `GeometryProxy.reservedRegions(kind:)` | The fold. Book pose: menu on one side, map on the other. Tabletop: map above the fold, pages and navigation below. Nothing is placed across it. |
| `reservedRegions(kind: .occlusion)` | The cameras. The vertical capsule and map controls keep clear of them. |
| `UITraitCollection.verticalBarEdge` / SwiftUI `toolbarVerticalEdge` | Where iOS puts bars vertically (outer display, inner landscape). TrailMind's navigation capsule stands on that edge, icons only, like system bars. |
| Size classes / window size | Android's rule kept: under 600 pt wide is the narrow layout (capsule), wider is the rail and side pane (29 % of the width, 260–340 pt) over the map. |
| `ArrangementView` | Not used: the shell's own split does the same with the Android look, and the map must stay one live view across poses. |

All iOS 27.1 calls are behind `#available(iOS 27.1, *)`; on other iPhones the layout is the Android one.

## Architecture

- One SwiftPM module (`ios/TrailMind`), built and signed on Linux/WSL with xtool (`scripts/ios-xtool.sh`), and an XcodeGen
  spec (`ios/project.yml`) for Macs.
- `Core/`: the Android `core` library ported line for line to Foundation-only Swift, with its unit tests ported
  (`ios/TrailMindTests`), run on Linux (`ios-xtool.sh test`). Same maths, thresholds and wording on both platforms.
- `Design/`: the Android palette (day/night), type scale, the Android vector icons drawn from the same path data, and the
  `Ui.kt` components (tonal cards, frosted glass cards, pill buttons, chips, stat grids, list rows, banners, page header).
- `App/` + `Duo/`: the map-first shell (narrow capsule, wide rail and pane, fold splits), navigation stack per tab, dialogs.
- `Data/`: the Android SQLite schema and queries on the system SQLite; settings with the Android keys; keys and tokens
  in the Keychain.
- `Map/`: MapKit with TrailMind's tile engine — OS Outdoor/Road/Light, OS Explorer & Landranger warped from the British
  National Grid, OpenStreetMap, Apple Maps, old maps faded over the base map; packs → cache → network, Premium kept
  24 hours, last free zoom enlarged.
- `Features/`: one folder per area, ported from the Android pages and services.

## Android feature → iPhone implementation

| Android | iPhone |
|---|---|
| Custom raster tile view, heading-up, follow, scale, OS branding | MapKit + custom tile overlays; heading from `MapHeading` (course when walking, compass when still) |
| OS Maps API layers incl. Explorer & Landranger (BNG) | Same API and key; BNG tiles warped per tile |
| Offline packs, MBTiles import, 24 h Premium renewal | Same rules; files in Application Support; renewal reminders as local notifications |
| Search: OS Names, grid refs, coordinates, what3words | Same, plus Apple Maps search when there is no OS key |
| Routes: Waymarked Trails, planner (BRouter), GPX import/export, facilities (Overpass), readiness, terrain, LiDAR | Same services; Swift Charts elevation profile; Files/share sheet for GPX |
| Hike recording service (2 s GPS, filtering, segments, recovery, auto-pause in a vehicle) | Core Location background updates with the blue indicator; every point written to SQLite at once |
| Guidance: off-route, go-to, retrace, distance marks, daylight guard | Same logic; haptics and local notifications |
| Compass with declination and interference checks, barometer | Core Location true heading; magnetometer field check; CMAltimeter |
| Safety: SOS text, what3words, 999/112, check-in, fall alarm | Message composer (iOS needs the user to tap Send), `tel:` links, local notifications with actions, Core Motion fall detection |
| Satellite network detection, GNSS sky plot | Not possible on iOS (no public API); telemetry page shows what iOS provides, and points to iPhone's Emergency SOS via satellite |
| Trip groups over Bluetooth LE Coded, UWB find | iPhone-to-iPhone groups over Multipeer Connectivity with the same sealed frames; listening for Android members over Bluetooth where iOS allows; Nearby Interaction (UWB) to find a member |
| Strava (manual and automatic posting) | Same API; sign-in with `ASWebAuthenticationSession`; retries in the background |
| Beacon briefing (rule-based) + Gemma prompt | Same briefing and mountain forecast; Apple Intelligence on-device model writes it up when available |
| Wear OS watch companion | Not ported (needs a watchOS app target) |

## Testing

1. Linux: every ported core test (`ios-xtool.sh test`).
2. iOS 27.1 SDK build with xtool; binary checked for `sdk 27.1`.
3. Smoke test on a non-Duo iPhone if connected; then, with permission, on iPhone Duo: closed, open (portrait and
   landscape), book and tabletop poses, using More → Display & fold to confirm what iOS reports.
