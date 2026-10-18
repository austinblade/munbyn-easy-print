#if DEBUG
import AppKit
import SwiftUI

/// Renders the README screenshots from sample data, without Bluetooth or the
/// IPP server: `MunbynEasyPrint --render-screenshots docs/screenshots`.
@MainActor
enum Screenshots {
    static func render(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = AppModel(demo: true)
        model.loadDemoState()

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let look = NSAppearance(named: appearance)!
            save(snapshot(MenuView().environment(model), appearance: look, title: nil, radius: 12),
                 to: dir.appendingPathComponent("menu-\(suffix).png"))
            save(snapshot(PrintingSettings().environment(model).frame(width: 520), appearance: look, title: "Printing", radius: 10),
                 to: dir.appendingPathComponent("settings-printing-\(suffix).png"))
            save(snapshot(ConnectionSettings().environment(model).frame(width: 520), appearance: look, title: "Connection", radius: 10),
                 to: dir.appendingPathComponent("settings-connection-\(suffix).png"))
            save(snapshot(GeneralSettings().environment(model).frame(width: 520), appearance: look, title: "General", radius: 10),
                 to: dir.appendingPathComponent("settings-general-\(suffix).png"))
        }
        print("Wrote screenshots to \(dir.path)")
    }

    /// Lays the view out in an off-screen window and draws it at 2x, with an
    /// optional title bar, rounded corners and a drop shadow.
    private static func snapshot(_ view: some View, appearance: NSAppearance, title: String?, radius: CGFloat) -> CGImage {
        // fittingSize overshoots for grouped Forms and the surplus lands above
        // the content, so measure the laid-out height and shrink to it.
        let measured = Measured()
        let content = VStack(spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .overlay(alignment: .leading) { TrafficLights().padding(.leading, 12) }
                Divider()
            }
            view.fixedSize(horizontal: false, vertical: true)
        }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { measured.height = proxy.size.height }
        })
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: content)
        host.appearance = appearance
        var size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let height = measured.height, height > 0, height < size.height {
            size.height = height
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return framed(rep.cgImage!, radius: radius * scale, dark: appearance.name == .darkAqua)
    }

    private static func framed(_ image: CGImage, radius: CGFloat, dark: Bool) -> CGImage {
        let margin: CGFloat = 60
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let ctx = CGContext(data: nil, width: Int(w + 2 * margin), height: Int(h + 2 * margin), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: margin, y: margin, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 50, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.3))
        ctx.addPath(path)
        ctx.setFillColor(gray: dark ? 0.15 : 1, alpha: 1)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(gray: dark ? 1 : 0, alpha: dark ? 0.2 : 0.15)
        ctx.setLineWidth(2)
        ctx.strokePath()
        return ctx.makeImage()!
    }

    private static func save(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width / 2, height: image.height / 2)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private final class Measured {
    var height: CGFloat?
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)],
                    id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
    }
}
#endif
