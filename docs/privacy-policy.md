<!--
Before publishing: replace [Developer name] and [contact email] below, then host this page at a public web
address (not a PDF) and paste that address into Play Console > Policy > App content > Privacy policy.
Keep it in step with the Data safety answers in google-play.md whenever the app's network use changes.
-->

# TrailMind privacy policy

*Effective 28 September 2026*

TrailMind is a hiking app for Android phones and Wear OS watches, published by [Developer name] ("we"). This
policy explains what TrailMind does with your information. In short: TrailMind has no accounts, no ads, no
analytics and no servers of our own. Your routes, hikes and settings stay on your devices.

## What stays on your phone

TrailMind stores the following only on your phone (and, for the watch app, on your watch):

- routes you plan or import, and hikes you record, including their GPS tracks and times
- offline map packs and cached map, terrain, weather and facility data
- your settings, including your Ordnance Survey (OS) Data Hub API key, your emergency contact's name and number,
  and check-in and fall alarm settings
- fall alarm events and "group heartbeats" (short summaries of your own position, kept for a short time)
- if you are in a trip group: its name and code (encrypted by Android's keystore), your name in the group, and
  the last positions heard from its members

We never receive this information. TrailMind turns off Android backup, so it is not copied to cloud backups. It
is deleted when you delete it in the app, clear the app's storage, or uninstall TrailMind. A trip group and
everything heard from its members are deleted when you leave it or the trip ends.

## What TrailMind sends, and to whom

TrailMind contacts third-party services directly from your phone, over encrypted connections (HTTPS), only to
provide the feature you are using. Each request contains only what that service needs, as listed below. Like any
website, these services see your phone's IP address and the request, and handle them under their own privacy
policies. TrailMind sends them no name, account or device identifier, apart from your own OS key, which goes to
Ordnance Survey with your OS requests, and your own MapTiler key, which goes to MapTiler with old-map requests.

| Service | Used for | What it receives |
|---|---|---|
| [Ordnance Survey](https://www.ordnancesurvey.co.uk/legal) (OS Maps API, OS Names API) | OS maps, place and postcode search, names for offline areas | The map tiles for the area on screen or being downloaded, what you type into search, or the area being named; your OS API key |
| [OpenStreetMap Foundation](https://osmfoundation.org/wiki/Privacy_Policy) tile servers | OpenStreetMap map | The map tiles for the area on screen |
| [Geospatial Information Authority of Japan](https://maps.gsi.go.jp/development/ichiran.html) (GSI Tiles, cyberjapandata.gsi.go.jp) | Japan maps: GSI Standard Map, Aerial Photo and Hill shading | The map tiles for the area on screen or being downloaded |
| [MapTiler](https://www.maptiler.com/privacy-policy/) (MapTiler Cloud, api.maptiler.com), serving the National Library of Scotland's old Ordnance Survey maps | Old maps faded over the map | The map tiles for the area on screen; your MapTiler key |
| Mapzen Terrain Tiles on [Amazon Web Services](https://aws.amazon.com/privacy/) | Heights, steep-ground shading, elevation profiles | The terrain tiles for the area involved |
| [Environment Agency](https://environment.data.gov.uk/support/faqs/275811163/275811229) (Defra Data Services Platform) | 1 m LiDAR hill shading, crags, ground heights and route terrain checks in England | The 256 m grid squares for the area on screen, along a route being checked, or along a route's offline map |
| [Open-Meteo](https://open-meteo.com/en/terms) | Mountain forecast for a route | The position and height of the route's high point |
| [BRouter](https://brouter.de/) | Snapping a planned route to paths | The points you placed on the map |
| [Waymarked Trails](https://hiking.waymarkedtrails.org/) | Finding waymarked routes | The map area or the name you search for; the route you pick |
| [Overpass API](https://overpass-api.de/) (overpass-api.de) | Facilities along a route | The area along the route |
| A custom map source you add | Your own map layer | The map tiles for the area on screen |

When the map follows your position, the map tiles it asks for show roughly where you are. TrailMind does not
upload your GPS track or position history anywhere. Services may keep request logs for a limited time: for
example, Open-Meteo deletes its logs after 90 days and BRouter after two weeks.

## Trip groups (Bluetooth)

If you create or join a trip group, TrailMind shares your precise position, height, battery level, safety status
(for example after a fall alarm) and the name you choose with the other members of that group, directly between
phones over Bluetooth. It does this while TrailMind is open and while you record a hike, including with the screen
off. Members' phones may pass your position on to other members who are out of your range.

Everything is encrypted with a key made from the group's code, which only the people you give it to have. Nothing
is sent to us or to any server, and the broadcast carries no name, phone number or fixed identifier. Positions
from the group stay on your phone until the trip ends (after a day, unless you extend it) or you leave, and are
then deleted.

The broadcast also says whether you are recording a hike. By default, when you start one, the other members'
TrailMind starts recording its own copy (or asks them), and yours does the same when they start one; turn this off
under *Trip group → Group hikes*. Only the fact that you are recording is shared: each phone saves its own track,
which is never uploaded.

Anyone with the code can see the group while their phone is in Bluetooth range, so share it only with your
party; to remove someone, start a new group. If you send the code by text message, your mobile network could see
it. You can stop sharing your position at any time on the Safety page.

## Texts to your emergency contact

TrailMind can text your location (grid reference, a map link, the time and your battery level) to the emergency
contact you enter:

- when you send a check-in or SOS text yourself, from your messages app or with TrailMind's own Send button; or
- automatically, only if you turn on "Send it without asking me": when a possible fall is detected and you don't
  answer the fall alarm within its countdown. When you then tap "I'm OK", TrailMind texts the same person that
  you're fine.

These are ordinary SMS messages from your phone, carried by your mobile network and charged as normal texts. SMS
is not end-to-end encrypted. TrailMind never texts emergency numbers such as 999 by itself.

## Your watch

The Wear OS app talks to the phone app over a direct Bluetooth link between your own devices. Map tiles, your
position, hike statistics and alerts pass over that link. Nothing is sent to us.

## Other apps you choose

When you share or export a GPX file, share your location, copy a prompt for Google AI Edge Gallery, or open a
website such as Strava, the data goes to the app or site you pick, and its privacy policy applies.

## Android permissions

TrailMind asks for each permission when you first use the feature that needs it, and keeps working without the
ones you refuse.

- **Location (while using the app):** shows your position, records hikes and guides you along a route, and shares
  your position with your trip group if you are in one. While a hike is recording, or the watch link is on, a
  notification shows that TrailMind is using location.
- **Notifications, alarms & reminders, full-screen alerts:** check-in reminders, off-route alerts, the fall alarm,
  and alerts when someone in your trip group needs help.
- **Nearby devices (Bluetooth):** the link to your own paired watch, and trip groups.
- **SMS (send only):** only if you turn on automatic SOS texts. TrailMind cannot read your messages.
- **Motion sensors:** detecting a possible fall while you record a hike, on the phone only.

## Children

TrailMind is intended for adults and is not directed at children.

## Changes and contact

If this policy changes, we will update this page and its effective date. For questions or requests, contact
[contact email].
