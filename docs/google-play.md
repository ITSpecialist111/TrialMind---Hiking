# Publishing TrailMind on Google Play

A step-by-step guide for putting the phone app and its Wear OS companion on Google Play, with suggested answers
for every Play Console form. The code side is done: both apps target API 36, the watch app has its own version
code, release builds are minified and signed with your upload key, and the permissions follow Play policy
(see [What changed for Play](#what-changed-for-play)). What remains needs you, your accounts or your judgement.

## 1. One-off setup

1. **Developer account** at [play.google.com/console](https://play.google.com/console): US$25 once, with ID
   checks. A *personal* account must run a closed test with at least 12 testers for 14 days in a row before it can
   publish to everyone. An *organisation* account (needs a D-U-N-S number) skips that rule.
2. **Upload key.** Create it once in PowerShell, keep it out of the repo, and back it up with its password.
   keytool asks for the password, so it never appears on the command line:

   ```
   New-Item -ItemType Directory -Force $env:USERPROFILE\keys
   keytool -genkeypair -v -keystore $env:USERPROFILE\keys\trailmind-upload.jks -storetype PKCS12 -alias upload -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=TrailMind"
   ```

   Then add these lines to `%USERPROFILE%\.gradle\gradle.properties`, which is outside the repo. A PKCS12 key
   uses the store password for the key too:

   ```
   trailmind.upload.storeFile=C:/Users/<you>/keys/trailmind-upload.jks
   trailmind.upload.storePassword=...
   trailmind.upload.keyAlias=upload
   trailmind.upload.keyPassword=...
   ```

   Play App Signing (on by default for new apps) holds the key that signs the app for users. If this upload key is
   ever lost, Play support can reset it.
3. **Privacy policy page.** Fill in the two placeholders in [privacy-policy.md](privacy-policy.md) and publish it
   at a public address; a PDF isn't accepted. This repository is private, so GitHub Pages can't serve it on a free
   plan. Options: a small public repository holding only the policy (with GitHub Pages), a public Gist, or any
   website you run.
4. **A reviewer OS key.** Create a separate project on the [OS Data Hub](https://osdatahub.os.uk/) on the free
   OpenData plan, just for Google's reviewers, so you can revoke it later without touching your own key.

## 2. Build the upload files

1. Raise `trailmind.versionCode` in [gradle.properties](../gradle.properties) by one for every upload, and set
   `trailmind.versionName`. The watch app automatically uses 1,000,000 + that code.
2. Build both bundles:

   ```
   ./gradlew :app:bundleRelease :wear:bundleRelease
   ```

   The files are `app/build/outputs/bundle/release/app-release.aab` and
   `wear/build/outputs/bundle/release/wear-release.aab`.
3. Check the signer. It must be your upload key, not `CN=Android Debug`. Without an upload key configured,
   release builds fall back to the debug key so they can be tested, and Play rejects those:

   ```
   keytool -printcert -jarfile app/build/outputs/bundle/release/app-release.aab
   ```

4. Test the minified build: `./scripts/e2e.ps1 -Release` (add `-Watch <serial>` for the watch).

## 3. Create the app

In Play Console, choose **Create app**: name `TrailMind: Hiking Maps & SOS`, default language English (United
Kingdom), App, Free. Then work through **Policy > App content**:

| Section | Answer |
|---|---|
| Privacy policy | The public address from step 1.3. |
| App access | *All or some functionality is restricted.* Use the reviewer instructions below. |
| Ads | No ads. |
| Content rating | Category *Utility, productivity, communication or other*. Answer No to everything except the question on sharing the user's location with others: Yes, because check-in and SOS texts contain it. |
| Target audience | 18 and over only. It is a safety tool, and this keeps it out of the Families programme. |
| News app | No. |
| Data safety | See [Data safety](#data-safety). |
| Government app | No. |
| Financial features | None. |
| Health | If asked about health features, declare activity tracking (hike recording). TrailMind doesn't use Health Connect. |
| Advertising ID | No. The app doesn't declare `AD_ID` and has no Google Play services. |
| Sensitive permissions | See [Permission declarations](#permission-declarations). |

**Reviewer instructions (App access):**

```
No account is needed. OpenStreetMap maps work straight away. On a narrow screen, Safety and Settings are under More.
OS maps: Settings > Ordnance Survey maps > paste this key: <reviewer key> > Save & test, then choose
"OS Maps - Outdoor" from the map's Layers button.
Fall alarm and SOS text: Settings > Emergency contact (please use a test number, because the text is a real SMS)
> Safety > turn on Frontier safety features and "Detect falls while recording" > Start hike on the map.
The alarm starts after a drop and 90 seconds lying still.
"Send SOS text to ..." on the Safety page sends the same text straight away.
Watch app: needs this phone app on a paired phone; Settings > Watch companion > pick the watch.
Trip groups need two Android 12+ phones: on one, Safety > Trip group > Create group; on the other, Join with code
and type the code shown on the first. Each phone then shows the other on the map. "Bluetooth diagnostics" at the
bottom of the Trip group page shows what the radio is doing.
```

## Data safety

TrailMind has no server. Its data leaves the phone only when it asks the map, weather and routing services for
what's on screen, and when the user texts their contact. Suggested answers:

- **Does your app collect or share any of the required user data types?** Yes.
- **Is all of the user data collected by your app encrypted in transit?** Yes. Every service uses HTTPS, and
  Android blocks cleartext traffic for this app.
- **Do you provide a way for users to request that their data is deleted?** Yes. Users delete routes, hikes and
  settings in the app, or uninstall it. The developer holds no copy.

| Data type | Collected | Shared | Processed ephemerally | Required or optional | Purpose |
|---|---|---|---|---|---|
| Location: approximate location | Yes | No | Yes | Required | App functionality |
| Location: precise location | Yes | No | Yes | Required | App functionality |
| App activity: in-app search history | Yes | No | Yes | Optional | App functionality |

Why these answers:

- **Location is collected.** Map, terrain and facility requests name the area on screen, which is where the user
  is when the map follows them. Forecasts, route snapping and area names send exact points. None of it is stored
  by the developer, so it is *processed ephemerally*. It is *required* because online maps load by default.
- **Not shared.** Google exempts transfers the user starts and expects. That covers check-in and SOS texts to the
  contact the user chose, including the automatic SOS the user turns on. The map, weather and routing services
  only answer the app's requests.
- **Search history** is included as a precaution: place and postcode searches go to OS Names.
- **Not declared:** the emergency contact's name and number, and the OS key, never leave the phone except as the
  SMS recipient or in the OS request itself. Hikes, sensor data and fall events stay on the phone. There are no
  crash reports, analytics or advertising identifiers.
- **Trip groups add nothing to declare**, because of Google's end-to-end encryption exemption: "User data that is
  sent off device, but that is unreadable by you or anyone other than the sender and recipient as a result of
  end-to-end encryption does not need to be disclosed"
  ([Data safety help](https://support.google.com/googleplay/android-developer/answer/10787469)). Positions go
  phone to phone over Bluetooth, sealed with AES-GCM under keys derived from the group code, which only the
  members hold; the developer never has the code, and no server is involved. Everything in the broadcast
  (position, name, member id, status) is encrypted, and the only clear field, the group tag, changes every 15
  minutes. Keep it that way: if group data ever goes through a server, or anything readable is broadcast, declare
  precise location as shared.

Update these answers and the privacy policy if the app ever sends heartbeats, tracks or other data anywhere.

## Permission declarations

### SMS (`SEND_SMS`)

Play allows SMS permissions only for listed uses, and a declaration form appears on upload. Choose **Physical
safety/emergency alerts to send SMS**. Suggested description:

```
TrailMind detects a possible fall while a hike is recording, sounds an alarm and counts down 60 seconds. If the
hiker doesn't answer and has turned on "Send it without asking me", TrailMind sends one SMS with their grid
reference, a map link, the time and battery level to the emergency contact they chose, retries every 2 minutes if
it fails, and texts an all-clear when they tap "I'm OK". SEND_SMS is requested only when the user turns that
option on, and is never used to text emergency numbers. Without it, TrailMind can only prepare the text in the
messages app, which needs a tap on Send: impossible for someone who is injured or unconscious. That is why there
is no alternative way to provide this feature.
```

The video should show: setting the emergency contact; turning on automatic SOS texts, including the permission
prompt; starting a hike; the fall alarm and countdown; the SMS arriving. The alarm needs a free fall, an impact
above 4.5 g and then 90 seconds lying still, so film a short drop onto a firm cushion while recording, then wait.
The Safety page's "Send SOS text to ..." sends the same text at once.

Play also requires the listing to promote this feature prominently, as the description below does. If Google
still refuses, remove `SEND_SMS` from the manifest. The app then prepares the text for the user to send, as it
already does when the permission is off.

### Full-screen intent (`USE_FULL_SCREEN_INTENT`)

When asked whether the app's core function is an alarm clock or calling, answer **No**. Android then leaves the
permission off by default, and the Safety page shows "Allow full-screen alerts" so the user can turn it on.

### Exact alarms

Nothing to declare. The app now asks for `SCHEDULE_EXACT_ALARM`, which users grant in *Alarms & reminders*.
Check-in and the Safety page offer that setting when it's off, and alarms fall back to inexact timing without it.

### Foreground services

Declare each type with a short description and a video link (an unlisted YouTube video is fine):

| Service | Type | Use |
|---|---|---|
| `TrackingService` | location | Records the hike the user starts with **Start hike**, with a notification offering Pause and Finish. Stops when the user finishes. When the user has joined a trip group, it also keeps sharing their position with that group (user-initiated location sharing). |
| `TrackingService` | connectedDevice | Only while the user is in a trip group they created or joined: keeps the group's Bluetooth LE exchange going during the recording, so members' phones keep seeing each other with the screen off. Stops when the hike finishes or the user leaves the group. |
| `DownloadService` | dataSync | Downloads the offline map pack the user asks for, with a progress notification. Stops when done or cancelled. |
| `WatchLinkService` | connectedDevice | Keeps the Bluetooth link to the user's own paired watch, turned on in *Settings > Watch companion*. |
| `WatchLinkService` | location | Sends the phone's position to the watch for its navigation dial and map while the phone is in a pocket. |
| Watch app `LinkService` | connectedDevice | Keeps the watch's link to the phone while the watch screen is off, shown as an ongoing activity. |

The watch link's location use outside a recording is the one most likely to be questioned. Say that the user
turns it on and that the watch has no GPS link of its own in TrailMind.

For the trip-group video: create a group on one phone, join it on a second with the code, start a hike on both,
turn both screens off, walk a few metres and show that each map still updates. Trip groups also need two more
things Google checks: the in-app disclosure shown before the Nearby devices prompt ("Share your location with your
group"), and `BLUETOOTH_SCAN` declared without `neverForLocation`, because the scan results carry positions.

### Precise location (from November 2026)

Every app that asks for `ACCESS_FINE_LOCATION` must complete a Play Console declaration. It opens in November 2026
and becomes mandatory on 27 January 2027, with a 30-day self-extension available
([policy](https://support.google.com/googleplay/android-developer/answer/17033915)). Google names "continuous,
real-time tracking while the app is active, such as fitness tracking or active navigation" as a use that justifies
precise location. Choose live tracking or navigation, and describe it like this:

```
TrailMind records the hiker's GPS track every 2 seconds while they record a hike, in a foreground service that
the hiker starts and stops. It also shows their position on the map, guides them along a route, and warns when
they leave it by more than a few tens of metres. Grid references and SOS texts need a position accurate to
metres. In a trip group the hiker creates or joins, it shares that position, end-to-end encrypted over Bluetooth,
with the group's phones, so the party can see each other on the map and find someone who has fallen. Coarse
location (about 3 km²) can't follow a path or find a person, and the one-time location button can't record a
continuous track.
```

Reuse the recording video from the foreground-service declaration. The location button itself is required only for
apps targeting API 37 or higher whose precise location is for one-off actions, so it doesn't apply while TrailMind
targets API 36.

## 4. Store listing

**App name** (30 characters at most):

```
TrailMind: Hiking Maps & SOS
```

**Short description** (80 characters at most):

```
Offline UK hiking maps, GPS tracks, route alerts and a fall alarm with SOS text
```

**Full description:**

```
TrailMind is a hiking app for Great Britain that keeps working when the signal doesn't.

SAFETY
• Fall alarm: while you record a hike, TrailMind watches for a hard fall. It sounds an alarm and asks if you're OK. If you don't answer within 60 seconds, it can text your emergency contact your grid reference, a map link and your battery level. You choose the contact and whether it sends by itself.
• Check-in: set a return time. If you're overdue, TrailMind reminds you and gets a text to your contact ready.
• Trip groups: see your party on the map with no signal. Phones share positions directly over Bluetooth (long range where the phone supports it), encrypted with the group's code, and pass them on along the group. If someone falls, everyone else gets an alert with a bearing to them.
• Safety page: your OS grid reference, location sharing, 999-by-text (emergencySMS) help, air pressure and storm warnings.
• Daylight guard: when to start and when to turn back to finish before sunset.

MAPS
• Ordnance Survey maps with your own free OS Data Hub key, including the Leisure style with public rights of way and open access land.
• OpenStreetMap for browsing.
• Offline map packs for an area or along a route.
• Heights, elevation profiles and steep-ground shading.

ROUTES
• Find national trails and waymarked walks, plan your own route snapped to paths, or import GPX.
• Time estimates (Naismith with Langmuir, and Tobler) matched to your pace.
• Route guidance: distance and climb left, the next waypoint, off-route alerts with the bearing back, and Retrace my steps.
• Parking, toilets, water, food and transport along a route.
• A mountain forecast for the route's high point.

RECORD
• GPS recording with the screen off, pause and resume, barometric height, and GPX export for Strava.

WATCH
• A Wear OS companion with a navigation dial, the map, hike stats and alerts. It needs TrailMind on your phone.

FOLDABLES
• Laid out for both the cover screen and the inner screen of foldable phones.

PRIVACY
• No accounts, ads or analytics. Your routes and hikes stay on your phone.

IMPORTANT
TrailMind is a navigation aid, not a replacement for a paper map, a compass and the skills to use them. GPS, batteries and phone signal fail. In an emergency in the UK, call 999 or 112 and ask for Police, then Mountain Rescue.

Contains OS data © Crown copyright and database rights. Map data © OpenStreetMap contributors. Weather data by Open-Meteo.com. TrailMind is not affiliated with or endorsed by Ordnance Survey.
```

**Graphics:**

- App icon: [play-store/icon-512.png](play-store/icon-512.png), 512 × 512. It's the launcher icon's artwork, full
  bleed, because Play adds its own rounded mask.
- Feature graphic: [play-store/feature-graphic.png](play-store/feature-graphic.png), 1024 × 500, without
  transparency. Both have editable SVG sources beside them. They were rendered with resvg (the
  `@resvg/resvg-js` package on Node), and the feature graphic was saved as 24-bit PNG.
- Phone screenshots: 2 to 8, JPEG or PNG without transparency. Sides must be 320 to 3,840 px, and the long side at
  most twice the short side. Use 1080 px or more for the best placement.
- Tablet screenshots (optional): these help on large screens, and the unfolded Fold layout is a good fit.
- Screenshots from `./scripts/e2e.ps1` runs are in `out-e2e/` and make a starting point, but they show the
  emulator's test route.

**Contact details:** an email address is required. The OpenStreetMap tile policy also asks for a contact on the
store listing.

## 5. Wear OS

1. **Test and release > Advanced settings > Form factors > Add form factor > Wear OS.** Use the dedicated Wear OS
   track, and upload `wear-release.aab` there, never to the phone track.
2. Add at least one Wear OS screenshot: square, 384 × 384 px or larger, app screen only, no watch frame.
3. The watch app is marked non-standalone (it needs the phone app), and the description says so.
4. Opt in to Wear OS review in Advanced settings. Google checks the
   [Wear OS app quality guidelines](https://developer.android.com/docs/quality-guidelines/wear-app-quality);
   reviewers need a phone with TrailMind to pair with.

## 6. Release path

1. **Internal testing:** upload both bundles, install from the Play link on your own phone and watch, and read
   the pre-launch report.
2. **Closed testing:** invite at least 12 testers (for example by Google Group), who must stay opted in for 14
   days in a row. The count and days only matter for new personal accounts.
3. **Production:** apply for production access from the Dashboard, then roll out gradually, for example to 20%
   first.

## 7. Before going public: third-party services

Checked on 28 September 2026 against each operator's own pages. What TrailMind does in the table below is already
in the code; the last column is what's left for you.

| Service | What the operator says | What TrailMind does | Before launch |
|---|---|---|---|
| Ordnance Survey | OpenData is usable "for any purposes" under the Open Government Licence. Premium may be used in "desktop, web and mobile applications". The terms require the OS logo, "a prominent link to our Errors and Omissions Tool", a conspicuous copyright statement and ® on OS trade marks. Premium may only be cached automatically, for 24 hours at most. ([API terms](https://osdatahub.os.uk/legal/apiTermsConditions), [branding](https://docs.os.uk/os-apis/core-concepts/os-api-branding)) | Each user brings their own key, sent only to api.os.uk. The OS logo is on OS maps. Tapping the credit, or Settings > About, links to the OS terms and the Errors and Omissions Tool. Explorer® and Landranger® carry the mark. OpenData goes in offline packs, and Premium is kept for 24 hours at most. | Email OS (draft 3). The terms don't address bring-your-own-key apps, and the 24-hour Explorer pre-load could count as a download rather than a cache. If OS objects, limit pre-loading to OpenData zooms. |
| OpenStreetMap tiles | Needs an identifying User-Agent, visible attribution, caching by headers or for at least 7 days, and conditional requests when cached tiles expire. No bulk downloads or prefetching. Heavy use can be blocked without notice. Recommended: a "Report a map issue" link and a contact email on the store listing. ([tile policy](https://operations.osmfoundation.org/policies/tiles/)) | The User-Agent names the app, its version and its Play listing. Tiles are cached for 7 days, then asked for with `If-Modified-Since`. Nothing is bulk-downloaded. Tapping the on-map credit opens the licence and "Report a map issue". | Give a contact email on the Play listing; Play needs one anyway. |
| Overpass API (facilities) | The operators list "setting up an app for more than just OSM mappers and relying on the public instances as backend" as problematic behaviour. The fair share is about 50 requests a day, counted across all of an app's users. Clients that retry soon after a 429 or 406 get banned. ([manual](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html), [operator's rules](https://community.openstreetmap.org/t/overpass-api-performance-issues/140598)) | Sends one request at a time, only when asked, and keeps the result per route. It waits at least 30 s after a 429 or 406. The French mirror, which now serves only whitelisted users, is removed. | Fine for testing and a small audience. Before a wide launch, switch to a source that can take it: a UK facilities pack built from a Geofabrik extract (ODbL), an instance that welcomes apps (private.coffee asks to be told first), or your own. |
| Waymarked Trails (find routes) | The API "was never meant to be public", its format may change, and endpoints have been removed without notice ([maintainer](https://github.com/waymarkedtrails/waymarked-trails-site/issues/496)). The site's terms ask for moderate use, no mass downloads, and credit to OpenStreetMap and the site. Heights come from ASTER GDEM (METI and NASA). | Credits OpenStreetMap, Waymarked Trails and ASTER GDEM. Makes one request per search or added route. If the API changes, the page shows an error instead of crashing. | Email the maintainer (draft 1). |
| BRouter (route snapping) | No policy for other apps is published. A 2024 permission request from another app is still unanswered. A collaborator reports "server load problems with unknown users", and the server can block clients by User-Agent. ([issue](https://github.com/abrensch/brouter/issues/732)) | Calls it only while planning, one leg at a time. A leg it can't route stays straight. | Ask the BRouter group (draft 2). Plan B: host your own server (Docker image `ghcr.io/abrensch/brouter`; UK segments are about 360 MB) or run brouter-core on the phone. |
| Open-Meteo (forecast) | Free apps with no ads, subscriptions or in-app purchases count as non-commercial. The free tier allows under 10,000 calls a day, per IP. The credit must link to open-meteo.com (CC BY 4.0). ([terms](https://open-meteo.com/en/terms), [licence](https://open-meteo.com/en/licence)) | One call per route, only when asked. The credit links to Open-Meteo and says TrailMind adds its own warnings. Settings > About links to CC BY 4.0. | Nothing while the app is free. Ads, a subscription, in-app purchases or a price need a paid plan (from €29 a month), using `customer-api.open-meteo.com` with an API key. |
| Terrain tiles on AWS | Open data, free to request. Attribution is required to Copernicus EU-DEM, the Environment Agency, USGS and NOAA. ([registry](https://registry.opendata.aws/terrain-tiles/), [attribution](https://github.com/tilezen/joerd/blob/master/docs/attribution.md)) | Full credits under Map layers > About sources, and a short credit beside terrain data. | Nothing. The dataset is in maintenance mode, so check it still loads before each release. |
| MapTiler Cloud (old maps from the National Library of Scotland) | The free plan is limited to non-commercial use, and bulk downloading, "export" of tiles and server-side caching are prohibited. The NLS layers are CC BY 3.0 and need a credit to the Library with a link. The Library's page says they moved to MapTiler Cloud, with a free tier of 100,000 tile requests a month for non-commercial use. ([NLS API](https://maps.nls.uk/projects/api/), [MapTiler terms](https://www.maptiler.com/terms/cloud/)) | Each user brings their own key, sent only to api.maptiler.com. Tiles are browsed live and kept only in the short-term cache; there is no offline pack, and `maptiler.com` is refused for bulk downloads of custom sources. The credit shows on the map and links to the NLS and MapTiler. Only the tile levels each series was drawn for are requested. | A free key makes this fine for a personal app. A public, free listing sits closer to the edge: each user's own free key keeps their use personal, but check MapTiler's terms and NLS's [commercial re-use page](https://maps.nls.uk/guides/georeferencing/commercial-use) with them before a wide release. Not yet run against MapTiler's live service. |
| Environment Agency LiDAR (1 m DTM) | Open Government Licence v3.0, with the attribution "© Environment Agency copyright and/or database right 2022. All rights reserved." Served by a public WCS on the Defra Data Services Platform with no key; no rate limit is published. ([dataset](https://environment.data.gov.uk/dataset/13787b9a-26a4-4775-8523-806d13af58fc)) | Asks for one 256 m square at a time, two at most in parallel, only when zoomed in close with the LiDAR layer on, for a route check, or for a route's offline map. Saved squares are reused. The credit shows on the map, in route checks, under About sources and in Settings > About, which links to the licence. | Nothing required. For a wide release, tell the Defra Data Services Platform team (via its support page) how the app uses the service. |

### Messages to send before launch

Replace the placeholders, and send from the address you'll put on the Play listing.

**Draft 1: Waymarked Trails** (email lonvia@denofr.de)

```
Subject: TrailMind (Android hiking app) and the Waymarked Trails API

Hello Sarah,

I'm about to publish TrailMind, a free Android hiking app for Great Britain with no ads or subscriptions. Its
"Find routes" page lists waymarked routes near the hiker or by name and lets them add one. It uses these
endpoints of hiking.waymarkedtrails.org/api/v1: /list/by_area, /list/search, /details/relation/{id} and
/details/relation/{id}/way-elevation. Each is called once per tap, never in bulk, and results are kept on the
phone. Requests send the User-Agent "TrailMind/<version> (Android;
+https://play.google.com/store/apps/details?id=com.trailmind.app)". The app credits OpenStreetMap, Waymarked
Trails and ASTER GDEM.

Is this use acceptable, and is there a request rate you'd like the app to stay under? I understand the API may
change without notice; the app shows an error rather than breaking if it does.

Thank you for Waymarked Trails,
<your name>
```

**Draft 2: BRouter** (post to the osm-android-bikerouting Google Group, or open a GitHub issue on abrensch/brouter)

```
Subject: Using brouter.de from a free Android hiking app

Hello,

TrailMind is a free Android hiking app for Great Britain with no ads. When someone plans a route by tapping
points on the map, the app asks https://brouter.de/brouter to route each leg (profile hiking-mountain, format
geojson). That's one request per leg, only while planning: typically 5 to 20 per planned route. Requests send
the User-Agent "TrailMind/<version> (Android; +https://play.google.com/store/apps/details?id=com.trailmind.app)".

Is it acceptable to use the public server this way? If not, or above a certain volume, would you prefer that I
host my own server, and may it download the UK segment files from brouter.de/brouter/segments4?

Thank you,
<your name>
```

**Draft 3: Ordnance Survey** (via https://www.ordnancesurvey.co.uk/contact-us)

```
Subject: OS Maps API in a free Android app where each user enters their own API key

Hello,

TrailMind is a free Android hiking app. It shows OS Maps API tiles (Outdoor, Road, Light and Leisure) and uses
the OS Names API, with an API key each user creates in their own OS Data Hub account and enters in the app. The
key is sent only to api.os.uk. The app shows the OS logo on the map and the copyright statement, and links to
your terms and the Errors and Omissions Tool. OpenData tiles can be saved for offline use. For Leisure zooms 6
to 9 (Premium), the user can fetch an area before a walk, and the app deletes those tiles 24 hours after they
were fetched.

Could you confirm that (1) this bring-your-own-key model is acceptable, and (2) fetching Premium Leisure tiles
for a walk and deleting them after 24 hours counts as caching under the API terms? If not, I'll restrict
offline use to OpenData.

Kind regards,
<your name>
```

## What changed for Play

- `USE_EXACT_ALARM` removed. Play reserves it for alarm clock, timer and calendar apps. The app requests
  `SCHEDULE_EXACT_ALARM` instead, and the Safety page asks for *Alarms & reminders* when the fall alarm is on.
- Version codes: one version in `gradle.properties`, and the watch app's code is 1,000,000 + the phone's.
- Release signing with an upload key from Gradle properties outside the repo. `*.jks` files are git-ignored.
- AGP 9.4.1, whose R8 (9.4) reads Kotlin 2.4 metadata. Release builds also remove unused resources.
- The OS logo is drawn on OS maps (phone and watch). Tapping the map credit opens the source's terms and error
  reporting. Settings > About has the same links, plus OpenStreetMap's, and the Open-Meteo, Waymarked Trails and
  ASTER GDEM credits.
- The User-Agent names the installed version and the Play listing instead of this private repository.
- Tiles that have expired from the cache are asked for conditionally (`If-Modified-Since`).
- Overpass: the closed French mirror is gone, queries go one at a time, and the app waits at least 30 s after a
  429 or 406.
- In-app privacy text: a Privacy card in Settings and a corrected summary on the welcome screen.
- `scripts/e2e.ps1 -Release` tests the minified release build.

## Upcoming changes

- **Precise location declaration:** opens in November 2026 and becomes mandatory on 27 January 2027. See
  [Precise location](#precise-location-from-november-2026).
- **Targeting API 37:** Play requires new apps and updates to target API 36 now, and will move to API 37 around
  August 2027. Lint already notes that API 37 is available. Moving means testing Android 17's behaviour changes, and
  once the app targets 37, Play expects the location button for any one-off precise-location actions.
- **Developer verification:** Android developer verification reaches the UK in 2027. The Play account covers apps
  installed from Play, but sideloaded builds for friends will need a verified developer (or `adb install`).
