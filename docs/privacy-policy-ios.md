<!--
Before publishing: replace [Developer name] and [contact email] below, then use this page's public web address (for
example its GitHub page; not a PDF) in App Store Connect > TrailMind > TestFlight > Test Information > Privacy Policy
URL (and, for a public release, App Information > Privacy Policy URL).
Keep it in step with privacy-policy.md (Android) and ios/TrailMind/Resources/PrivacyInfo.xcprivacy whenever the app's
network use changes.
-->

# TrailMind for iPhone: privacy policy

*Effective 1 November 2026*

TrailMind is a hiking app for iPhone, published by [Developer name] ("we"). This policy explains what TrailMind
does with your information. In short: TrailMind has no accounts, no ads, no analytics and no servers of our own.
Your routes, hikes and settings stay on your iPhone.

## What stays on your iPhone

TrailMind stores the following only on your iPhone:

- routes you plan or import, and hikes you record, including their GPS tracks and times
- offline map packs and cached map, terrain, weather and facility data
- your settings, including your emergency contact's name and number, and check-in and fall alarm settings
- your Ordnance Survey (OS), MapTiler and optional what3words API keys and any Strava credentials, kept in the
  iPhone Keychain for this iPhone only
- if you are in a trip group: its name, its code (sealed with a key in the Keychain), your name in the group, and
  the last positions heard from its members

We never receive this information. Routes, hikes, offline maps and downloaded data are kept out of iPhone backups.
Your settings are included in your iPhone's own backup, as every app's are; Apple (iCloud Backup) or your computer
keeps that backup under your account, and we never receive it. Keychain items are not restored to another iPhone.

Information is deleted when you delete it in the app (including selecting some or all saved routes or finished
hikes) or delete TrailMind. iOS can keep Keychain items after an app is deleted, so remove your keys in TrailMind's
Settings first if you want them gone. Deleting hikes does not delete exported files or copies already on Strava. A
trip group and everything heard from its members are deleted when you leave it or the trip ends.

## What TrailMind sends, and to whom

TrailMind contacts third-party services directly from your iPhone, over encrypted connections (HTTPS), only to
provide the feature you are using. Each request contains only what that service needs, as listed below. Like any
website, these services see your iPhone's IP address and the request, and handle them under their own privacy
policies. TrailMind sends them no name, account or device identifier, apart from your own OS key, which goes to
Ordnance Survey with your OS requests, your own MapTiler key, which goes to MapTiler with old-map requests, your
what3words key, which goes to what3words only when you request a conversion, and, only if you set up automatic
posting, your own Strava application's credentials and account link, which go to Strava.

| Service | Used for | What it receives |
|---|---|---|
| [Ordnance Survey](https://www.ordnancesurvey.co.uk/legal) (OS Maps API, OS Names API) | OS maps, place and postcode search, names for offline areas | The map tiles for the area on screen or being downloaded, what you type into search, or the area being named; your OS API key |
| [Apple](https://www.apple.com/legal/privacy/) (Apple Maps) | The Apple map drawn underneath the map you choose (so places without its tiles still show a map), except in offline-only mode, and place search when you have no OS key | The map area on screen, and what you type into search |
| [OpenStreetMap Foundation](https://osmfoundation.org/wiki/Privacy_Policy) tile servers | OpenStreetMap map | The map tiles for the area on screen |
| [what3words](https://what3words.com/privacy), optional | Convert three words to a position, or your current position to three words | The words you explicitly search for, or the precise GPS position when you tap Look up three words; your API key |
| [MapTiler](https://www.maptiler.com/privacy-policy/) (MapTiler Cloud, api.maptiler.com), serving the National Library of Scotland's old Ordnance Survey maps | Old maps faded over the map | The map tiles for the area on screen; your MapTiler key |
| [Strava](https://www.strava.com/legal/privacy) (www.strava.com), only if you set up automatic posting | Linking your Strava account and posting each finished hike to it | Your own Strava application's Client ID and secret and the sign-in code, then each hike: its name, track points with times and heights, the activity type and the note "Recorded with TrailMind". The secret and the tokens Strava returns are kept in the Keychain. Disconnecting tells Strava to forget TrailMind; hikes already posted stay on Strava until you delete them there |
| Mapzen Terrain Tiles on [Amazon Web Services](https://aws.amazon.com/privacy/) | Heights, steep-ground shading, elevation profiles | The terrain tiles for the area involved |
| [Environment Agency](https://environment.data.gov.uk/support/faqs/275811163/275811229) (Defra Data Services Platform) | 1 m LiDAR hill shading, crags, ground heights and route terrain checks in England | The 256 m grid squares for the area on screen, along a route being checked, or along a route's offline map |
| [Open-Meteo](https://open-meteo.com/en/terms) | Mountain forecast for a route | The position and height of the route's high point |
| [BRouter](https://brouter.de/) | Snapping a planned route to paths | The points you placed on the map |
| [Waymarked Trails](https://hiking.waymarkedtrails.org/) | Finding waymarked routes | The map area or the name you search for; the route you pick |
| [Overpass API](https://overpass-api.de/) (overpass-api.de) | Facilities along a route | The area along the route |
| A custom map source you add | Your own map layer | The map tiles for the area on screen |

When the map follows your position, the map tiles it asks for show roughly where you are. TrailMind does not
upload your GPS track or position history except when you explicitly share or export it or enable Strava posting.
what3words lookup is optional and online; there are no automatic conversions while recording or preparing an SOS
text. A current-position result is kept in memory, used in sharing only while the fix remains in the same square
and the lookup's fix is no more than one minute old, and is not saved. Services may keep request logs for a limited
time: for example, Open-Meteo deletes its logs after 90 days and BRouter after two weeks.

Beacon's briefing is worked out on your iPhone. Where your iPhone has Apple Intelligence and you leave it on, Apple's
on-device model writes the briefing up; that happens on the iPhone and nothing is sent.

## Testing with TestFlight

While you test TrailMind through Apple's TestFlight, Apple gives us the information TestFlight provides to
developers: the email address we invited, when you installed and opened builds, crash reports, and any feedback or
screenshots you choose to send. Apple's terms for [TestFlight](https://testflight.apple.com) apply.

## Trip groups

If you create or join a trip group, TrailMind shares your precise position, height, battery level, safety status
(for example after a fall alarm) and the name you choose with the other members of that group, directly between
phones: with other iPhones over Apple's peer-to-peer Wi-Fi and Bluetooth (Multipeer Connectivity), and by listening
for Android members' Bluetooth broadcasts. iPhones share only while TrailMind is open on screen. Members' phones
may pass your position on to other members who are out of your range.

Everything is encrypted with a key made from the group's code, which only the people you give it to have. Nothing
is sent to us or to any server, and what the iPhone advertises carries no name, phone number or fixed identifier:
only a random name for the session and a tag that changes every 15 minutes. Positions from the group stay on your
iPhone until the trip ends (after a day, unless you extend it) or you leave, and are then deleted.

The group also learns whether you are recording a hike. By default, when you start one, the other members'
TrailMind starts recording its own copy (or asks them), and yours does the same when they start one; turn this off
under *Trip group → Group hikes*. Only the fact that you are recording is shared: each phone saves its own track,
which is never uploaded.

Finding a member uses Nearby Interaction (ultra-wideband) between iPhones: the phones exchange short-lived tokens
over the group's link and measure distance and direction on the phones themselves.

Anyone with the code can see the group while their phone is in range, so share it only with your party; to remove
someone, start a new group. If you send the code by text message, your mobile network could see it.

## Texts to your emergency contact

TrailMind can prepare a text with your location (grid reference, coordinates or a map link, the time, battery level
and a recent what3words result if available) to the emergency contact you enter, for a check-in or an SOS, and
after a possible fall that you don't answer within the fall alarm's countdown. iPhone apps can't send texts by
themselves: TrailMind opens Messages with the text ready, and nothing is sent until you tap Send. These are ordinary
messages from your phone, carried by your mobile network (or by Apple as iMessage, if your contact uses it) and
charged as normal texts. TrailMind never contacts emergency numbers such as 999 by itself.

## Other apps you choose

When you share or export a GPX file, share your location, copy a prompt for Google AI Edge Gallery, or open a
website such as Strava, the data goes to the app or site you pick, and its privacy policy applies. Upload to Strava
on a hike's page saves that hike's GPX where you choose in Files and opens Strava's upload page in your browser;
TrailMind sends nothing itself, and the file stays there until you delete it.

## iPhone permissions

TrailMind asks for each permission when you first use the feature that needs it, and keeps working without the ones
you refuse.

- **Location:** shows your position, records hikes and guides you along a route, and shares your position with
  your trip group if you are in one. While a hike is recording with TrailMind in the background, iOS shows that
  TrailMind is using your location.
- **Notifications:** check-in reminders, off-route alerts, the fall alarm, offline-map renewal reminders, and alerts
  when someone in your trip group needs help.
- **Motion & Fitness:** the barometer for accurate climb and air pressure, and detecting a possible fall while you
  record a hike, on the iPhone only.
- **Bluetooth, Local Network and Nearby Interaction:** trip groups and finding a member.
- **Contacts:** none in general; choosing your emergency contact uses iOS's contact picker, which gives TrailMind
  only the contact you pick.

## Children

TrailMind is intended for adults and is not directed at children.

## Changes and contact

If this policy changes, we will update this page and its effective date. For questions or requests, contact
[contact email].
