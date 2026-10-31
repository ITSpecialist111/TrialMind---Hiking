import Foundation

// The trip group's wording and small rules from the Android app layer (ui/GroupPage.kt, GroupSharing.kt,
// GroupFinder.kt, GroupFindPage.kt), kept Foundation-only so iPhone and Android say the same things, tested on Linux.

/// Member colours (GroupSharing.COLOURS); red is kept for calls for help.
enum GroupColours {
    static let all: [UInt32] = [
        0xFF00_897B, 0xFFEF_6C00, 0xFF7B_1FA2, 0xFF38_8E3C,
        0xFF39_49AB, 0xFFC2_185B, 0xFF6D_4C41, 0xFF82_7717,
    ]

    /// `COLOURS[Math.floorMod(colour ?: memberId, COLOURS.size)]`: the colour a member picked, or one from their id.
    static func of(colour: Int?, memberId: Int) -> UInt32 { all[kMod(colour ?? memberId, all.count)] }
}

/// How long a trip group lasts (GroupSharing.TRIP_MS and MAX_TRIP_MS).
enum TripTimes {
    static let tripMs: Int64 = 24 * 3_600_000
    static let maxTripMs: Int64 = 7 * 24 * 3_600_000

    /// "Add a day": another day on the trip, up to a week from now.
    static func extended(expiresMs: Int64, nowMs: Int64) -> Int64 { min(max(expiresMs, nowMs) + tripMs, nowMs + maxTripMs) }
}

enum GroupText {
    /// "45 s", "12 min", "3 h 5 min".
    static func age(_ seconds: Int64) -> String {
        let s = max(seconds, 0)
        if s < 90 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        return "\(s / 3_600) h \((s % 3_600) / 60) min"
    }

    /// "just now" under a minute, then "12 min ago": coarse, so pages needn't redraw every second.
    static func ago(_ seconds: Int64) -> String { seconds < 60 ? "just now" : "\(age(seconds)) ago" }

    /// Up to two letters for a map marker: "Sam Jones" is "SJ".
    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" || $0 == "_" }.map(String.init).filter { !FrontierCompat.isBlank($0) }
        let text = words.prefix(2).map { word in word.unicodeScalars.first.map { String($0) } ?? "" }.joined().uppercased()
        return FrontierCompat.isBlank(text) ? "?" : text
    }

    /// What a member's call for help says on the page (GroupPage.helpText).
    static func help(_ status: EmergencyStatus) -> String {
        switch status {
        case .fallDetected: return "May have fallen"
        case .criticalSos: return "Needs help"
        case .injuredStationary: return "Hurt and can't move"
        case .injuredMoving: return "Hurt but moving"
        default: return ""
        }
    }

    /// The help alert's verb (GroupSharing.alertHelp): "Sam may have fallen".
    static func alertWhat(_ status: EmergencyStatus) -> String {
        switch status {
        case .fallDetected: return "may have fallen"
        case .criticalSos: return "needs help"
        default: return "is hurt"
        }
    }

    /// A member's name, or "Hiker 3F2A" from their id until their name arrives (GroupSharing.nameOf).
    static func name(_ name: String?, memberId: Int) -> String {
        if let name, !FrontierCompat.isBlank(name) { return name }
        return "Hiker " + String(memberId & 0xFFFF, radix: 16, uppercase: true).padStart(4, "0")
    }

    /// `"%08x".format(memberId)`: the 32-bit member id in hex, as the reception log and mesh heartbeats write it.
    static func memberHex(_ memberId: Int) -> String {
        let v = UInt32(truncatingIfNeeded: memberId)
        return FrontierCompat.hex([
            UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v),
        ])
    }

    /// UWB distance: "3.4 m" close in, "27 m" further; feet for imperial (GroupFinder.uwbDistance).
    static func uwbDistance(_ m: Double, imperial: Bool) -> String {
        if imperial {
            let ft = m * 3.28084
            return ft < 10 ? fmt("%.1f ft", ft) : "\(kRoundL(ft)) ft"
        }
        return m < 10 ? fmt("%.1f m", m) : "\(kRoundL(m)) m"
    }

    /// The member details dialog (showGroupMember). `link` names how a member in range is heard when that isn't a
    /// Bluetooth signal strength (an iPhone's direct link).
    static func memberDetails(
        _ peer: PeerTable.Peer, nowS: Int64, nowMs: Int64, here: LatLon?, imperial: Bool, inRange: Bool, link: String? = nil
    ) -> [String] {
        var lines: [String] = []
        if let pos = peer.position {
            if pos.status.needsHelp { lines.append("⚠ " + help(pos.status)) }
            lines.append("Position \(age(nowS - pos.originTimeS)) old, " +
                (pos.hops == 0 ? "straight from their phone" : "passed on by \(pos.hops) phone\(pos.hops > 1 ? "s" : "")"))
            let there = LatLon(pos.lat, pos.lon)
            if let here {
                let b = Geo.bearingDeg(here, there)
                lines.append("\(Units.distance(Geo.distanceM(here, there), imperial: imperial)) at \(Units.bearing(b)) \(Geo.cardinal(b)) from you (straight line)")
            }
            if let grid = OsGrid.fromWgs84(there)?.format(8) { lines.append("Grid ref " + grid) }
            if let altitude = pos.altitudeM { lines.append("Height about " + Units.elevation(Double(altitude), imperial: imperial)) }
            lines.append("Accuracy ±\(pos.accuracyM) m · battery \(pos.batteryPercent)%")
            if pos.flags & GroupFrames.flagPaused != 0 {
                lines.append("Hike paused")
            } else if pos.flags & GroupFrames.flagRecording != 0 {
                lines.append(pos.flags & GroupFrames.flagGroupHike != 0 ? "Recording a group hike" : "Recording a hike")
            }
        } else {
            lines.append("No position from them yet.")
        }
        if inRange {
            let via = link.map { " · " + $0 } ?? (peer.rssi.map { " · \($0) dBm" } ?? "")
            lines.append("In range now" + via + (peer.coded ? " · long range" : ""))
        } else if peer.lastDirectMs > 0 {
            lines.append("Last heard directly \(age((nowMs - peer.lastDirectMs) / 1_000)) ago")
        } else {
            lines.append("Only heard through other phones")
        }
        return lines
    }

    /// A member's line on the Trip group page (GroupPage.subtitle).
    static func subtitle(_ peer: PeerTable.Peer, nowS: Int64, here: LatLon?, imperial: Bool, inRange: Bool) -> String {
        var parts: [String] = []
        let pos = peer.position
        if let pos, pos.status.needsHelp { parts.append(help(pos.status)) }
        if let pos {
            parts.append(ago(nowS - pos.originTimeS))
            if let here {
                let there = LatLon(pos.lat, pos.lon)
                parts.append("\(Units.distance(Geo.distanceM(here, there), imperial: imperial)) \(Geo.cardinal(Geo.bearingDeg(here, there)))")
            }
            parts.append("\(pos.batteryPercent)%")
        } else {
            parts.append("no position yet")
        }
        if inRange {
            parts.append(peer.coded ? "in range (long range)" : "in range")
        } else if let pos, pos.hops > 0 {
            parts.append("passed on")
        } else {
            parts.append("out of range")
        }
        return parts.joined(separator: " · ")
    }

    /// Your own line on the Trip group page (GroupPage.ownSubtitle). `paused`: the radio is off right now.
    static func ownSubtitle(_ own: PositionFrame?, nowS: Int64, paused: Bool) -> String {
        guard let own else { return "Waiting for a GPS fix" }
        var parts = ["Shared " + ago(nowS - own.originTimeS)]
        if own.status.needsHelp { parts.append(help(own.status)) }
        if paused { parts.append("sharing paused until TrailMind is open or a hike records") }
        return parts.joined(separator: " · ")
    }

    /// A call for help from `name` (GroupSharing.alertHelp): the title, then where they are and how old that is.
    static func helpAlert(name: String, frame: PositionFrame, here: LatLon?, imperial: Bool, time: String) -> (title: String, text: String) {
        let there = LatLon(frame.lat, frame.lon)
        let place = here.map { h -> String in
            let b = Geo.bearingDeg(h, there)
            return "\(Units.distance(Geo.distanceM(h, there), imperial: imperial)) \(Geo.cardinal(b)) of you"
        }
        let text = [place, "position from " + time, frame.hops > 0 ? "passed on by the group" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return ("\(name) \(alertWhat(frame.status))", text)
    }

    /// Which way to turn, under the distance (GroupFindPage.bind). `measured`: there is a measurement at all.
    static func direction(azimuthDeg: Double?, elevationDeg: Double?, measured: Bool, fresh: Bool) -> String {
        let main: String
        if !measured || !fresh {
            main = ""
        } else if let azimuth = azimuthDeg {
            if abs(azimuth) <= 10 {
                main = "Straight ahead"
            } else if azimuth > 0 {
                main = "\(kRound(azimuth))° to your right"
            } else {
                main = "\(kRound(-azimuth))° to your left"
            }
        } else {
            main = "Hold the phone upright in front of you to see which way."
        }
        var tail = ""
        if measured, fresh, let elevation = elevationDeg, abs(elevation) >= 20 { tail = elevation > 0 ? " · above you" : " · below you" }
        return main + tail
    }

    /// Why the other phone wouldn't be found (GroupFinder.declined).
    static func declined(_ reason: Int) -> String {
        switch reason {
        case RangeFrame.reasonNotAllowed: return "They've turned off being found with UWB."
        case RangeFrame.reasonUwbOff: return "UWB is off on their phone (or it's in flight mode)."
        case RangeFrame.reasonBusy: return "Their phone is already ranging with someone else. Try again in a minute."
        case RangeFrame.reasonUnsupported: return "Their phone can't use the UWB settings this one asked for."
        default: return "Their phone couldn't start UWB."
        }
    }

    /// The found phone's notice while `name` finds it with UWB (GroupFinder.notification on Android). It goes up once
    /// per find, so it doesn't carry the distance; the find page does.
    static func beingFound(_ name: String) -> (title: String, text: String) {
        ("\(name) is finding you with UWB", "Tap to see how far away they are. Keep TrailMind open on screen until they reach you.")
    }
}

/// `trailmind://group/join?code=…&name=…` invites (GroupPage.inviteLink and inviteText, joinGroupFromLink).
enum GroupInvite {
    static let scheme = "trailmind"
    static let host = "group"
    /// Longest trip name taken from a link (`take(40)`).
    static let maxNameLength = 40

    struct Parsed: Equatable {
        /// Nil when the invite is incomplete or its code is mistyped.
        var code: GroupCode?
        var name: String?
    }

    static func link(name: String, code: GroupCode) -> String {
        "\(scheme)://\(host)/join?code=\(encode(code.text))&name=\(encode(name))"
    }

    static func text(name: String, code: GroupCode) -> String {
        "Join my TrailMind trip group \"\(name)\".\n\nCode: \(code.formatted)\n\n" +
            "In TrailMind: Safety > Trip group > Join with code, or open \(link(name: name, code: code))\n\n" +
            "Our phones then show each other on the map over Bluetooth, with no signal needed."
    }

    /// Nil when `link` isn't a trip-group invite at all.
    static func parse(_ link: String) -> Parsed? {
        guard let parts = URLComponents(string: link), parts.scheme?.lowercased() == scheme, parts.host == host else { return nil }
        let query = parts.percentEncodedQuery ?? ""
        func value(_ key: String) -> String? {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if decode(String(kv[0])) == key { return kv.count > 1 ? decode(String(kv[1])) : "" }
            }
            return nil
        }
        let code = value("code").flatMap(GroupCode.parse)
        let name = value("name").map { cut(FrontierCompat.trim($0), maxNameLength) }.flatMap { FrontierCompat.isBlank($0) ? nil : $0 }
        return Parsed(code: code, name: name)
    }

    /// Android's `Uri.encode`: UTF-8, leaving only letters, digits and `_-!.~'()*` as they are.
    static func encode(_ s: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-!.~'()*".utf8)
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for b in s.utf8 {
            if unreserved.contains(b) {
                out.append(b)
            } else {
                out += [UInt8(ascii: "%"), hex[Int(b >> 4)], hex[Int(b & 0xF)]]
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Android's `getQueryParameter` decoding: '+' is a space, then percent escapes.
    private static func decode(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// The longest start of `s` within `max` UTF-16 units (Kotlin's `take`), never splitting a character.
    private static func cut(_ s: String, _ max: Int) -> String {
        var out = ""
        var units = 0
        for c in s {
            units += c.utf16.count
            if units > max { break }
            out.append(c)
        }
        return out
    }
}

/// The reception log for range tests (GroupSharing.record and logCsv): one line per frame heard.
enum GroupLog {
    static let header = "time,member,frame,sequence,hops,ttl,result,rssi_dbm,phy,tx_power_dbm,lat,lon,distance_m,own_lat,own_lon"
    static let maxLines = 5_000

    /// `rssi` is nil, and `phy` "iphone", for frames that came over an iPhone's direct link rather than Bluetooth.
    static func line(
        _ frame: any GroupFrame, outcome: PeerTable.Result, rssi: Int?, phy: String, txPower: Int?, nowMs: Int64, own: LatLon?
    ) -> String {
        let p = frame as? PositionFrame
        let kind: String
        switch frame {
        case is PositionFrame: kind = "position"
        case is ProfileFrame: kind = "profile"
        default: kind = "range"
        }
        var distance = ""
        if let p, let own { distance = String(Int(Geo.distanceM(own.lat, own.lon, p.lat, p.lon))) }
        let fields: [String] = [
            String(nowMs), GroupText.memberHex(frame.memberId), kind, p.map { String($0.sequence) } ?? "",
            String(frame.hops), String(frame.ttl), outcomeName(outcome), rssi.map(String.init) ?? "", phy,
            txPower.map(String.init) ?? "", p.map { "\($0.lat)" } ?? "", p.map { "\($0.lon)" } ?? "", distance,
            own.map { "\($0.lat)" } ?? "", own.map { "\($0.lon)" } ?? "",
        ]
        return fields.joined(separator: ",")
    }

    static func outcomeName(_ outcome: PeerTable.Result) -> String {
        switch outcome {
        case .new: return "new"
        case .newer: return "newer"
        case .same: return "same"
        case .older: return "older"
        case .rejected: return "rejected"
        }
    }

    static func csv(_ lines: [String]) -> String { ([header] + lines).map { $0 + "\n" }.joined() }
}
