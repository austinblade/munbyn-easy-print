import CoreGraphics
import Foundation

public struct RasterOptions: Sendable {
    public var dpi: Double = 300
    /// Printable width of the head. Wider pages are rotated 90° if that makes
    /// them fit, otherwise centered and cropped.
    public var maxWidthDots: Int = 1280
    /// Floyd–Steinberg dither for photos and gray fills. Vector art is rendered
    /// without antialiasing, so barcodes stay crisp either way.
    public var dither: Bool = true
    /// Gray level (0...255) below which a pixel prints when not dithering.
    public var threshold: Int = 160

    public init() {}
}

public struct RenderedLabel: Sendable {
    public var bitmap: MonoBitmap
    public var rotated: Bool
}

public enum Rasterizer {
    /// Render one PDF page at its own page size (CUPS has already laid out the
    /// document on the chosen label stock).
    public static func render(pdfPage page: CGPDFPage, options: RasterOptions) -> RenderedLabel {
        let box = page.getBoxRect(.cropBox)
        let angle = ((page.rotationAngle % 360) + 360) % 360
        let quarter = angle == 90 || angle == 270
        let pageSize = quarter ? CGSize(width: box.height, height: box.width) : box.size

        return render(contentSize: pageSize, options: options, antialias: false) { ctx, rect in
            let s = min(rect.width / pageSize.width, rect.height / pageSize.height)
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.rotate(by: -CGFloat(angle) * .pi / 180)
            ctx.translateBy(x: -box.midX, y: -box.midY)
            ctx.clip(to: box)
            ctx.drawPDFPage(page)
        }
    }

    /// Render an image onto a label of `labelSize` points (1/72"), aspect-fit.
    /// Pass the image's own physical size for raster input (PWG/URF).
    public static func render(image: CGImage, labelSize: CGSize, options: RasterOptions) -> RenderedLabel {
        render(contentSize: labelSize, options: options, antialias: true) { ctx, rect in
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = min(rect.width / iw, rect.height / ih)
            let w = iw * s, h = ih * s
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        }
    }

    /// Lays out `contentSize` (points) on the head, rotating if needed, and
    /// hands `draw` a context whose `rect` is the content area in device pixels.
    public static func render(
        contentSize: CGSize,
        options: RasterOptions,
        antialias: Bool,
        draw: (CGContext, CGRect) -> Void
    ) -> RenderedLabel {
        let scale = options.dpi / 72
        let contentW = max(1, Int((contentSize.width * scale).rounded()))
        let contentH = max(1, Int((contentSize.height * scale).rounded()))

        let rotate = contentW > options.maxWidthDots && contentH <= options.maxWidthDots
        let canvasW = min(rotate ? contentH : contentW, options.maxWidthDots)
        let canvasH = rotate ? contentW : contentH

        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return RenderedLabel(bitmap: MonoBitmap(width: canvasW, height: canvasH), rotated: rotate)
        }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.setShouldAntialias(antialias)
        ctx.setAllowsAntialiasing(antialias)

        ctx.saveGState()
        if rotate {
            // Content x runs down the canvas; content y runs across it.
            ctx.translateBy(x: CGFloat(canvasW - contentH) / 2, y: CGFloat(contentW))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(canvasW - contentW) / 2, y: 0)
        }
        draw(ctx, CGRect(x: 0, y: 0, width: contentW, height: contentH))
        ctx.restoreGState()

        let stride = ctx.bytesPerRow
        let pixels = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: stride * canvasH)
        let bitmap = threshold(gray: pixels, width: canvasW, height: canvasH, stride: stride, options: options)
        return RenderedLabel(bitmap: bitmap, rotated: rotate)
    }

    /// Gray (0 = black, 255 = white, top row first) to 1-bit.
    public static func threshold(
        gray: UnsafeBufferPointer<UInt8>, width: Int, height: Int, stride: Int, options: RasterOptions
    ) -> MonoBitmap {
        var out = MonoBitmap(width: width, height: height)

        guard options.dither else {
            let t = UInt8(clamping: options.threshold)
            for y in 0..<height {
                let row = y * stride
                for x in 0..<width where gray[row + x] < t { out.setDark(x: x, y: y) }
            }
            return out
        }

        // Floyd–Steinberg with two rolling error rows (values scaled by 16).
        var cur = [Int](repeating: 0, count: width + 2)
        var next = [Int](repeating: 0, count: width + 2)
        for y in 0..<height {
            let row = y * stride
            for x in 0..<width {
                let v = Int(gray[row + x]) * 16 + cur[x + 1]
                let dark = v < 128 * 16
                if dark { out.setDark(x: x, y: y) }
                let err = v - (dark ? 0 : 255 * 16)
                cur[x + 2] += err * 7 / 16
                next[x] += err * 3 / 16
                next[x + 1] += err * 5 / 16
                next[x + 2] += err / 16
            }
            swap(&cur, &next)
            for i in next.indices { next[i] = 0 }
        }
        return out
    }

    /// Grayscale preview image of a 1-bit label (for the UI and debug dumps).
    public static func previewImage(_ bitmap: MonoBitmap) -> CGImage? {
        var gray = [UInt8](repeating: 255, count: bitmap.width * bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isDark(x: x, y: y) { gray[y * bitmap.width + x] = 0 }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: bitmap.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
