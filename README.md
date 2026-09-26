# HikingApp101 – TrailMind

TrailMind is a personal, offline-first Android hiking app for the UK. It shows **Ordnance Survey maps** (using your own free OS Data Hub key) and **OpenStreetMap** for browsing. It can store licensed maps offline, find waymarked routes or follow imported GPX routes, record a breadcrumb track with a foreground location service, and give you a compass, grid references, elevation profiles and time estimates. You can export hikes as GPX for Strava, and prepare briefings for an on-device Gemma model. The layout adapts to the Galaxy Z Fold cover screen and the inner screen.

> **Safety:** TrailMind supports navigation; it does not replace it. Carry a paper map and compass and know how to use them. GPS, batteries and phone signal all fail. In the UK, call **999/112** and ask for **Police → Mountain Rescue**.

## Status

This is a working MVP foundation, not a finished product. Every feature below is implemented against real APIs. Where a feature depends on a third party, the limits are stated honestly, both here and in the app.

| Area | What works | Honest limits |
|---|---|---|
| Maps | Custom raster tile engine: pan, pinch and double-tap zoom, a follow-me GPS dot with accuracy circle and heading cone, a scale bar, and attribution. Offline tiles are used first, then a disk cache (300 MB, 7 days), then the network. | Raster only. No vector maps and no map rotation. |
| OS maps | OS Maps API **Outdoor / Road / Light** in Web Mercator, and **Explorer & Landranger** (the OS *Leisure* paper-map style, with public rights of way and open access land) in British National Grid, warped onto the map so routes and the GPS dot line up. It uses **your own** OS Data Hub key, which you enter in Settings (it is never bundled). *Save & test* reports whether the key is on the free OpenData plan or a Premium plan. | Outdoor/Road/Light zoom 7–16 is OS OpenData (free) and zoom 17–20 is **Premium**. Explorer & Landranger is OpenData only down to 1:100,000; the 1:50,000 and 1:25,000 detail is Premium. On the free plan TrailMind shows the last free zoom enlarged instead; on a Premium plan it is charged per transaction once the monthly free allowance runs out, and cached for 24 hours at most. The watch shows OS Outdoor when the phone shows Explorer & Landranger. |
| Search | Find places and postcodes with OS Names, or jump offline to an OS grid reference or decimal coordinates. Results centre the map with a clearable pin; five recent queries are kept locally. | Place and postcode search needs your OS key and a network connection; OS Names does not search house addresses. |
| OpenStreetMap | Online browsing via tile.openstreetmap.org, with short-term caching. | **Never bulk-downloaded or pre-fetched.** The OSMF tile usage policy forbids that, and `TilePolicy` enforces it in code, including for custom templates on OSM and OpenTopoMap hosts. |
| Offline maps | (1) Download an OS area or a route corridor into an MBTiles pack. This runs as a foreground `dataSync` service that you can pause and resume. It is capped at zoom 16 and 25,000 tiles per pack. With a Premium key a download can also pre-load **Premium detail** (zoom 17 to 19) for 24 hours, for example on the morning of a walk; the pack page shows until when. (2) Import any **raster** `.mbtiles` file you have rights to (made with QGIS, MOBAC or similar). Packs work in flight mode. Zooming in past what the phone holds **enlarges the closest zoom it has**, so the map is not blank offline. The map tints and outlines the areas where the base map you are viewing is on the phone (*Map layers → Hide offline areas* turns this off). | Check that your OS Data Hub plan terms allow offline storage. OS terms allow Premium tiles to be kept for 24 hours only, so they are deleted after that; OpenData zooms stay. Vector (pbf) MBTiles are detected and rejected with an explanation. |
| Routes | **Find routes:** waymarked walking routes from OpenStreetMap (national trails, regional ways, local walks), listed near you or in the map view, or found by name, via the [Waymarked Trails](https://hiking.waymarkedtrails.org) API. One tap adds the route with its heights. Or import GPX (tracks, routes and waypoints) from the file picker or via Open/Share from other apps. Each route gets stats, an elevation profile, a time estimate (Naismith/Langmuir and Tobler, adjusted for your pace and the conditions). You can rename it, delete it, or save/share it as GPX. | Found routes are only as complete as OpenStreetMap: gaps are bridged with straight lines, alternatives are left out, and heights are only downloaded for routes up to 60 km. Komoot, AllTrails and OS Maps route libraries have no open API. No turn-by-turn routing and no offline route *planning*. TrailMind guides you **along the line you imported**. |
| Guidance | Follow a route to see distance and ascent remaining, time left at your pace, progress, and the next waypoint. **Off-route detection** (with hysteresis) triggers vibration and a notification, and shows the bearing back to the route. You can also "Go to" a point (long-press) for a straight-line bearing and distance. **Retrace my steps** (Safety page, or *Retrace* on the watch) follows your recorded track back to where the hike started. The map and the watch dial mark every kilometre, or mile, along the route. | Guidance runs while the app or recording is active. Off-route alerts with the screen off need a hike to be recording. |
| Hike recording | `location` foreground service with GPS every 2 s, filtered for accuracy, jitter and speed. **Every point is written to SQLite immediately.** Pause/resume creates new track segments. It survives the UI being closed, and offers to recover an unfinished hike. Notification actions: Pause and Finish. | Needs "while in use" location only (no background permission). If Android kills the process, recording resumes only when the system restarts the service. Otherwise the app offers recovery. |
| History & export | Each hike shows stats (distance, ascent/descent, moving time, elevation range), a profile and a map view. It can be exported as GPX 1.1 with `<time>` and elevation, using the system save dialog or share sheet. | — |
| Strava | Share or save the GPX, then open **strava.com/upload/select**. The in-app guide explains the steps. | No Strava API/OAuth, because that needs a client secret that must not be embedded in an app. See follow-ups. |
| Compass | Rotation-vector sensor (with accelerometer and magnetometer as a fallback), true north via magnetic declination, and bearing to target. Works with the phone flat or upright. Warns when the magnetometer needs calibrating, and when the field it measures does not match the Earth's at your position (strength and dip from the geomagnetic model), which catches interference the sensor itself reports as calibrated. The watch shows the same warnings on its dial. | Phone compasses are easily disturbed by magnets, cases and metal, and a watch by its magnetic charger. |
| Terrain & safety | Elevation profiles, ascent/descent with a 4 m hysteresis, and an OS grid reference (6/8/10-figure) for your position or any long-pressed point. On phones with a **barometer** (the Galaxy Z Fold has one), altitude and recorded ascent come from air pressure anchored to GPS, and a **storm warning** fires while recording if sea-level pressure falls 4 hPa in 3 hours. The Safety page shows pressure and its trend, and lets you copy/share/SMS your location with its grid reference, call 999, and read UK mountain-rescue guidance. | Without a barometer, altitude comes from GPS. It is converted to height above mean sea level on Android 14+ (`AltitudeConverter`); older versions show ellipsoid height, which is ~50 m off in the UK. The pressure trend needs about 2½ hours of readings while the app is open or recording. There is no DEM or contour data. |
| On-device AI | **Beacon**, the offline hike assistant, builds a rule-based **briefing** on the phone. It covers distance, climb, time, whether you'd finish after sunset, waypoints, and the **mountain forecast** at the route's high point for the hour you'd get there: temperature and feels-like, wind and gusts, rain, low cloud and freezing level, with warnings for strong gusts, cold, ice and poor visibility. The forecast comes from [Open-Meteo](https://open-meteo.com) (no key needed) and is saved on the phone, so fetch it before you go. You can copy a ready-made **Gemma prompt** and open **Google AI Edge Gallery** (`com.google.aiedge.gallery`) to paste it into AI Chat with a Gemma model you have downloaded. | Edge Gallery has **no public SDK or intent API**, so this is a manual copy → open → paste handoff. TrailMind does not run an LLM itself (see follow-ups). |
| Foldables | Layout depends on window width, not device model. Narrow (<600 dp, e.g. the Fold cover screen) shows the map, full-screen pages and a bottom navigation bar. Wide (≥600 dp, the inner screen or tablets) shows a navigation rail, a side pane and a live map; the **full-screen map** button hides the rail and pane (Back or the same button brings them back). Folding or unfolding rebuilds the layout **without restarting the activity**, so recording, the page stack and the map camera survive. Handles edge-to-edge insets and multi-window. | No hinge or tabletop-posture layouts (that needs the AndroidX WindowManager library). |
| Privacy | No accounts, analytics or ads. Data stays on the device. Backup and device transfer are disabled, and the OS key stays local. | — |
| Watch companion | A Wear OS app (tested for Galaxy Watch4, Wear OS 3+) that works with the phone. Its first page is a **navigation dial**: a compass ring that turns with the watch, a pointer along the route (or back to it when off route, or to a go-to point), and your breadcrumb trail and route drawn heading-up around you, with the bezel setting the scale (100 m to 5 km) and a tap switching to north-up. Other pages: the phone's map (including its offline packs), live hike time/distance/ascent with Start/Pause/Resume/Finish and **Retrace**, and your grid reference, altitude and pressure trend. Off-route and weather alerts vibrate. It uses a Bluetooth RFCOMM link to the watch you pick in *Settings → Watch companion*, with **no Google Play services**. The link keeps running with the phone app in the background or the phone in a pocket (a *Watch link* notification on the phone, an ongoing activity on the watch) and while the watch screen is off. | The phone app must have been opened once to start the link. With no hike recording, the watch closes the link after 15 minutes out of view to save battery, and reconnects when you open TrailMind on it. Starting a hike from the watch while the phone app is closed only works when Android lets TrailMind start location tracking from the background (for example with battery optimisation off for TrailMind); otherwise the watch asks you to open TrailMind on the phone. Position comes from the phone's GPS. No always-on (ambient) map and no Wear tile yet. |

## Architecture

```
core/   Pure Kotlin/JVM, no Android. Fully unit-tested.
  geo/     Geodesy (distance, bearing, cross-track), Web Mercator tiles, OSGB36 National Grid, sunrise/sunset, route-piece joining
  gpx/     Streaming-safe GPX 1.0/1.1 parser (XXE-hardened), GPX 1.1 writer
  stats/   Track statistics (hysteresis ascent, moving time), hike time estimator
  nav/     RouteGuide (snap-to-route, remaining distance/ascent, waypoints), distance marks, off-route detector, GPS track filter
  map/     Tile policy (OSM bulk-download block, template validation), route-corridor tile coverage
  weather/ Barometric altitude and pressure trend, mountain forecast wording and warnings
  ai/      Beacon: offline hike briefing + Gemma prompt builder
  watch/   Phone ↔ watch message format (framing, state, route, track, tiles), shared by both apps
app/    Android app, framework APIs only (no AndroidX / Play Services)
  map/       TileMapView (custom View), TileProvider (memory/disk cache, MBTiles, HTTP), MbTiles, DownloadService
  location/  ForegroundLocation, TrackingService (location FGS), TrackingState, LocationHub
  nav/       NavigationController (route following, off-route alerts)
  data/      SQLite (routes, hikes + points, offline packs), preferences, Waymarked Trails route finder, Open-Meteo forecasts
  ui/        MainActivity (adaptive shell), MapScreen, pages, small UI toolkit
  watch/     WatchLink: Bluetooth RFCOMM server for the watch (state, route, track, map tiles, commands), WatchLinkService
wear/   Wear OS companion, framework APIs only (plus AndroidX core and wear-ongoing): LinkService and PhoneLink (RFCOMM client), WatchMapView, 4 vertical pages
```

The app deliberately depends only on the Android framework plus `:core`. That keeps the dependency surface small and auditable, avoids needing Google Play Services, and let the whole app be compiled and linted here even though Google's Maven repository (AndroidX, MapLibre's AndroidX dependencies, AGP) was unreachable. The trade-off: TrailMind has its own raster tile renderer instead of MapLibre, which is the main follow-up for vector maps. The watch app follows the same rule, apart from AndroidX core and wear-ongoing for the ongoing activity, so it talks to the phone over a plain Bluetooth socket instead of Google's Wearable Data Layer.

## Building

### Android Studio / Gradle (normal route)

Open the folder in Android Studio (JDK 17, SDK 36), then run:

```
./gradlew :app:assembleDebug        # APK in app/build/outputs/apk/debug/
./gradlew :wear:assembleDebug       # watch APK in wear/build/outputs/apk/debug/
./gradlew :core:test                # domain unit tests
./gradlew :app:testDebugUnitTest    # app unit tests (tile licensing rules)
```

GitHub Actions (`.github/workflows/android.yml`) runs the unit tests, both debug builds and lint on every push to `main` and every pull request, and keeps the APKs as artifacts.

### End-to-end test on emulators

```
./scripts/e2e.ps1 -Phone emulator-5554 -Watch emulator-5556
```

It builds and installs both apps, clears TrailMind's data, then drives the UI with simulated GPS: onboarding, GPX import, route guidance, recording, off-route alert, pause/resume, GPX export, fold/unfold, full-screen map, OS maps (including offline enlargement), finding a route online, the mountain forecast, and the watch companion (including the link with the phone app in the background and the watch screen off). It prints PASS/FAIL per check and exits with the number of failures; screenshots and logs go to `out-e2e/`. OS map checks run when `local.properties` (git-ignored) contains `trailmind.osApiKey=<your key>`.

The root `build.gradle.kts` pins **AGP 9.0.0** on the root buildscript classpath (it must share a classloader with the Kotlin plugin), and uses AGP 9's built-in Kotlin support. If it doesn't resolve, bump it to the latest stable AGP 9.x.

### Installing on a Galaxy Watch4

1. On the watch: *Settings → About watch → Software information*, tap *Software version* five times, then in *Developer options* turn on *ADB debugging* and *Wireless debugging* (called *Debug over Wi-Fi* on older software). The watch and PC must be on the same Wi-Fi.
2. If the watch offers *Pair new device*, run `adb pair <ip>:<pairing port>` with the code it shows. Then run `adb connect <ip>:<port>` with the address it lists.
3. `adb -s <ip>:<port> install -r wear/build/outputs/apk/debug/wear-debug.apk`, and install the phone APK on the phone as usual.
4. On the phone: *Settings → Watch companion*, turn it on, allow *Nearby devices* and pick the watch. Open TrailMind on the watch and allow *Nearby devices* there too.

### Without AGP (what was verified in this repository)

```
./gradlew -Ptrailmind.coreOnly=true :core:test      # Maven Central only
scripts/build-apk-without-agp.sh --lint              # -> out-apk/TrailMind-debug.apk
adb install -r out-apk/TrailMind-debug.apk
```

The script calls aapt2, `kotlinc` 2.4.0 (downloaded from Maven Central with SHA-1 checks into `.toolcache/`), d8, zipalign and apksigner directly, using `-Werror`. It then runs the SDK's standalone Android lint. The debug keystore is generated locally and git-ignored.

## Setup in the app

1. **OS maps:** create a free account at [osdatahub.os.uk](https://osdatahub.os.uk/) and a project with the **OS Maps API**. Paste the project API key into *Settings → OS Data Hub key*, tap **Save & test**, and pick *OS Maps – Outdoor* from the layers button.
2. **Offline:** go to *Offline → Download an area*. Choose the visible map area or a route corridor, pick a zoom (15–16 is best for walking), and download. With a Premium key, pick *Premium detail* to add zoom 17–19 for the next 24 hours. Alternatively, import a `.mbtiles` file.
3. **Routes:** go to *Routes → Find* to pick a waymarked route near you or search by name, or *Routes → Import* (or open a `.gpx` file from Files, Gmail, Drive and so on). Then *Follow* it, download a corridor for it, or build a briefing.
4. **Record:** tap **Start hike** on the map. For long hikes, exempt TrailMind from battery optimisation.
5. **Strava:** open the hike, then *Upload to Strava…* → share or save the GPX → upload it at strava.com/upload/select.
6. **Beacon (Gemma):** go to *Beacon*, pick a route, then *Copy prompt & open Edge Gallery* and paste it into AI Chat.
7. **Watch:** see *Installing on a Galaxy Watch4* above. On the watch, swipe up/down between Navigate, Map, Hike and Position. On Navigate and Map, turn the bezel (or use −/+) to zoom; tap the dial for north-up, or the map for a route overview.

## Licensing notes

- **OS data:** "Contains OS data © Crown copyright and database rights". OpenData is under the Open Government Licence; Premium follows your OS Data Hub plan. Every OS tile shows this attribution.
- **OpenStreetMap:** © OpenStreetMap contributors (ODbL). Tile usage follows the [OSMF tile policy](https://operations.osmfoundation.org/policies/tiles/). Routes found with Waymarked Trails are OpenStreetMap data too; the *Find routes* page shows the attribution.
- **Open-Meteo:** weather data by Open-Meteo.com (CC BY 4.0), free for non-commercial use. Beacon shows the attribution.
- Icons are Material Symbols paths (Apache 2.0).

## Verified checks

- `./gradlew -Ptrailmind.coreOnly=true :core:test` passes 50 JUnit 5 tests covering geodesy, OS grid, GPX round-trip and XXE, stats, estimator, guidance, off-route, retrace, barometric altitude and pressure trend, tile policy, corridor coverage, route-piece joining, the magnetic interference check, distance marks, the high-point forecast in the briefing and the watch protocol.
- `scripts/build-apk-without-agp.sh --lint` builds and signs an APK (v2+v3). `apksigner verify` passes and `aapt2 dump badging` shows `com.trailmind.app`, minSdk 26, targetSdk 36. Kotlin compiles with 0 warnings. Android lint reports 0 errors and 1 informational warning.
- The AGP build (`./gradlew :app:assembleDebug :app:lintDebug`) passes with Gradle 9.7.1 and AGP 9.0.0 (lint: 0 errors).
- End-to-end run on a Pixel 9 Pro Fold emulator (Android 16, API 36), covering onboarding and permissions, OSM tiles, GPX import (picker and share), route following, off-route alerts, recording with pause/resume from the app and the notification, process-kill recovery, GPX export, compass, go-to, raster MBTiles in flight mode, vector MBTiles rejection, fold/unfold while recording, and dark mode.
- Layout checked on the inner screen, the cover screen, the cover screen in landscape and at 130% font size: no clipped controls or hidden options.
- Watch companion run on a Wear OS 5 emulator (454×454, like a Galaxy Watch4 44 mm) paired over emulated Bluetooth with the phone emulator: map tiles from the phone, live stats, start/pause/resume/finish from the watch, off-route alert, reconnection. `./gradlew :wear:lintDebug` reports no issues.
- `scripts/e2e.ps1` passes all 62 checks on the Fold and watch emulators with a Premium-plan OS key, including Premium tiles and their 24-hour purge, offline enlargement past the cached zooms, finding and adding a route online, and the watch link with the phone app in the background and the watch screen off.
- Real devices: installed and run on a Galaxy Z Fold7 (SM-F966B, Android 16, One UI 8.5) and a Galaxy Watch4 40 mm (SM-R860, 396×396). Checked: GPS fix (±3–4 m), barometer pressure and barometric altitude, inner-screen layout, miles/feet, the watch compass dial, and the Bluetooth link between them, including with the phone app in the background and after the watch screen was off for 25 s.
- **Not yet verified:** an outdoor walk on the real devices (recording, guidance, off-route, retrace), and the GitHub Actions workflow (it runs once pushed).

## Roadmap

### Off-grid mapping

1. **Explorer-style walking maps offline:** pre-load Explorer & Landranger (British National Grid) tiles for an area or route corridor for 24 hours, as the Premium terms allow, and show them on the watch.
2. **Terrain detail:** add contours, elevation sampling, hill shading and slope information from OS Terrain 50 OpenData. Keep this terrain data available offline with downloaded map packs.
3. **Offline vector maps:** adopt **MapLibre Native** and support vector MBTiles/offline packs. Prefer the newer **OS NGD API – Tiles** for new OS integration because the OS Vector Tile API is expected to retire in autumn 2028.
4. **Detailed OS features:** evaluate the OS Features API and OS NGD data for selectable MasterMap-derived features, paths, access information and other useful trail context. Cache only the data and time periods permitted by the user's licence.
5. **Safer offline preparation:** show missing-tile checks, estimated storage and licence/cost warnings before departure, then provide a one-tap readiness check for maps, route, GPS and battery.
6. **Offline route planning:** add on-device walking-route calculation and rerouting over a licensed path network; keep the current imported-GPX and straight-line guidance as offline fallbacks.

### Other follow-ups

- Real on-device LLM: bundle **LiteRT-LM / MediaPipe LLM Inference** with a user-supplied Gemma model file, instead of the Edge Gallery handoff.
- Strava API upload via OAuth through **your own backend**, so the client secret stays off the phone.
- Hinge and tabletop postures with AndroidX WindowManager. Add Robolectric and instrumented UI tests.
