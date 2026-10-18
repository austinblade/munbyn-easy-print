import CoreGraphics
import Foundation
import ImageIO

public enum DocumentFormat: String, Sendable {
    case pdf = "application/pdf"
    case pwgRaster = "image/pwg-raster"
    case urf = "image/urf"
    case jpeg = "image/jpeg"
    case png = "image/png"

    public static let supportedMIMETypes = [pdf, pwgRaster, urf, jpeg, png].map(\.rawValue)

    /// Resolve an IPP `document-format`, sniffing magic bytes for octet-stream.
    public static func resolve(mimeType: String?, data: [UInt8]) -> DocumentFormat? {
        if let mimeType, let f = DocumentFormat(rawValue: mimeType) { return f }
        func starts(_ magic: [UInt8]) -> Bool { data.starts(with: magic) }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts(Array("RaS2".utf8)) { return .pwgRaster }
        if starts(Array("UNIRAST".utf8)) { return .urf }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        return nil
    }
}

public enum DecodeError: Error, LocalizedError {
    case unsupportedFormat(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): return "Unsupported document format \(f)"
        case .malformed(let why): return "Malformed document: \(why)"
        }
    }
}

public enum DocumentDecoder {
    /// Decode every page of a document to a 1-bit label.
    /// `fallbackLabelSize` (points) is used for formats without a page size (JPEG/PNG).
    public static func render(
        data: [UInt8], format: DocumentFormat, fallbackLabelSize: CGSize, options: RasterOptions
    ) throws -> [RenderedLabel] {
        switch format {
        case .pdf:
            guard let provider = CGDataProvider(data: Data(data) as CFData),
                  let doc = CGPDFDocument(provider), doc.numberOfPages > 0
            else { throw DecodeError.malformed("unreadable PDF") }
            return (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map {
                Rasterizer.render(pdfPage: $0, options: options)
            }

        case .jpeg, .png:
            guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { throw DecodeError.malformed("unreadable image") }
            return [Rasterizer.render(image: image, labelSize: fallbackLabelSize, options: options)]

        case .pwgRaster:
            return try PWGRaster.decode(data).map { page in
                Rasterizer.render(image: page.image, labelSize: page.sizePoints, options: options)
            }

        case .urf:
            return try URFRaster.decode(data).map { page in
                Rasterizer.render(image: page.image, labelSize: page.sizePoints, options: options)
            }
        }
    }
}

// MARK: - Raster formats

public struct RasterPage {
    public var image: CGImage
    public var sizePoints: CGSize
}

private struct ByteReader {
    let bytes: [UInt8]
    var pos = 0

    var remaining: Int { bytes.count - pos }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw DecodeError.malformed("unexpected end of raster data") }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, pos + n <= bytes.count else { throw DecodeError.malformed("unexpected end of raster data") }
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }

    func u32BE(at offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }
}

/// Shared PackBits-style line codec used by both PWG Raster and Apple URF:
/// a line-repeat byte, then runs of `n+1` repeated pixels (0...127) or
/// `257-n` literal pixels (129...255); 128 fills the rest of the line white.
private func decodeRasterLines(
    _ r: inout ByteReader, width: Int, height: Int, bytesPerPixel: Int, white: UInt8
) throws -> [UInt8] {
    let lineBytes = width * bytesPerPixel
    var out = [UInt8](repeating: white, count: lineBytes * height)
    var y = 0
    while y < height {
        let repeatCount = Int(try r.u8()) + 1
        var line = [UInt8](repeating: white, count: lineBytes)
        var x = 0
        while x < lineBytes {
            let code = Int(try r.u8())
            if code == 128 {
                break
            } else if code < 128 {
                let pixel = try r.take(bytesPerPixel)
                for _ in 0..<(code + 1) where x < lineBytes {
                    line.replaceSubrange(x..<(x + bytesPerPixel), with: pixel)
                    x += bytesPerPixel
                }
            } else {
                let n = (257 - code) * bytesPerPixel
                let run = try r.take(n)
                let fit = min(n, lineBytes - x)
                line.replaceSubrange(x..<(x + fit), with: run.prefix(fit))
                x += fit
            }
        }
        for _ in 0..<repeatCount where y < height {
            out.replaceSubrange((y * lineBytes)..<((y + 1) * lineBytes), with: line)
            y += 1
        }
    }
    return out
}

/// Pixels to an 8-bit gray CGImage (0 = black).
private func grayImage(from pixels: [UInt8], width: Int, height: Int, bytesPerPixel: Int, inverted: Bool) -> CGImage? {
    var gray = [UInt8](repeating: 255, count: width * height)
    for i in 0..<(width * height) {
        let p = i * bytesPerPixel
        var v: Int
        if bytesPerPixel >= 3 {
            v = (Int(pixels[p]) * 299 + Int(pixels[p + 1]) * 587 + Int(pixels[p + 2]) * 114) / 1000
        } else {
            v = Int(pixels[p])
        }
        if inverted { v = 255 - v }
        gray[i] = UInt8(v)
    }
    guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}

/// Expand 1-bit packed lines (PWG `black_1`, 1 = black) to 8-bit gray.
private func expandOneBit(_ packed: [UInt8], width: Int, height: Int, bytesPerLine: Int) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: width * height)
    for y in 0..<height {
        for x in 0..<width where packed[y * bytesPerLine + x / 8] & (0x80 >> UInt8(x % 8)) != 0 {
            out[y * width + x] = 0
        }
    }
    return out
}

public enum PWGRaster {
    static let headerSize = 1796

    public static func decode(_ data: [UInt8]) throws -> [RasterPage] {
        guard data.starts(with: Array("RaS2".utf8)) else { throw DecodeError.malformed("missing RaS2 sync word") }
        var r = ByteReader(bytes: data, pos: 4)
        var pages: [RasterPage] = []

        while r.remaining >= headerSize {
            let h = r.pos
            let xdpi = r.u32BE(at: h + 276), ydpi = r.u32BE(at: h + 280)
            let width = r.u32BE(at: h + 372), height = r.u32BE(at: h + 376)
            let bitsPerColor = r.u32BE(at: h + 384), bitsPerPixel = r.u32BE(at: h + 388)
            let bytesPerLine = r.u32BE(at: h + 392), colorSpace = r.u32BE(at: h + 400)
            r.pos += headerSize

            guard width > 0, height > 0, xdpi > 0, ydpi > 0, bitsPerColor == 8 || bitsPerPixel == 1 else {
                throw DecodeError.malformed("unsupported PWG page (\(bitsPerPixel) bpp)")
            }

            // CUPS_CSPACE_K (3) is ink-based: 0 = white. Gray/RGB spaces are light-based.
            let inkBased = colorSpace == 3
            let image: CGImage?
            if bitsPerPixel == 1 {
                let packedWidth = bytesPerLine
                let packed = try decodeRasterLines(&r, width: packedWidth, height: height, bytesPerPixel: 1, white: 0)
                let gray = expandOneBit(packed, width: width, height: height, bytesPerLine: bytesPerLine)
                image = grayImage(from: gray, width: width, height: height, bytesPerPixel: 1, inverted: false)
            } else {
                let bpp = bitsPerPixel / 8
                let pixels = try decodeRasterLines(&r, width: width, height: height, bytesPerPixel: bpp, white: inkBased ? 0 : 255)
                image = grayImage(from: pixels, width: width, height: height, bytesPerPixel: bpp, inverted: inkBased)
            }
            guard let image else { throw DecodeError.malformed("could not build page image") }
            pages.append(RasterPage(
                image: image,
                sizePoints: CGSize(width: Double(width) * 72 / Double(xdpi), height: Double(height) * 72 / Double(ydpi))
            ))
        }
        guard !pages.isEmpty else { throw DecodeError.malformed("PWG stream has no pages") }
        return pages
    }
}

public enum URFRaster {
    public static func decode(_ data: [UInt8]) throws -> [RasterPage] {
        guard data.count >= 12, data.starts(with: Array("UNIRAST".utf8)) else {
            throw DecodeError.malformed("missing UNIRAST header")
        }
        var r = ByteReader(bytes: data, pos: 8)
        let pageCount = r.u32BE(at: 8)
        r.pos = 12
        var pages: [RasterPage] = []

        while r.remaining >= 32, pageCount == 0 || pages.count < pageCount {
            let h = r.pos
            let bitsPerPixel = Int(data[h])
            let width = r.u32BE(at: h + 12), height = r.u32BE(at: h + 16), dpi = r.u32BE(at: h + 20)
            r.pos += 32
            guard width > 0, height > 0, dpi > 0, bitsPerPixel % 8 == 0, bitsPerPixel >= 8 else {
                throw DecodeError.malformed("unsupported URF page (\(bitsPerPixel) bpp)")
            }
            let bpp = bitsPerPixel / 8
            let pixels = try decodeRasterLines(&r, width: width, height: height, bytesPerPixel: bpp, white: 255)
            guard let image = grayImage(from: pixels, width: width, height: height, bytesPerPixel: bpp, inverted: false) else {
                throw DecodeError.malformed("could not build page image")
            }
            pages.append(RasterPage(
                image: image,
                sizePoints: CGSize(width: Double(width) * 72 / Double(dpi), height: Double(height) * 72 / Double(dpi))
            ))
        }
        guard !pages.isEmpty else { throw DecodeError.malformed("URF stream has no pages") }
        return pages
    }
}
