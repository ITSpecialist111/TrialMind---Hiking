import Foundation

#if DEBUG
/// Developer launches set up a check without touching the phone (iPhone Duo poses, screenshots), for example
/// `pymobiledevice3 developer core-device launch-application --env TM_TAB=routes --env TM_BASE=osm <bundle id>`:
/// TM_BASE=<map source id>, TM_OFFLINE_ONLY=0|1, TM_CENTER=lat,lon[,zoom], TM_HEADING_UP=0|1, TM_ONBOARDED=1,
/// TM_TAB=<tab>, TM_PAGE=display, TM_LOCATE=1. Debug builds only.
enum TestLaunch {
    static func apply() {
        let env = ProcessInfo.processInfo.environment
        let prefs = Prefs.shared
        if let base = env["TM_BASE"], TileSources.builtIns().contains(where: { $0.id == base }) { prefs.baseSourceId = base }
        if let offline = env["TM_OFFLINE_ONLY"] { prefs.offlineOnly = offline == "1" }
        if let up = env["TM_HEADING_UP"] { prefs.mapHeadingUp = up == "1" }
        if let center = env["TM_CENTER"] {
            let parts = center.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 2 {
                prefs.mapLat = parts[0]
                prefs.mapLon = parts[1]
                if parts.count >= 3 { prefs.mapZoom = parts[2] }
            }
        }
        if env["TM_ONBOARDED"] == "1" { prefs.onboardingAccepted = true }
        DispatchQueue.main.async {
            if let tab = env["TM_TAB"], let t = Tab(rawValue: tab) { Navigator.shared.open(t) }
            if env["TM_PAGE"] == "display" { Navigator.shared.push(PageRoute("display") { DisplayDiagnosticsPage() }) }
        }
        // TM_LOCATE=1: "Show my position" once the map is up (checks centring in the uncovered map area).
        if env["TM_LOCATE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MapController.shared.locate() }
        }
    }
}
#endif
