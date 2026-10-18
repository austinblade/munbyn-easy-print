import AppKit
import CoreImage
import PrintCore

/// Calibration label: border, edge ticks, text, a Code 128 barcode and a QR code.
enum TestLabel {
    static func make(media: LabelMedia, dpi: Int, printerName: String?) -> CGImage? {
        let scale = Double(dpi) / 72
        let w = Int(media.sizePoints.width * scale), h = Int(media.sizePoints.height * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        let W = CGFloat(w), H = CGFloat(h), unit = min(W, H) / 40
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)

        // Border inset by 1/16" and 1/4" tick marks.
        let inset = CGFloat(dpi) / 16
        ctx.setLineWidth(max(2, unit / 4))
        ctx.stroke(CGRect(x: inset, y: inset, width: W - 2 * inset, height: H - 2 * inset))
        let tick = CGFloat(dpi) / 4
        var x = inset
        while x < W - inset { ctx.fill(CGRect(x: x, y: H - inset - unit, width: 2, height: unit)); x += tick }

        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black]
            let str = NSAttributedString(string: s, attributes: attrs)
            let bounds = str.size()
            str.draw(at: CGPoint(x: (W - bounds.width) / 2, y: y))
        }

        let titleSize = unit * 2.4
        var y = H - inset - unit * 5
        text("Munbyn Easy Print", size: titleSize, weight: .bold, y: y)
        y -= titleSize * 1.3
        text(printerName ?? "MUNBYN 941BP", size: titleSize * 0.6, weight: .regular, y: y)
        y -= titleSize * 0.9
        text("\(media.displayName) · \(dpi) dpi · \(Date().formatted(date: .abbreviated, time: .shortened))", size: titleSize * 0.45, weight: .regular, y: y)

        // Gray ramp to check dithering.
        let rampY = y - unit * 3
        let rampW = (W - 4 * inset) / 8
        for i in 0..<8 {
            ctx.setFillColor(gray: CGFloat(i) / 7, alpha: 1)
            ctx.fill(CGRect(x: 2 * inset + CGFloat(i) * rampW, y: rampY, width: rampW, height: unit * 1.5))
        }
        ctx.setFillColor(gray: 0, alpha: 1)

        NSGraphicsContext.restoreGraphicsState()

        let ci = CIContext()
        let barcodeTop = rampY - unit * 2
        if let filter = CIFilter(name: "CICode128BarcodeGenerator") {
            filter.setValue(Data("MUNBYN-EASY-PRINT".utf8), forKey: "inputMessage")
            filter.setValue(0, forKey: "inputQuietSpace")
            if let out = filter.outputImage, let cg = ci.createCGImage(out, from: out.extent) {
                let moduleWidth = max(1, floor((W - 4 * inset) / CGFloat(cg.width)))
                let bw = CGFloat(cg.width) * moduleWidth, bh = min(unit * 6, barcodeTop - H * 0.35)
                ctx.interpolationQuality = .none
                ctx.draw(cg, in: CGRect(x: (W - bw) / 2, y: barcodeTop - bh, width: bw, height: max(bh, unit * 2)))
            }
        }
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data("https://github.com/thermal-label/labelife".utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            if let out = filter.outputImage, let cg = ci.createCGImage(out, from: out.extent) {
                let module = max(1, floor(min(W, H) * 0.3 / CGFloat(cg.width)))
                let side = CGFloat(cg.width) * module
                ctx.interpolationQuality = .none
                ctx.draw(cg, in: CGRect(x: (W - side) / 2, y: inset * 2, width: side, height: side))
            }
        }

        return ctx.makeImage()
    }
}
