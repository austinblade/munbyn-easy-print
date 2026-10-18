// Renders Resources/AppIcon.icns: a label coming out of a printer.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Squircle background.
    let bg = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)

    // Label strip with barcode.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(312, 210, 400, 470), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSColor.black.setFill()
    let bars: [CGFloat] = [8, 4, 12, 4, 6, 10, 4, 8, 14, 4, 6, 4, 10, 6, 4, 12, 8, 4]
    var x: CGFloat = 352
    for (i, w) in bars.enumerated() {
        if i % 2 == 0 { NSBezierPath(rect: r(x, 300, w * 1.1, 150)).fill() }
        x += w * 1.1 + 4
    }
    NSBezierPath(roundedRect: r(352, 500, 320, 34), xRadius: 8 * s, yRadius: 8 * s).fill()
    NSBezierPath(roundedRect: r(352, 560, 210, 26), xRadius: 8 * s, yRadius: 8 * s).fill()

    // Printer body.
    NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.20, alpha: 1),
               ending: NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.13, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: r(220, 620, 584, 210), xRadius: 60 * s, yRadius: 60 * s), angle: -90)
    NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: r(292, 640, 440, 22), xRadius: 11 * s, yRadius: 11 * s).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: r(712, 742, 36, 36)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
