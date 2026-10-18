import Foundation
import PrintCore

enum SettingsKey {
    static let dialect = "dialect"
    static let dpi = "dpi"
    static let maxWidthDots = "maxWidthDots"
    static let overrideDensity = "overrideDensity"
    static let density = "density"
    static let speed = "speed"
    static let paper = "paper"
    static let gapMM = "gapMM"
    static let dither = "dither"
    static let flip = "flip"
    static let offsetX = "offsetX"
    static let offsetY = "offsetY"
    static let keepConnected = "keepConnected"
    static let simulate = "simulate"
    static let saveJobs = "saveJobs"
    static let defaultMedia = "defaultMedia"
    static let printerID = "printerID"
    static let printerName = "printerName"
    static let printerUUID = "ippPrinterUUID"
    static let queueDeclined = "queueDeclined"
    static let didFirstLaunch = "didFirstLaunch"
}

/// Snapshot of user settings, safe to read from any thread.
struct PrintSettings {
    var tspl: TSPLOptions
    var raster: RasterOptions
    var simulate: Bool
    var saveJobs: Bool
    var defaultMedia: LabelMedia

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.dialect: TSPLDialect.standard.rawValue,
            SettingsKey.dpi: 300,
            SettingsKey.maxWidthDots: 1280,
            SettingsKey.overrideDensity: false,
            SettingsKey.density: 8,
            SettingsKey.speed: 0,
            SettingsKey.paper: PaperType.gap.rawValue,
            SettingsKey.gapMM: 3.0,
            SettingsKey.dither: true,
            SettingsKey.flip: false,
            SettingsKey.offsetX: 0,
            SettingsKey.offsetY: 0,
            SettingsKey.keepConnected: false,
            SettingsKey.simulate: false,
            SettingsKey.saveJobs: false,
            SettingsKey.defaultMedia: LabelMedia.default.keyword,
        ])
    }

    static var current: PrintSettings {
        let d = UserDefaults.standard
        var tspl = TSPLOptions()
        tspl.dialect = TSPLDialect(rawValue: d.string(forKey: SettingsKey.dialect) ?? "") ?? .standard
        tspl.dpi = d.integer(forKey: SettingsKey.dpi)
        tspl.density = d.bool(forKey: SettingsKey.overrideDensity) ? d.integer(forKey: SettingsKey.density) : nil
        let speed = d.integer(forKey: SettingsKey.speed)
        tspl.speed = speed > 0 ? speed : nil
        tspl.paper = PaperType(rawValue: d.string(forKey: SettingsKey.paper) ?? "") ?? .gap
        tspl.gapMM = d.double(forKey: SettingsKey.gapMM)
        tspl.flip = d.bool(forKey: SettingsKey.flip)
        tspl.originDots = (d.integer(forKey: SettingsKey.offsetX), d.integer(forKey: SettingsKey.offsetY))

        var raster = RasterOptions()
        raster.dpi = Double(tspl.dpi)
        raster.maxWidthDots = d.integer(forKey: SettingsKey.maxWidthDots)
        raster.dither = d.bool(forKey: SettingsKey.dither)

        return PrintSettings(
            tspl: tspl,
            raster: raster,
            simulate: d.bool(forKey: SettingsKey.simulate),
            saveJobs: d.bool(forKey: SettingsKey.saveJobs),
            defaultMedia: LabelMedia.find(keyword: d.string(forKey: SettingsKey.defaultMedia) ?? "") ?? .default
        )
    }

    /// ~/Library/Application Support/Munbyn Easy Print
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Munbyn Easy Print", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var jobsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
