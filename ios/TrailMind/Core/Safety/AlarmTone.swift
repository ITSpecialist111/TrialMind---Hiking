import Foundation

/// The fall alarm's sound, made on the phone rather than shipped as a file: a one-second loop of four short beeps that
/// alternate between two high tones (the pattern of a personal alarm), as a 16-bit mono PCM WAV.
enum AlarmTone {
    static let sampleRate = 22_050
    /// The two pitches, hertz.
    static let highHz = 1_046.5
    static let lowHz = 784.0
    /// Each beep and the gap after it, seconds; four beeps fill the second.
    static let beepS = 0.18
    static let periodS = 0.25
    /// Fade in and out of each beep, seconds, so the speaker doesn't click.
    static let fadeS = 0.006
    static let peak = 0.85

    /// The sample at `index` of the one-second loop, -1...1.
    static func sample(_ index: Int) -> Double {
        let t = Double(index) / Double(sampleRate)
        let beep = Int(t / periodS)
        let inBeep = t - Double(beep) * periodS
        if inBeep >= beepS { return 0 }
        let hz = beep % 2 == 0 ? highHz : lowHz
        let envelope = min(1.0, inBeep / fadeS, (beepS - inBeep) / fadeS)
        let x = 2 * Double.pi * hz * t
        // A touch of the third harmonic carries further than a pure tone through a pocket.
        return peak * envelope * (0.8 * sin(x) + 0.2 * sin(3 * x))
    }

    /// The loop as a complete WAV file, `seconds` long (the pattern repeats each second).
    static func wav(seconds: Int = 1) -> [UInt8] {
        let count = sampleRate * max(seconds, 1)
        var out: [UInt8] = []
        out.reserveCapacity(44 + count * 2)
        func text(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        text("RIFF")
        u32(36 + count * 2)
        text("WAVE")
        text("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        text("data")
        u32(count * 2)
        let second = (0..<sampleRate).map { i -> Int16 in
            Int16((sample(i) * Double(Int16.max)).rounded().clamped(Double(Int16.min), Double(Int16.max)))
        }
        for i in 0..<count {
            withUnsafeBytes(of: second[i % sampleRate].littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }
}
