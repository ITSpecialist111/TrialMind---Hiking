# HikingApp101 – TrailMind

TrailMind is a personal, offline-first Android hiking app for the UK. It shows **Ordnance Survey maps** (using your own free OS Data Hub key) and **OpenStreetMap** for browsing. It can store licensed maps offline, follow imported GPX routes, record a breadcrumb track with a foreground location service, and give you a compass, grid references, elevation profiles and time estimates. You can export hikes as GPX for Strava, and prepare briefings for an on-device Gemma model. The layout adapts to the Galaxy Z Fold cover screen and the inner screen.

> **Safety:** TrailMind supports navigation; it does not replace it. Carry a paper map and compass and know how to use them. GPS, batteries and phone signal all fail. In the UK, call **999/112** and ask for **Police → Mountain Rescue**.

## Status

This is a working MVP foundation, not a finished product. Every feature below is implemented against real APIs. Where a feature depends on a third party, the limits are stated honestly, both here and in the app.

| Area | What works | Honest limits |
|---|---|---|
| Maps | Custom raster tile engine: pan, pinch and double-tap zoom, a follow-me GPS dot with accuracy circle and heading cone, a scale bar, and attribution. Offline tiles are used first, then a disk cache (300 MB, 7 days), then the network. | Raster only. No vector maps and no map rotation. |
| OS maps | OS Maps API **Outdoor / Road / Light** in Web Mercator, using **your own** OS Data Hub key, which you enter in Settings (it is never bundled). | Zoom 7–16 is OS OpenData (free). Zoom 17–20 is **Premium**, which is charged per transaction once your plan's free allowance runs out. The 1:25k **Leisure** (Explorer-style) layer is only available in British National Grid (EPSG:27700), which TrailMind can't render yet. |
| OpenStreetMap | Online browsing via tile.openstreetmap.org, with short-term caching. | **Never bulk-downloaded or pre-fetched.** The OSMF tile usage policy forbids that, and `TilePolicy` enforces it in code, including for custom templates on OSM and OpenTopoMap hosts. |
| Offline maps | (1) Download an OS area or a route corridor into an MBTiles pack. This runs as a foreground `dataSync` service that you can pause and resume. It is capped at zoom 16 and 25,000 tiles per pack. (2) Import any **raster** `.mbtiles` file you have rights to (made with QGIS, MOBAC or similar). Packs work in flight mode. | Check that your OS Data Hub plan terms allow offline storage. Vector (pbf) MBTiles are detected and rejected with an explanation. |
| Routes | Import GPX (tracks, routes and waypoints) from the file picker or via Open/Share from other apps. Each route gets stats, an elevation profile, a time estimate (Naismith/Langmuir and Tobler, adjusted for your pace and the conditions). You can rename it, delete it, or save/share it as GPX. | No turn-by-turn routing and no offline route *planning*. TrailMind guides you **along the line you imported**. |
| Guidance | Follow a route to see distance and ascent remaining, time left at your pace, progress, and the next waypoint. **Off-route detection** (with hysteresis) triggers vibration and a notification, and shows the bearing back to the route. You can also "Go to" a point (long-press) for a straight-line bearing and distance. | Guidance runs while the app or recording is active. Off-route alerts with the screen off need a hike to be recording. |
| Hike recording | `location` foreground service with GPS every 2 s, filtered for accuracy, jitter and speed. **Every point is written to SQLite immediately.** Pause/resume creates new track segments. It survives the UI being closed, and offers to recover an unfinished hike. Notification actions: Pause and Finish. | Needs "while in use" location only (no background permission). If Android kills the process, recording resumes only when the system restarts the service. Otherwise the app offers recovery. |
| History & export | Each hike shows stats (distance, ascent/descent, moving time, elevation range), a profile and a map view. It can be exported as GPX 1.1 with `<time>` and elevation, using the system save dialog or share sheet. | — |
| Strava | Share or save the GPX, then open **strava.com/upload/select**. The in-app guide explains the steps. | No Strava API/OAuth, because that needs a client secret that must not be embedded in an app. See follow-ups. |
| Compass | Rotation-vector sensor (with accelerometer and magnetometer as a fallback), true north via magnetic declination, bearing to target, and a calibration warning. | Phone compasses are easily disturbed by magnets, cases and metal. |
| Terrain & safety | Elevation profiles, ascent/descent with a 4 m hysteresis, and an OS grid reference (6/8/10-figure) for your position or any long-pressed point. The Safety page lets you copy/share/SMS your location with its grid reference, call 999, and read UK mountain-rescue guidance. | Altitude comes from GPS. It is converted to height above mean sea level on Android 14+ (`AltitudeConverter`); older versions show ellipsoid height, which is ~50 m off in the UK. There is no DEM or contour data. |
| On-device AI | A rule-based **briefing** is built offline. It covers distance, climb, time, whether you'd finish after sunset, and waypoints. You can copy a ready-made **Gemma prompt** and open **Google AI Edge Gallery** (`com.google.aiedge.gallery`) to paste it into AI Chat with a Gemma model you have downloaded. | Edge Gallery has **no public SDK or intent API**, so this is a manual copy → open → paste handoff. TrailMind does not run an LLM itself (see follow-ups). |
| Foldables | Layout depends on window width, not device model. Narrow (<600 dp, e.g. the Fold cover screen) shows the map, full-screen pages and a bottom navigation bar. Wide (≥600 dp, the inner screen or tablets) shows a navigation rail, a side pane and a live map. Folding or unfolding rebuilds the layout **without restarting the activity**, so recording, the page stack and the map camera survive. Handles edge-to-edge insets and multi-window. | No hinge or tabletop-posture layouts (that needs the AndroidX WindowManager library). |
| Privacy | No accounts, analytics or ads. Data stays on the device. Backup and device transfer are disabled, and the OS key stays local. | — |

## Architecture

```
core/   Pure Kotlin/JVM, no Android. Fully unit-tested.
  geo/     Geodesy (distance, bearing, cross-track), Web Mercator tiles, OSGB36 National Grid, sunrise/sunset
  gpx/     Streaming-safe GPX 1.0/1.1 parser (XXE-hardened), GPX 1.1 writer
  stats/   Track statistics (hysteresis ascent, moving time), hike time estimator
  nav/     RouteGuide (snap-to-route, remaining distance/ascent, waypoints), off-route detector, GPS track filter
  map/     Tile policy (OSM bulk-download block, template validation), route-corridor tile coverage
  ai/      Offline hike briefing + Gemma prompt builder
app/    Android app, framework APIs only (no AndroidX / Play Services)
  map/       TileMapView (custom View), TileProvider (memory/disk cache, MBTiles, HTTP), MbTiles, DownloadService
  location/  ForegroundLocation, TrackingService (location FGS), TrackingState, LocationHub
  nav/       NavigationController (route following, off-route alerts)
  data/      SQLite (routes, hikes + points, offline packs), preferences
  ui/        MainActivity (adaptive shell), MapScreen, pages, small UI toolkit
```

The app deliberately depends only on the Android framework plus `:core`. That keeps the dependency surface small and auditable, avoids needing Google Play Services, and let the whole app be compiled and linted here even though Google's Maven repository (AndroidX, MapLibre's AndroidX dependencies, AGP) was unreachable. The trade-off: TrailMind has its own raster tile renderer instead of MapLibre, which is the main follow-up for vector maps.

## Building

### Android Studio / Gradle (normal route)

Open the folder in Android Studio (JDK 17, SDK 36), then run:

```
./gradlew :app:assembleDebug        # APK in app/build/outputs/apk/debug/
./gradlew :core:test                # domain unit tests
```

`settings.gradle.kts` pins **AGP 9.0.0**, which uses AGP 9's built-in Kotlin support. That exact version couldn't be verified here because Google Maven was blocked. If it doesn't resolve, bump it to the latest stable AGP 9.x.

### Without AGP (what was verified in this repository)

```
./gradlew -Ptrailmind.coreOnly=true :core:test      # Maven Central only
scripts/build-apk-without-agp.sh --lint              # -> out-apk/TrailMind-debug.apk
adb install -r out-apk/TrailMind-debug.apk
```

The script calls aapt2, `kotlinc` 2.4.0 (downloaded from Maven Central with SHA-1 checks into `.toolcache/`), d8, zipalign and apksigner directly, using `-Werror`. It then runs the SDK's standalone Android lint. The debug keystore is generated locally and git-ignored.

## Setup in the app

1. **OS maps:** create a free account at [osdatahub.os.uk](https://osdatahub.os.uk/) and a project with the **OS Maps API**. Paste the project API key into *Settings → OS Data Hub key*, tap **Save & test**, and pick *OS Maps – Outdoor* from the layers button.
2. **Offline:** go to *Offline → Download an area*. Choose the visible map area or a route corridor, pick a zoom (15–16 is best for walking), and download. Alternatively, import a `.mbtiles` file.
3. **Routes:** go to *Routes → Import* (or open a `.gpx` file from Files, Gmail, Drive and so on). Then *Follow* it, download a corridor for it, or build a briefing.
4. **Record:** tap **Start hike** on the map. For long hikes, exempt TrailMind from battery optimisation.
5. **Strava:** open the hike, then *Upload to Strava…* → share or save the GPX → upload it at strava.com/upload/select.
6. **Gemma:** go to *Assist*, pick a route, then *Copy prompt & open Edge Gallery* and paste it into AI Chat.

## Licensing notes

- **OS data:** "Contains OS data © Crown copyright and database rights". OpenData is under the Open Government Licence; Premium follows your OS Data Hub plan. Every OS tile shows this attribution.
- **OpenStreetMap:** © OpenStreetMap contributors (ODbL). Tile usage follows the [OSMF tile policy](https://operations.osmfoundation.org/policies/tiles/).
- Icons are Material Symbols paths (Apache 2.0).

## Verified checks

- `./gradlew -Ptrailmind.coreOnly=true :core:test` passes 28 JUnit 5 tests covering geodesy, OS grid, GPX round-trip and XXE, stats, estimator, guidance, off-route, tile policy and corridor coverage.
- `scripts/build-apk-without-agp.sh --lint` builds and signs an APK (v2+v3). `apksigner verify` passes and `aapt2 dump badging` shows `com.trailmind.app`, minSdk 26, targetSdk 36. Kotlin compiles with 0 warnings. Android lint reports 0 errors and 1 informational warning.
- **Not yet verified:** running on a real device or emulator (none was available), and the AGP/Android Studio build.

## Follow-ups

- Vector maps via **MapLibre Native** plus the OS Vector Tile API, with MapLibre's `OfflineManager` for OS vector packs.
- EPSG:27700 tile grid support for the OS **Leisure 1:25k** layer, where your plan allows it.
- Real on-device LLM: bundle **LiteRT-LM / MediaPipe LLM Inference** with a user-supplied Gemma model file, instead of the Edge Gallery handoff.
- Strava API upload via OAuth through **your own backend**, so the client secret stays off the phone.
- Hinge and tabletop postures with AndroidX WindowManager. Robolectric and instrumented UI tests.
- DEM-based terrain (slope shading, contours) from OS Terrain 50 (OpenData).
