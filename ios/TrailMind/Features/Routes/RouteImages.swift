import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Pixels in and out of images for the terrain and LiDAR layers.
enum RouteImages {
    /// The exact RGB samples of a PNG as Android's `Bitmap.getPixels` gives them (opaque ARGB words), read from the
    /// decoded image without colour management, so Terrarium heights come out exact.
    static func argbPixels(_ data: Data, width: Int, height: Int) -> [UInt32]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
              image.width == width, image.height == height else { return nil }
        if let raw = rawArgb(image) { return raw }
        return drawnArgb(image)
    }

    private static func rawArgb(_ image: CGImage) -> [UInt32]? {
        guard image.bitsPerComponent == 8, image.colorSpace?.model == .rgb,
              image.bitsPerPixel == 24 || image.bitsPerPixel == 32,
              let cf = image.dataProvider?.data else { return nil }
        let bytes = CFDataGetBytePtr(cf)
        let length = CFDataGetLength(cf)
        let bpp = image.bitsPerPixel / 8
        let alpha = image.alphaInfo
        let little = image.byteOrderInfo == .order32Little
        // Offsets of R, G and B within a pixel, as stored.
        var r = 0, g = 1, b = 2
        if bpp == 4 {
            switch alpha {
            case .premultipliedFirst, .first, .noneSkipFirst: (r, g, b) = little ? (2, 1, 0) : (1, 2, 3)
            case .premultipliedLast, .last, .noneSkipLast: (r, g, b) = little ? (3, 2, 1) : (0, 1, 2)
            default: return nil
            }
        } else if alpha != .none {
            return nil
        }
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let a = bpp == 4 ? (alpha == .premultipliedFirst || alpha == .first ? (little ? 3 : 0) : (little ? 0 : 3)) : -1
        guard let bytes, image.bytesPerRow * image.height <= length else { return nil }
        var out = [UInt32](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<image.width {
                let p = row + x * bpp
                var rv = UInt32(p[r]), gv = UInt32(p[g]), bv = UInt32(p[b])
                var av: UInt32 = 255
                if a >= 0, alpha != .noneSkipFirst, alpha != .noneSkipLast {
                    av = UInt32(p[a])
                    if premultiplied, av > 0, av < 255 {
                        rv = min(255, rv * 255 / av)
                        gv = min(255, gv * 255 / av)
                        bv = min(255, bv * 255 / av)
                    }
                }
                out[y * image.width + x] = av << 24 | rv << 16 | gv << 8 | bv
            }
        }
        return out
    }

    /// Fallback for images ImageIO keeps in another layout (palette, grey): drawn into sRGB.
    private static func drawnArgb(_ image: CGImage) -> [UInt32]? {
        var out = [UInt32](repeating: 0, count: image.width * image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok: Bool = out.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? out : nil
    }

    /// An image from straight (not premultiplied) ARGB words, as `Bitmap.createBitmap(colors, ...)` makes one.
    static func image(argb: [UInt32], width: Int, height: Int) -> CGImage? {
        var premultiplied = [UInt32](repeating: 0, count: argb.count)
        for i in argb.indices {
            let c = argb[i]
            let a = c >> 24
            if a == 0 { continue }
            if a == 255 { premultiplied[i] = c; continue }
            let r = (c >> 16 & 0xFF) * a / 255
            let g = (c >> 8 & 0xFF) * a / 255
            let b = (c & 0xFF) * a / 255
            premultiplied[i] = a << 24 | r << 16 | g << 8 | b
        }
        let data = premultiplied.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A transparent tile, `pixels` square, with `draw` painting into it; PNG bytes for an MKTileOverlay.
    static func tile(pixels: Int, _ draw: (CGContext) -> Void) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { ctx in draw(ctx.cgContext) }
        return image.pngData()
    }
}
