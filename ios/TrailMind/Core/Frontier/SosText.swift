import Foundation

/// SOS texts that fit one plain SMS, the service O2 Satellite carries everywhere it reaches.
///
/// Lengths and cuts count UTF-16 code units, as Kotlin's `String.length` and `take` do, so the texts match Android's.
enum SosText {
    static let maxChars = 160

    /// For a contact: what happened, where (grid, map link or coordinates), height and battery.
    static func contact(
        _ situation: String, location: LatLon?, altitudeM: Int?, time: String, batteryPercent: Int, words: String? = nil
    ) -> String {
        let what = trimEnd(gsm(situation), ".", " ")
        let prefix = "SOS from TrailMind: "
        let suffix = " at " + gsm(time) + "."
        let grid = location.flatMap { OsGrid.fromWgs84($0)?.format(8) }.map { " Grid " + $0 + "." } ?? ""
        let coords = location.map { " " + fmt("%.5f,%.5f", $0.lat, $0.lon) + "." } ?? " No GPS fix."
        let link = location.map { " " + fmt("https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f", $0.lat, $0.lon) }
        let tail = (altitudeM.map { " \($0) m." } ?? "") + ((0...100).contains(batteryPercent) ? " Battery \(batteryPercent)%." : "")
        let head = prefix + what + suffix
        let threeWords = words.flatMap(normalizeThreeWords).flatMap { location != nil && isGsm7($0) ? " ///" + $0 + "." : nil }
        if let threeWords {
            let room = maxChars - length(prefix) - length(suffix) - length(grid) - length(coords) - length(tail) - length(threeWords)
            if room >= 12 { return prefix + trimEnd(take(what, room), ",", " ") + suffix + grid + coords + threeWords + tail }
        }
        if let link {
            let text = head + grid + link + tail
            if length(text) <= maxChars { return text }
        }
        let room = maxChars - length(prefix) - length(suffix) - length(grid) - length(coords) - length(tail)
        return prefix + trimEnd(take(what, max(room, 0)), ",", " ") + suffix + grid + coords + tail
    }

    /// For 999 by emergencySMS: the service to send, then what and where. The user reads it before sending.
    static func emergency(_ situation: String, location: LatLon?, time: String, words: String? = nil) -> String {
        let place = location.map { l in
            (OsGrid.fromWgs84(l)?.format(10).map { "Grid " + $0 + ", " } ?? "") + fmt("lat %.5f lon %.5f", l.lat, l.lon)
        } ?? "location unknown"
        let threeWords = words.flatMap(normalizeThreeWords).flatMap { location != nil ? " what3words ///" + $0 + "." : nil } ?? ""
        return "Police, mountain rescue. " + trimEnd(FrontierCompat.trim(gsm(situation)), ".") + ". " + place + "." + threeWords +
            " Time " + gsm(time) + "."
    }

    /// True if `text` uses only the basic GSM-7 alphabet, so it is sent as one 160-character SMS.
    static func isGsm7(_ text: String) -> Bool { text.utf16.allSatisfy { gsm7.contains($0) } }

    /// 999 and other emergency-service numbers: TrailMind never texts these by itself, only the user does.
    static func isEmergencyNumber(_ number: String) -> Bool {
        // Any script's digits (fullwidth, Arabic-Indic...) count as the ASCII digit the phone would dial.
        let digits = number.utf16.compactMap(decimalDigit).map(String.init).joined()
        return emergencyNumbers.contains(digits) ||
            (digits.count <= 6 && emergencyNumbers.contains { digits.hasSuffix($0) })
    }

    private static let emergencyNumbers: Set<String> = ["999", "112", "911", "000", "110", "119"]

    private static func gsm(_ text: String) -> String {
        var units: [UInt16] = []
        for unit in text.utf16 {
            let kept: UInt16 = gsm7.contains(unit) && unit != 0x0A && unit != 0x0D ? unit : 0x20
            // " {2,}" becomes " ".
            if kept == 0x20 && units.last == 0x20 { continue }
            units.append(kept)
        }
        return FrontierCompat.trim(String(decoding: units, as: UTF16.self))
    }

    private static let gsm7 = Set(
        ("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?" +
            "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà").utf16
    )

    /// Java's `Character.digit(c, 10)` for one UTF-16 unit: the value of a decimal digit in any script, else nil.
    private static func decimalDigit(_ unit: UInt16) -> Int? {
        guard let scalar = Unicode.Scalar(unit), scalar.properties.generalCategory == .decimalNumber,
              let value = scalar.properties.numericValue else { return nil }
        return Int(value)
    }

    /// `ThreeWordAddress.normalize` (geo/ThreeWordAddress.kt), kept private here until that file is ported.
    private static func normalizeThreeWords(_ input: String) -> String? {
        var units = Array(FrontierCompat.trim(input).utf16)
        if units.starts(with: "///".utf16) { units.removeFirst(3) }
        let value = String(decoding: units, as: UTF16.self).lowercased()
        guard length(value) <= 100 else { return nil }
        return threeWords.firstMatch(in: value, options: [], range: NSRange(value.startIndex..., in: value)) != nil ? value : nil
    }

    private static let threeWords = try! NSRegularExpression(
        pattern: "\\A[\\p{L}]+(?:[-'][\\p{L}]+)*\\.[\\p{L}]+(?:[-'][\\p{L}]+)*\\.[\\p{L}]+(?:[-'][\\p{L}]+)*\\z"
    )

    private static func length(_ text: String) -> Int { FrontierCompat.length(text) }

    /// Kotlin's `take(n)`: the first `n` UTF-16 units. Only used on GSM-7 text, which has no surrogate pairs.
    private static func take(_ text: String, _ n: Int) -> String { String(decoding: Array(text.utf16.prefix(n)), as: UTF16.self) }

    /// Kotlin's `trimEnd(vararg chars)`.
    private static func trimEnd(_ text: String, _ chars: Character...) -> String {
        let drop = Set(chars.flatMap { $0.utf16 })
        var units = Array(text.utf16)
        while let last = units.last, drop.contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}
