import Foundation

/// GeoTiff.kt's `IOException`: the bytes are not a GeoTIFF this reader can use.
struct GeoTiffError: Error, Equatable, CustomStringConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var description: String { message }
}

/// Reads single-band 32-bit float GeoTIFFs, the format elevation web services return: strips or tiles, uncompressed
/// or Deflate, either byte order, north-up georeferencing. Anything else is refused with a `GeoTiffError`.
enum GeoTiff {
    final class Raster {
        let width: Int
        let height: Int
        /// Row-major from the top row; NaN where the file has no data.
        var values: [Float]
        /// Map position of the top-left corner of the top-left pixel.
        let left: Double
        let top: Double
        let pixelWidth: Double
        let pixelHeight: Double

        init(width: Int, height: Int, values: [Float], left: Double, top: Double, pixelWidth: Double, pixelHeight: Double) {
            self.width = width
            self.height = height
            self.values = values
            self.left = left
            self.top = top
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    private static let maxPixels = 4_194_304

    /// Reads out of range throw "truncated TIFF" as they happen, as GeoTiff.kt gets by catching IndexOutOfBoundsException.
    static func read(_ bytes: [UInt8]) throws -> Raster {
        try parse(bytes)
    }

    static func read(_ data: Data) throws -> Raster {
        try read([UInt8](data))
    }

    private static func parse(_ bytes: [UInt8]) throws -> Raster {
        if bytes.count < 8 { throw GeoTiffError("not a TIFF") }
        let bigEndian: Bool
        if bytes[0] == UInt8(ascii: "I") && bytes[1] == UInt8(ascii: "I") {
            bigEndian = false
        } else if bytes[0] == UInt8(ascii: "M") && bytes[1] == UInt8(ascii: "M") {
            bigEndian = true
        } else {
            throw GeoTiffError("not a TIFF")
        }
        let buf = Buffer(bytes: bytes, bigEndian: bigEndian)
        if try buf.getShort(2) != 42 { throw GeoTiffError("unsupported TIFF variant") }
        let tags = try Tags(buf, try buf.getUInt(4))

        guard let width = try tags.int(256) else { throw GeoTiffError("no width") }
        guard let height = try tags.int(257) else { throw GeoTiffError("no height") }
        if width <= 0 || height <= 0 || Int64(width) * Int64(height) > Int64(maxPixels) {
            throw GeoTiffError("unsupported size \(width)x\(height)")
        }
        if (try tags.longs(258)).map({ bits in bits.allSatisfy { $0 == 32 } }) != true { throw GeoTiffError("not 32-bit samples") }
        if (try tags.int(339) ?? 1) != 3 { throw GeoTiffError("not floating point samples") }
        if (try tags.int(277) ?? 1) != 1 { throw GeoTiffError("more than one band") }
        if (try tags.int(284) ?? 1) != 1 { throw GeoTiffError("unsupported planar configuration") }
        if (try tags.int(317) ?? 1) != 1 { throw GeoTiffError("unsupported predictor") }
        let compression = try tags.int(259) ?? 1
        if compression != 1 && compression != 8 && compression != 32946 {
            throw GeoTiffError("unsupported compression \(compression)")
        }

        var values = [Float](repeating: 0, count: width * height)
        if let tileWidth = try tags.int(322) {
            guard let tileHeight = try tags.int(323) else { throw GeoTiffError("no tile height") }
            if tileWidth <= 0 || tileHeight <= 0 || Int64(tileWidth) * Int64(tileHeight) > Int64(maxPixels) {
                throw GeoTiffError("bad tile size")
            }
            let across = (width + tileWidth - 1) / tileWidth
            let down = (height + tileHeight - 1) / tileHeight
            guard let offsets = try tags.longs(324) else { throw GeoTiffError("no tile offsets") }
            guard let counts = try tags.longs(325) else { throw GeoTiffError("no tile sizes") }
            if offsets.count != across * down || counts.count != offsets.count { throw GeoTiffError("tile count mismatch") }
            for t in offsets.indices {
                let chunk = try samples(bytes, offsets[t], counts[t], tileWidth * tileHeight, compression, bigEndian)
                let x0 = t % across * tileWidth
                let y0 = t / across * tileHeight
                let length = min(tileWidth, width - x0)
                for row in 0..<min(tileHeight, height - y0) {
                    let from = row * tileWidth
                    let to = (y0 + row) * width + x0
                    values.replaceSubrange(to..<to + length, with: chunk[from..<from + length])
                }
            }
        } else {
            let rowsPerStrip = Int((try tags.long(278) ?? Int64(height)).clamped(1, Int64(height)))
            guard let offsets = try tags.longs(273) else { throw GeoTiffError("no strip offsets") }
            guard let counts = try tags.longs(279) else { throw GeoTiffError("no strip sizes") }
            if offsets.count != (height + rowsPerStrip - 1) / rowsPerStrip || counts.count != offsets.count {
                throw GeoTiffError("strip count mismatch")
            }
            for s in offsets.indices {
                let rows = min(rowsPerStrip, height - s * rowsPerStrip)
                let chunk = try samples(bytes, offsets[s], counts[s], rows * width, compression, bigEndian)
                let to = s * rowsPerStrip * width
                values.replaceSubrange(to..<to + rows * width, with: chunk)
            }
        }

        let noData = (try tags.ascii(42113)).flatMap { floatOrNull($0) }
        for i in values.indices {
            let v = values[i]
            // GDAL writes -3.4028235E38 as text, which may not parse back to exactly the stored float.
            if noData.map({ v == $0 }) == true || v < -1e30 || v > 1e30 { values[i] = .nan }
        }

        let transform = try tags.doubles(34264)
        var left: Double
        var top: Double
        let pixelWidth: Double
        let pixelHeight: Double
        if let transform = transform, transform.count >= 16 {
            if transform[1] != 0.0 || transform[4] != 0.0 { throw GeoTiffError("rotated rasters are not supported") }
            pixelWidth = transform[0]
            pixelHeight = -transform[5]
            left = transform[3]
            top = transform[7]
        } else {
            guard let tie = try tags.doubles(33922) else { throw GeoTiffError("no georeferencing") }
            guard let scale = try tags.doubles(33550) else { throw GeoTiffError("no pixel scale") }
            if tie.count < 6 || scale.count < 2 { throw GeoTiffError("bad georeferencing") }
            pixelWidth = scale[0]
            pixelHeight = scale[1]
            left = tie[3] - tie[0] * pixelWidth
            top = tie[4] + tie[1] * pixelHeight
        }
        if !(pixelWidth > 0) || !(pixelHeight > 0) { throw GeoTiffError("bad pixel size") }
        // GTRasterTypeGeoKey 2 (PixelIsPoint) puts the tie point on the pixel's centre rather than its corner.
        if try tags.geoKey(1025) == 2 {
            left -= pixelWidth / 2
            top += pixelHeight / 2
        }
        return Raster(width: width, height: height, values: values, left: left, top: top,
                      pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private static func samples(_ bytes: [UInt8], _ offset: Int64, _ count: Int64, _ pixels: Int, _ compression: Int,
                                _ bigEndian: Bool) throws -> [Float] {
        if offset < 0 || count < 0 || offset + count > Int64(bytes.count) { throw GeoTiffError("chunk outside the file") }
        let expected = pixels * 4
        let raw: [UInt8]
        let start: Int
        if compression == 1 {
            if count < Int64(expected) { throw GeoTiffError("short chunk") }
            raw = bytes
            start = Int(offset)
        } else {
            do {
                raw = try Inflate.zlib(bytes, offset: Int(offset), count: Int(count), expected: expected)
            } catch Inflate.Failure.short {
                throw GeoTiffError("short compressed chunk")
            } catch {
                throw GeoTiffError("corrupt compressed chunk")
            }
            start = 0
        }
        var floats = [Float](repeating: 0, count: pixels)
        for i in 0..<pixels {
            let p = start + i * 4
            let b0 = UInt32(raw[p]), b1 = UInt32(raw[p + 1]), b2 = UInt32(raw[p + 2]), b3 = UInt32(raw[p + 3])
            let bits: UInt32
            if bigEndian {
                bits = b0 << 24 | b1 << 16 | b2 << 8 | b3
            } else {
                bits = b3 << 24 | b2 << 16 | b1 << 8 | b0
            }
            floats[i] = Float(bitPattern: bits)
        }
        return floats
    }

    /// Kotlin's `trim().toFloatOrNull()`: Java's float syntax (with `NaN`, `Infinity`, hex and an f or d suffix), or nil.
    private static func floatOrNull(_ text: String) -> Float? {
        let javaFloat = "^[\\x00-\\x20]*[+-]?(NaN|Infinity|((([0-9]+)(\\.)?([0-9]*)([eE][+-]?[0-9]+)?)|(\\.([0-9]+)([eE][+-]?[0-9]+)?)|"
            + "(((0[xX][0-9a-fA-F]+(\\.)?)|(0[xX][0-9a-fA-F]*\\.[0-9a-fA-F]+))[pP][+-]?[0-9]+))[fFdD]?)[\\x00-\\x20]*$"
        guard text.range(of: javaFloat, options: .regularExpression) != nil else { return nil }
        var number = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value > 0x20 }))
        if let last = number.last, "fFdD".contains(last) { number.removeLast() }
        if number.hasSuffix("NaN") { return .nan }
        if number.hasSuffix("Infinity") { return number.hasPrefix("-") ? -.infinity : .infinity }
        return Float(number)
    }

    /// Big- or little-endian reads that throw where `java.nio.ByteBuffer` would be out of bounds.
    private struct Buffer {
        let bytes: [UInt8]
        let bigEndian: Bool

        var limit: Int { bytes.count }

        private func check(_ index: Int, _ size: Int) throws {
            if index < 0 || index > bytes.count - size { throw GeoTiffError("truncated TIFF") }
        }

        private func unsigned(_ index: Int, _ size: Int) throws -> UInt64 {
            try check(index, size)
            var value: UInt64 = 0
            for k in 0..<size { value = value << 8 | UInt64(bytes[bigEndian ? index + k : index + size - 1 - k]) }
            return value
        }

        func getUByte(_ index: Int) throws -> Int {
            let value = try unsigned(index, 1)
            return Int(value)
        }

        func getShort(_ index: Int) throws -> Int {
            let value = try unsigned(index, 2)
            return Int(Int16(truncatingIfNeeded: value))
        }

        func getUShort(_ index: Int) throws -> Int {
            let value = try unsigned(index, 2)
            return Int(value)
        }

        func getInt(_ index: Int) throws -> Int {
            let value = try unsigned(index, 4)
            return Int(Int32(truncatingIfNeeded: value))
        }

        func getUInt(_ index: Int) throws -> Int64 {
            let value = try unsigned(index, 4)
            return Int64(value)
        }

        func getFloat(_ index: Int) throws -> Float {
            let value = try unsigned(index, 4)
            return Float(bitPattern: UInt32(value))
        }

        func getDouble(_ index: Int) throws -> Double {
            let value = try unsigned(index, 8)
            return Double(bitPattern: value)
        }
    }

    private struct Tags {
        private struct Entry {
            let type: Int
            let count: Int64
            let at: Int
        }

        private let buf: Buffer
        private var entries: [Int: Entry] = [:]

        init(_ buf: Buffer, _ ifd: Int64) throws {
            self.buf = buf
            if ifd < 8 || ifd + 2 > Int64(buf.limit) { throw GeoTiffError("bad directory offset") }
            let n = try buf.getUShort(Int(ifd))
            for i in 0..<n {
                let p = Int(ifd) + 2 + i * 12
                let tag = try buf.getUShort(p)
                let type = try buf.getUShort(p + 2)
                let count = try buf.getUInt(p + 4)
                let size = Tags.typeSize(type) * count
                let at: Int
                if size <= 4 {
                    at = p + 8
                } else {
                    at = try buf.getInt(p + 8)
                }
                if size > 4 && (at < 0 || Int64(at) + size > Int64(buf.limit)) { throw GeoTiffError("tag \(tag) outside the file") }
                entries[tag] = Entry(type: type, count: count, at: at)
            }
        }

        private static func typeSize(_ type: Int) -> Int64 {
            switch type {
            case 1, 2, 6, 7: return 1
            case 3, 8: return 2
            case 4, 9, 11: return 4
            case 5, 10, 12: return 8
            default: return 1
            }
        }

        func longs(_ tag: Int) throws -> [Int64]? {
            guard let e = entries[tag] else { return nil }
            if e.count > 1_000_000 { throw GeoTiffError("tag \(tag) too long") }
            var out = [Int64]()
            out.reserveCapacity(Int(e.count))
            for i in 0..<Int(e.count) {
                switch e.type {
                case 3: out.append(Int64(try buf.getUShort(e.at + i * 2)))
                case 4: out.append(try buf.getUInt(e.at + i * 4))
                case 1: out.append(Int64(try buf.getUByte(e.at + i)))
                default: throw GeoTiffError("tag \(tag) is not an integer")
                }
            }
            return out
        }

        func long(_ tag: Int) throws -> Int64? { try longs(tag)?.first }

        func int(_ tag: Int) throws -> Int? {
            guard let value = try long(tag) else { return nil }
            if value > Int64(Int32.max) { throw GeoTiffError("tag \(tag) too large") }
            return Int(value)
        }

        func doubles(_ tag: Int) throws -> [Double]? {
            guard let e = entries[tag] else { return nil }
            if e.count > 1_000 { throw GeoTiffError("tag \(tag) too long") }
            var out = [Double]()
            for i in 0..<Int(e.count) {
                switch e.type {
                case 12: out.append(try buf.getDouble(e.at + i * 8))
                case 11: out.append(Double(try buf.getFloat(e.at + i * 4)))
                default: throw GeoTiffError("tag \(tag) is not a real number")
                }
            }
            return out
        }

        func ascii(_ tag: Int) throws -> String? {
            guard let e = entries[tag] else { return nil }
            if e.type != 2 || e.count > 1_000 { return nil }
            var scalars = String.UnicodeScalarView()
            for i in 0..<Int(e.count) {
                let byte = try buf.getUByte(e.at + i)
                // As Java's US-ASCII decoding: anything above 127 is a replacement character.
                scalars.append(byte < 0x80 ? Unicode.Scalar(UInt8(byte)) : "\u{FFFD}")
            }
            var text = String(scalars)
            while text.unicodeScalars.last == "\u{0}" { text.unicodeScalars.removeLast() }
            return text
        }

        /// A value from the GeoKeyDirectory stored directly in it (TIFFTagLocation 0), or nil.
        func geoKey(_ key: Int) throws -> Int? {
            guard let dir = try longs(34735) else { return nil }
            if dir.count < 4 { return nil }
            let keys = Int(Int32(truncatingIfNeeded: dir[3]))
            var k = 0
            while k < keys {
                let base = 4 + k * 4
                if base + 3 >= dir.count { break }
                if Int(Int32(truncatingIfNeeded: dir[base])) == key && dir[base + 1] == 0 {
                    return Int(Int32(truncatingIfNeeded: dir[base + 3]))
                }
                k += 1
            }
            return nil
        }
    }
}
