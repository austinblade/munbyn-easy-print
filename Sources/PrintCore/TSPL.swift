import Foundation

/// 1-bit raster, rows top-to-bottom, 8 pixels per byte MSB-first, `1 = dark`.
public struct MonoBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.bytesPerRow = (width + 7) / 8
        self.data = data ?? [UInt8](repeating: 0, count: bytesPerRow * height)
    }

    public func isDark(x: Int, y: Int) -> Bool {
        data[y * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0
    }

    public mutating func setDark(x: Int, y: Int) {
        data[y * bytesPerRow + x / 8] |= 0x80 >> UInt8(x % 8)
    }
}

/// Which flavor of TSPL the printer firmware speaks.
public enum TSPLDialect: String, CaseIterable, Codable, Sendable {
    /// LabeLife `tspl-l3`/`tspl-m3` (BLE/Wi-Fi Aimo firmware): chunked LZO
    /// `BITMAP …,4,`, `1 = dark`, `PRINT` terminated with `\n\r`.
    case aimoChunked
    /// LabeLife `tspl-c1`: whole-frame LZO `BITMAP …,3,<len>,`, `1 = dark`.
    case aimoWholeFrame
    /// Stock TSC TSPL II: uncompressed `BITMAP …,0,`, `0 = dark`.
    case standard

    public var displayName: String {
        switch self {
        case .aimoChunked: return "Aimo / LabeLife — chunked LZO (mode 4)"
        case .aimoWholeFrame: return "Aimo / LabeLife — whole-frame LZO (mode 3)"
        case .standard: return "Standard TSPL II — uncompressed (mode 0)"
        }
    }
}

public enum PaperType: String, CaseIterable, Codable, Sendable {
    case gap
    case blackMark
    case continuous

    public var displayName: String {
        switch self {
        case .gap: return "Gap / die-cut labels"
        case .blackMark: return "Black mark"
        case .continuous: return "Continuous roll"
        }
    }
}

public struct TSPLOptions: Equatable, Sendable {
    public var dialect: TSPLDialect = .standard
    public var dpi: Int = 300
    /// 0...15; nil omits `DENSITY` and uses the printer's stored setting.
    public var density: Int?
    /// Inches per second; nil omits `SPEED`.
    public var speed: Int?
    public var paper: PaperType = .gap
    public var gapMM: Double = 3
    public var copies: Int = 1
    public var originDots: (x: Int, y: Int) = (0, 0)
    /// `DIRECTION 1,0` — rotate output 180° relative to feed.
    public var flip: Bool = false

    public init() {}

    public static func == (a: TSPLOptions, b: TSPLOptions) -> Bool {
        a.dialect == b.dialect && a.dpi == b.dpi && a.density == b.density && a.speed == b.speed
            && a.paper == b.paper && a.gapMM == b.gapMM && a.copies == b.copies
            && a.originDots == b.originDots && a.flip == b.flip
    }
}

/// Port of `packages/core/src/tspl/encode.ts` from thermal-label/labelife,
/// extended with a stock-TSPL dialect for non-Aimo firmware.
/// LabeLife is MIT licensed; see THIRD_PARTY_NOTICES.md.
public enum TSPLEncoder {
    public static func encode(_ bitmap: MonoBitmap, options: TSPLOptions) -> [UInt8] {
        var out = [UInt8]()
        func line(_ s: String, _ ending: String = "\r\n") { out.append(contentsOf: Array((s + ending).utf8)) }

        let dotsPerMM = Double(options.dpi) / 25.4
        let widthMM = Double(bitmap.width) / dotsPerMM
        let heightMM = Double(bitmap.height) / dotsPerMM

        // Leading newline, matching observed LabeLife wire output.
        line("")
        if let density = options.density { line("DENSITY \(max(0, min(15, density)))") }
        if let speed = options.speed { line("SPEED \(speed)") }
        line("REFERENCE \(options.originDots.x),\(options.originDots.y)")
        line("OFFSET 0 mm")

        switch options.dialect {
        case .aimoChunked, .aimoWholeFrame:
            // Aimo firmware is only ever fed integer millimetres.
            line("SIZE \(max(1, Int(widthMM.rounded()))) mm,\(max(1, Int(heightMM.rounded()))) mm")
        case .standard:
            line("SIZE \(mm(widthMM)) mm,\(mm(heightMM)) mm")
        }

        switch options.paper {
        case .gap: line("GAP \(fixed2(options.gapMM)) mm,0.00 mm")
        case .blackMark: line("BLINE \(fixed2(options.gapMM)) mm,0.00 mm")
        case .continuous: line("GAP 0.00 mm,0.00 mm")
        }

        line(options.flip ? "DIRECTION 1,0" : "DIRECTION 0,0")
        line("CLS")

        let header = "BITMAP 0,0,\(bitmap.bytesPerRow),\(bitmap.height),"
        switch options.dialect {
        case .aimoChunked:
            line(header + "4,", "")
            out.append(contentsOf: LZO1X.chunkedFrame(bitmap.data))
        case .aimoWholeFrame:
            let compressed = LZO1X.compress(bitmap.data)
            line(header + "3,\(compressed.count),", "")
            out.append(contentsOf: compressed)
        case .standard:
            // Stock TSPL II: bit 0 = print a dot. CLS already blanked the
            // label, so only inked regions are sent (uncompressed links are slow).
            for r in inkedRegions(bitmap) {
                line("BITMAP \(r.byteX * 8),\(r.y),\(r.bytes),\(r.rows),0,", "")
                for row in r.y..<(r.y + r.rows) {
                    let start = row * bitmap.bytesPerRow + r.byteX
                    out.append(contentsOf: bitmap.data[start..<(start + r.bytes)].map { ~$0 })
                }
                line("")
            }
        }
        if options.dialect != .standard { line("") }

        let copies = max(1, options.copies)
        line("PRINT 1,\(copies)", options.dialect == .aimoChunked ? "\n\r" : "\r\n")
        return out
    }

    /// Paper calibration: the printer feeds a few labels to measure the label
    /// pitch and gap (or black mark), then remembers it. Without it, labels
    /// can start partway down the previous label.
    public static func calibration(widthMM: Double, heightMM: Double, options: TSPLOptions) -> [UInt8] {
        var s = "\r\nSIZE \(mm(widthMM)) mm,\(mm(heightMM)) mm\r\n"
        switch options.paper {
        case .gap: s += "GAP \(fixed2(options.gapMM)) mm,0.00 mm\r\nGAPDETECT\r\n"
        case .blackMark: s += "BLINE \(fixed2(options.gapMM)) mm,0.00 mm\r\nBLINEDETECT\r\n"
        case .continuous: s += "GAP 0.00 mm,0.00 mm\r\nFORMFEED\r\n"
        }
        return Array(s.utf8)
    }

    struct Region: Equatable {
        var byteX: Int, y: Int, bytes: Int, rows: Int
    }

    /// Splits the bitmap into horizontal bands and, within each band, into
    /// runs of byte columns that contain ink. Blank gaps are merged into a
    /// run when sending them costs less than another `BITMAP` header.
    static func inkedRegions(_ bitmap: MonoBitmap, bandRows: Int = 24) -> [Region] {
        let headerCost = 28
        var regions: [Region] = []
        var top = 0
        while top < bitmap.height {
            let bottom = min(top + bandRows, bitmap.height)
            var columns = [Bool](repeating: false, count: bitmap.bytesPerRow)
            var firstRow = -1, lastRow = -1
            for row in top..<bottom {
                let base = row * bitmap.bytesPerRow
                var inked = false
                for x in 0..<bitmap.bytesPerRow where bitmap.data[base + x] != 0 {
                    columns[x] = true
                    inked = true
                }
                if inked {
                    if firstRow < 0 { firstRow = row }
                    lastRow = row
                }
            }
            if firstRow >= 0 {
                let rows = lastRow - firstRow + 1
                let maxGap = max(0, headerCost / rows)
                var x = 0
                while x < columns.count {
                    guard columns[x] else { x += 1; continue }
                    var end = x + 1 // exclusive
                    var probe = end
                    while probe < columns.count {
                        if columns[probe] { end = probe + 1; probe += 1; continue }
                        var gap = 0
                        while probe + gap < columns.count, !columns[probe + gap] { gap += 1 }
                        guard probe + gap < columns.count, gap <= maxGap else { break }
                        probe += gap
                    }
                    regions.append(Region(byteX: x, y: firstRow, bytes: end - x, rows: rows))
                    x = end
                }
            }
            top = bottom
        }
        return regions
    }

    private static func fixed2(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func mm(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
