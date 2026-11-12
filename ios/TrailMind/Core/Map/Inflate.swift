import Foundation

/// zlib-wrapped Deflate (RFC 1950 and 1951) in pure Swift, in place of the `java.util.zip.Inflater` GeoTiff.kt uses:
/// zlib cannot be imported from Swift on Linux. Like Inflater there it stops as soon as the expected bytes are out, and
/// otherwise reports what zlib's inflate would: bad data as corrupt, a stream or input that ends early as short.
enum Inflate {
    enum Failure: Error, Equatable {
        /// Not valid zlib data (Inflater's `DataFormatException`), with zlib's message.
        case corrupt(String)
        /// The stream finished, or its input ran out, before the expected bytes came out.
        case short
    }

    /// The first `expected` bytes the zlib stream in `input[offset ..< offset + count]` inflates to.
    static func zlib(_ input: [UInt8], offset: Int, count: Int, expected: Int) throws -> [UInt8] {
        precondition(offset >= 0 && count >= 0 && offset <= input.count - count, "input range outside the array")
        if expected <= 0 { return [] }
        var inflater = Inflater(input: input, pos: offset, end: offset + count, expected: expected)
        do {
            try inflater.run()
        } catch Stop.outputFull {
            return inflater.out
        } catch Stop.needInput {
            // Inflater would wait for more input: what came out is all there is.
        } catch Stop.needDictionary {
            // A preset dictionary is never supplied.
        }
        if inflater.done < expected { throw Failure.short }
        return inflater.out
    }

    /// Adler-32 of `data`, the checksum that ends a zlib stream.
    static func adler32(_ data: ArraySlice<UInt8>) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var i = data.startIndex
        while i < data.endIndex {
            // 5552 bytes is the most that cannot overflow 32 bits before the modulo (zlib's NMAX).
            let end = min(i + 5552, data.endIndex)
            while i < end {
                a &+= UInt32(data[i])
                b &+= a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    private enum Stop: Error {
        /// A byte has to be written and all the expected ones are out.
        case outputFull
        case needInput
        case needDictionary
    }

    /// A canonical Huffman code as a table indexed by the next `bits` input bits, first bit lowest. Each entry is
    /// symbol << 8 | code length; symbol -1 is zlib's invalid-code marker, which only an incomplete code leaves.
    private struct Huffman {
        let table: [Int32]
        let bits: Int

        static let invalid: Int32 = -1 << 8 | 1

        /// The code for `lengths`, or nil where zlib's inflate_table refuses it: over-subscribed, or incomplete unless it
        /// is a single one-bit code (never for the code-length code). No codes at all gives a table that is all invalid.
        static func build<C: Collection>(_ lengths: C, codeLengthCode: Bool) -> Huffman? where C.Element == Int {
            var count = [Int](repeating: 0, count: 16)
            for length in lengths { count[length] += 1 }
            var max = 15
            while max >= 1 && count[max] == 0 { max -= 1 }
            if max == 0 { return Huffman(table: [invalid, invalid], bits: 1) }
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= count[length]
                if left < 0 { return nil }
            }
            if left > 0 && (codeLengthCode || max != 1) { return nil }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            count[0] = 0
            for length in 1...15 {
                code = (code + count[length - 1]) << 1
                next[length] = code
            }
            var table = [Int32](repeating: invalid, count: 1 << max)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let c = next[length]
                next[length] += 1
                var reversed = 0
                for i in 0..<length { reversed |= (c >> i & 1) << (length - 1 - i) }
                let entry = Int32(symbol << 8 | length)
                var i = reversed
                while i < table.count {
                    table[i] = entry
                    i += 1 << length
                }
            }
            return Huffman(table: table, bits: max)
        }
    }

    private static let fixedLiterals: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return Huffman.build(lengths, codeLengthCode: false)!
    }()
    private static let fixedDistances = Huffman.build([Int](repeating: 5, count: 32), codeLengthCode: false)!

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// The order code-length code lengths are stored in.
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private struct Inflater {
        let input: [UInt8]
        var pos: Int
        let end: Int
        let expected: Int
        var out: [UInt8]
        var done = 0
        /// Input bits not yet used, first bit lowest.
        var hold: UInt64 = 0
        var bitCount = 0

        init(input: [UInt8], pos: Int, end: Int, expected: Int) {
            self.input = input
            self.pos = pos
            self.end = end
            self.expected = expected
            out = [UInt8](repeating: 0, count: expected)
        }

        mutating func run() throws {
            let cmf = try bits(8)
            let flg = try bits(8)
            if ((cmf << 8) + flg) % 31 != 0 { throw Failure.corrupt("incorrect header check") }
            if cmf & 0x0F != 8 { throw Failure.corrupt("unknown compression method") }
            if (cmf >> 4) + 8 > 15 { throw Failure.corrupt("invalid window size") }
            if flg & 0x20 != 0 { throw Stop.needDictionary }
            var last = false
            while !last {
                last = try bits(1) == 1
                switch try bits(2) {
                case 0:
                    try stored()
                case 1:
                    try codes(Inflate.fixedLiterals, Inflate.fixedDistances)
                case 2:
                    let (literals, distances) = try dynamicTables()
                    try codes(literals, distances)
                default:
                    throw Failure.corrupt("invalid block type")
                }
            }
            alignToByte()
            var check: UInt32 = 0
            for _ in 0..<4 {
                let byte = try bits(8)
                check = check << 8 | UInt32(byte)
            }
            if check != Inflate.adler32(out[0..<done]) { throw Failure.corrupt("incorrect data check") }
        }

        private mutating func refill() {
            while bitCount <= 56 && pos < end {
                hold |= UInt64(input[pos]) << UInt64(bitCount)
                pos += 1
                bitCount += 8
            }
        }

        private mutating func bits(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            if bitCount < n {
                refill()
                if bitCount < n { throw Stop.needInput }
            }
            let value = Int(hold & (UInt64(1) << UInt64(n) - 1))
            hold >>= UInt64(n)
            bitCount -= n
            return value
        }

        private mutating func alignToByte() {
            let drop = bitCount & 7
            hold >>= UInt64(drop)
            bitCount -= drop
        }

        /// The next symbol in `code`, or -1 for an invalid code.
        private mutating func decode(_ code: Huffman) throws -> Int {
            if bitCount < code.bits { refill() }
            let entry = code.table[Int(hold & (UInt64(1) << UInt64(code.bits) - 1))]
            let length = Int(entry & 0xFF)
            if length > bitCount { throw Stop.needInput }
            hold >>= UInt64(length)
            bitCount -= length
            return Int(entry >> 8)
        }

        private mutating func put(_ byte: UInt8) throws {
            if done == expected { throw Stop.outputFull }
            out[done] = byte
            done += 1
        }

        private mutating func stored() throws {
            alignToByte()
            let length = try bits(16)
            let complement = try bits(16)
            if length != ~complement & 0xFFFF { throw Failure.corrupt("invalid stored block lengths") }
            var left = length
            while left > 0 {
                if done == expected { throw Stop.outputFull }
                if bitCount >= 8 {
                    let byte = try bits(8)
                    try put(UInt8(byte))
                    left -= 1
                    continue
                }
                if pos == end { throw Stop.needInput }
                let n = min(left, end - pos, expected - done)
                out.replaceSubrange(done..<done + n, with: input[pos..<pos + n])
                done += n
                pos += n
                left -= n
            }
        }

        private mutating func codes(_ literals: Huffman, _ distances: Huffman) throws {
            while true {
                let symbol = try decode(literals)
                if symbol == 256 { return }
                if symbol < 0 || symbol > 285 { throw Failure.corrupt("invalid literal/length code") }
                if symbol < 256 {
                    try put(UInt8(symbol))
                    continue
                }
                let index = symbol - 257
                let extraLength = try bits(Inflate.lengthExtra[index])
                let length = Inflate.lengthBase[index] + extraLength
                let code = try decode(distances)
                if code < 0 || code > 29 { throw Failure.corrupt("invalid distance code") }
                let extraDistance = try bits(Inflate.distanceExtra[code])
                let distance = Inflate.distanceBase[code] + extraDistance
                // zlib stops at a full output before it checks how far back the match reaches.
                if done == expected { throw Stop.outputFull }
                if distance > done { throw Failure.corrupt("invalid distance too far back") }
                var from = done - distance
                for _ in 0..<length {
                    let byte = out[from]
                    try put(byte)
                    from += 1
                }
            }
        }

        private mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let lengthCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeLengthCount = try bits(4) + 4
            if lengthCount > 286 || distanceCount > 30 { throw Failure.corrupt("too many length or distance symbols") }
            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<codeLengthCount { codeLengths[Inflate.codeLengthOrder[i]] = try bits(3) }
            guard let codeLengthCode = Huffman.build(codeLengths, codeLengthCode: true) else {
                throw Failure.corrupt("invalid code lengths set")
            }
            let total = lengthCount + distanceCount
            var lengths = [Int](repeating: 0, count: total)
            var have = 0
            while have < total {
                // zlib takes its invalid marker's value, 0, here rather than failing.
                let symbol = max(try decode(codeLengthCode), 0)
                if symbol < 16 {
                    lengths[have] = symbol
                    have += 1
                    continue
                }
                var length = 0
                let copy: Int
                if symbol == 16 {
                    let repeats = try bits(2)
                    if have == 0 { throw Failure.corrupt("invalid bit length repeat") }
                    length = lengths[have - 1]
                    copy = 3 + repeats
                } else if symbol == 17 {
                    copy = try bits(3) + 3
                } else {
                    copy = try bits(7) + 11
                }
                if have + copy > total { throw Failure.corrupt("invalid bit length repeat") }
                for _ in 0..<copy {
                    lengths[have] = length
                    have += 1
                }
            }
            if lengths[256] == 0 { throw Failure.corrupt("invalid code -- missing end-of-block") }
            guard let literals = Huffman.build(lengths[0..<lengthCount], codeLengthCode: false) else {
                throw Failure.corrupt("invalid literal/lengths set")
            }
            guard let distances = Huffman.build(lengths[lengthCount...], codeLengthCode: false) else {
                throw Failure.corrupt("invalid distances set")
            }
            return (literals, distances)
        }
    }
}
