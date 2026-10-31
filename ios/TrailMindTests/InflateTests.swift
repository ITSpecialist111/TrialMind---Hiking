import XCTest
@testable import TrailMind

/// The pure-Swift zlib inflater GeoTiff uses where Kotlin has `java.util.zip.Inflater` (Swift only, so no Kotlin twin).
/// The streams were made by Python's zlib from `words(4000)`.
final class InflateTests: XCTestCase {
    private let stored = "eAEBeACH/3NjcmVlc2NyZWUKc2NyZWUKY2Fpcm5taW5kcmlkZ2V0cmFpbG1pbmRyaWRnZXRhcm5zY3JlZQpjYWlybnNjcmVlc3VtbWl0cmlkZ2VtaW5kIG1pbmRjYWlybm1pbmQgbWluZCByaWRnZWNyYWdtaW5kY3JhZ3N1bUFzL8M="
    private let fixed = "eAErTi5KTS0GEVwQMjkxsygvNzMvpSgzJT21pCgxMwfBSyzKQ1IFZhaX5uZmloClQeoUQATcDDBPASyZXJSYDpYD0hA9YLMVYGJgRRAJCKkAsg1JFGwomM8FMRDOh8ijGg6WBZnABbYG7FQwC0yAZUGKwT4Ca4B4CaEYJAsJEgW4txEGcIE9BpKA+A4pQECCIFkko+ByKCGhAHMAJCBALLD7QQrhQa6gwAWTgGuG64NikGIQRooKSLjArSyGxzI8lGB+VEDSBfYP2DXw+ESEKFwIEoIwM+AGwZMKUvTBxRGGIkUPPI4U4HrBYcKlgBTDYALCh4QEiK+AiDd4qEAiWkEByQKE22BJCWIa3BdQxQqonkBKMmCViUgZAuJAWMij5gqII8FBAI92RC5CS0FI8YKU6JEEuJBSKjw/QazgUkCEB9wvcEch5S6EoQCLT5Cc"
    private let dynamic = "eNptV8uSIkEIvPMV/JrhTEwYsXrQ2f/fLajKB3qw7e56QZIk9Ov6/P5+rUv09Xq5PR/32+Prefv6+f59Xm5/+HR5PmRW3b7+3u+33xpe83JdsEc9ZQ1en5efGvv/32tq7zzvalIP9DXXafK2Nq3n6A3x3OO+eY2uHaKOKVPrri41uiaXR7WgXeLkNdqQJNzmBlGOrYH2TgBZL9eobIUxQyKPAQ3Euiv710RAnhlnAIuxbv/W5PWTUDQuOPKFKAOl42PKqvKnrEE8iSheNYJnD2wEqkj48J6bSngQo8TawiRSIlyXfm4k1nMybkClA50pB9C2Q6XeDV7syelOCGVq5kUSog08yHtWtJEFAcLOLBoMkrgI6eVFCFORT31EJPGALzBKsks2NcpHEjGaSV4YmTlhRKXB9MkJeyyxwYZ0SmD/DqtgdOa3b1iVJCSCth3e7hu7T/zKaZUgWBaWFoLfiapxxHJQQwbDYekQKaoZeIVZEqvGAT5EHHVaZ1IBiwy57Rvco1VDBZCR8g+2VvC2q4yIiImwqo6FRXAoKMRNrRhWAPR3MLabOdQbE4OCjoOBkqfhLAyuRAJi0t4t9CeAHYWBZh1eztVl5IEyKAhbmgblm0Rr7TnOwYw6hzwyQJhHFy1b0elNWFLqGvMEegvodsDINs+lcz756rBGU1L821sx/Z34dUaGq09hFEnQWPfew7/pf1J8s3IEf/OJha5RKmP78BhlxeQHQ+eUOHFOe81jyHHEZJTgsMphGg5aU0abbMn8pmyE8Exr63sxBmYfaveo/1KZcVC3cVLuXRoiSU+a3DKglM38JIyz/8BeIzslQgY4cnMWO8lpD8+WhRz1jgJ3GqoKOKU9intkABFgorJAcE9rC1l4vOb6pA+LpRdt+3dTFKc+wUeHjE4c/xEZgT4ZFTpzGpFDi1midg9FgERRe9bnlo99+CnRbLtgXGdnBmc3AlqNNDulD6FZmzS+BQnp6wKx1GSF1nmjgARz+oVo6Wzu3IJDMp1nxwyZ99Shd/BhYh3zY2kTxT/sphBAfaz/HVmkRHBIrbpQ01yK+IGV9sU3KNJeEJmAPPLG2j8uDTaLsxEO6H6OT4LR0w2/RVx9IPRbTEAEJq3gyQ7ci/EIvRf1f06XPWw="

    /// Words picked by a fixed pseudo-random sequence, as the Python that made the streams does.
    private func words(_ n: Int) -> [UInt8] {
        let words = ["trail", "mind", "ridge", "summit", "crag", "cairn", " ", "\n", "scree", "tarn"].map { Array($0.utf8) }
        var x: UInt64 = 12345
        var out: [UInt8] = []
        while out.count < n {
            x = (x * 1103515245 + 12345) & 0x7fffffff
            out += words[Int(x >> 16) % words.count]
        }
        return Array(out.prefix(n))
    }

    private func bytes(_ base64: String) throws -> [UInt8] { [UInt8](try XCTUnwrap(Data(base64Encoded: base64))) }

    private func inflate(_ stream: [UInt8], _ expected: Int) throws -> [UInt8] {
        try Inflate.zlib(stream, offset: 0, count: stream.count, expected: expected)
    }

    private func assertFails(_ stream: [UInt8], _ expected: Int, _ failure: Inflate.Failure, line: UInt = #line) {
        XCTAssertThrowsError(try inflate(stream, expected), line: line) { XCTAssertEqual($0 as? Inflate.Failure, failure, line: line) }
    }

    func testStoredFixedAndDynamicBlocksInflate() throws {
        let data = words(4000)
        XCTAssertEqual(Array(data.prefix(17)), Array("screescree\nscree\n".utf8))
        XCTAssertEqual(try inflate(try bytes(stored), 120), Array(data.prefix(120)))
        XCTAssertEqual(try inflate(try bytes(fixed), 1000), Array(data.prefix(1000)))
        XCTAssertEqual(try inflate(try bytes(dynamic), 4000), data)
        XCTAssertEqual(Inflate.adler32(data[...]), adler(data))
    }

    func testInflatesFromAnOffsetAndStopsOnceTheExpectedBytesAreOut() throws {
        let data = words(4000)
        var stream = try bytes(dynamic)
        XCTAssertEqual(try inflate(stream, 100), Array(data.prefix(100)))
        // The checksum after the last block is only read when every byte is wanted.
        stream[stream.count - 1] ^= 1
        XCTAssertEqual(try inflate(stream, 3999), Array(data.prefix(3999)))
        assertFails(stream, 4000, .corrupt("incorrect data check"))
        let padded = [0xAA, 0xBB] + (try bytes(fixed)) + [0xCC]
        XCTAssertEqual(try Inflate.zlib(padded, offset: 2, count: padded.count - 3, expected: 1000), Array(data.prefix(1000)))
    }

    func testShortWhenTheStreamOrItsInputEndsFirst() throws {
        let stream = try bytes(dynamic)
        assertFails(stream, 4001, .short)
        assertFails(Array(stream.prefix(stream.count - 30)), 4000, .short)
        assertFails(Array(stream.prefix(1)), 4000, .short)
        // A preset dictionary is never given.
        assertFails([0x78, 0xBB, 0, 0, 0, 1, 3, 0], 10, .short)
    }

    func testCorruptStreamsAreRefused() throws {
        var stream = try bytes(stored)
        stream[0] ^= 0x10
        assertFails(stream, 120, .corrupt("incorrect header check"))
        assertFails([0x78, 0x9C, 0x07, 0x00], 10, .corrupt("invalid block type"))
        assertFails([0x78, 0x9C, 0x01, 0x05, 0x00, 0x00, 0x00, 0x41], 10, .corrupt("invalid stored block lengths"))
        // A fixed block opening with a match three bytes long from one byte back.
        assertFails([0x78, 0x9C, 0x03, 0x02], 10, .corrupt("invalid distance too far back"))
    }

    /// Adler-32 the slow way, to check the fast one.
    private func adler(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}
