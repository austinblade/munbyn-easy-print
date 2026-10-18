import CoreGraphics
import Foundation

/// A label stock, named with its PWG 5101.1 self-describing media keyword.
public struct LabelMedia: Hashable, Sendable, Identifiable {
    public let keyword: String
    public let displayName: String
    /// Hundredths of a millimetre, as IPP `media-size` wants.
    public let width: Int
    public let height: Int

    public var id: String { keyword }

    public var sizePoints: CGSize {
        CGSize(width: Double(width) / 2540 * 72, height: Double(height) / 2540 * 72)
    }

    public static func inches(_ w: Double, _ h: Double) -> LabelMedia {
        let name = "\(fmt(w))x\(fmt(h))"
        return LabelMedia(
            keyword: "oe_\(name)-label_\(name)in",
            displayName: "\(fmt(w))\" × \(fmt(h))\"",
            width: Int((w * 2540).rounded()), height: Int((h * 2540).rounded())
        )
    }

    public static func millimetres(_ w: Int, _ h: Int) -> LabelMedia {
        LabelMedia(
            keyword: "om_\(w)x\(h)-label_\(w)x\(h)mm",
            displayName: "\(w) × \(h) mm",
            width: w * 100, height: h * 100
        )
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// The default stock is the first entry: 4x6" shipping labels.
    public static let catalog: [LabelMedia] = [
        .inches(4, 6), .inches(4, 8), .inches(4, 4), .inches(4, 3), .inches(4, 2), .inches(4, 1),
        .inches(3, 2), .inches(3, 1), .inches(2.25, 1.25), .inches(2, 1), .inches(1.5, 1),
        .millimetres(100, 150), .millimetres(100, 100), .millimetres(100, 50),
        .millimetres(60, 40), .millimetres(50, 30), .millimetres(40, 30),
    ]

    public static let `default` = catalog[0]

    /// Custom-size range advertised to CUPS (`custom_min_` / `custom_max_`).
    public static let customMin = (width: 2540, height: 1270)   // 1" × 0.5"
    public static let customMax = (width: 10795, height: 55880) // 4.25" × 22"

    public static func find(keyword: String) -> LabelMedia? {
        if let known = catalog.first(where: { $0.keyword == keyword }) { return known }
        return parse(keyword: keyword)
    }

    /// Parses any self-describing name like `custom_4x6in_4x6in` or `om_x_50x30mm`.
    public static func parse(keyword: String) -> LabelMedia? {
        guard let last = keyword.split(separator: "_").last else { return nil }
        let unit: Double
        var dims = Substring(last)
        if dims.hasSuffix("in") { unit = 2540; dims = dims.dropLast(2) }
        else if dims.hasSuffix("mm") { unit = 100; dims = dims.dropLast(2) }
        else { return nil }
        let parts = dims.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return LabelMedia(
            keyword: keyword, displayName: keyword,
            width: Int((parts[0] * unit).rounded()), height: Int((parts[1] * unit).rounded())
        )
    }

    /// Size from an IPP `media-col` collection's `media-size` member.
    public static func from(mediaCol: [IPPAttribute]) -> LabelMedia? {
        guard let size = mediaCol.first(where: { $0.name == "media-size" })?.values.first?.collectionValue,
              let w = size.first(where: { $0.name == "x-dimension" })?.values.first?.intValue,
              let h = size.first(where: { $0.name == "y-dimension" })?.values.first?.intValue,
              w > 0, h > 0
        else { return nil }
        if let known = catalog.first(where: { $0.width == w && $0.height == h }) { return known }
        return LabelMedia(keyword: "custom_\(w)x\(h)", displayName: "Custom", width: w, height: h)
    }
}
