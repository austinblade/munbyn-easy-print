import PrintCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PrintingSettings().tabItem { Label("Printing", systemImage: "printer") }
            ConnectionSettings().tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PrintingSettings: View {
    @AppStorage(SettingsKey.defaultMedia) private var defaultMedia = LabelMedia.default.keyword
    @AppStorage(SettingsKey.overrideDensity) private var overrideDensity = false
    @AppStorage(SettingsKey.density) private var density = 8
    @AppStorage(SettingsKey.speed) private var speed = 0
    @AppStorage(SettingsKey.dither) private var dither = true
    @AppStorage(SettingsKey.paper) private var paper = PaperType.gap.rawValue
    @AppStorage(SettingsKey.gapMM) private var gapMM = 3.0
    @AppStorage(SettingsKey.flip) private var flip = false
    @AppStorage(SettingsKey.offsetX) private var offsetX = 0
    @AppStorage(SettingsKey.offsetY) private var offsetY = 0

    var body: some View {
        Form {
            Section {
                Picker("Default label size", selection: $defaultMedia) {
                    ForEach(LabelMedia.catalog) { Text($0.displayName).tag($0.keyword) }
                }
                Picker("Label stock", selection: $paper) {
                    ForEach(PaperType.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                if paper != PaperType.continuous.rawValue {
                    LabeledContent(paper == PaperType.gap.rawValue ? "Gap between labels" : "Mark height") {
                        Stepper(value: $gapMM, in: 0...10, step: 0.5) { Text(String(format: "%.1f mm", gapMM)).monospacedDigit() }
                    }
                }
            } footer: {
                Text("The default size applies to the test label and to images. PDFs print at the size chosen in the Print dialog.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Quality") {
                Toggle("Override darkness", isOn: $overrideDensity)
                if overrideDensity {
                    LabeledContent("Darkness") {
                        HStack {
                            Slider(value: Binding(get: { Double(density) }, set: { density = Int($0) }), in: 0...15, step: 1)
                            Text("\(density)").monospacedDigit().frame(width: 24, alignment: .trailing)
                        }
                    }
                }
                Picker("Speed", selection: $speed) {
                    Text("Printer default").tag(0)
                    ForEach(2...6, id: \.self) { Text("\($0) in/s").tag($0) }
                }
                Toggle("Dither photos and gray areas", isOn: $dither)
            }

            Section("Position") {
                Toggle("Rotate output 180°", isOn: $flip)
                LabeledContent("Horizontal offset") {
                    Stepper(value: $offsetX, in: -300...300, step: 6) { Text("\(offsetX) dots").monospacedDigit() }
                }
                LabeledContent("Vertical offset") {
                    Stepper(value: $offsetY, in: -300...300, step: 6) { Text("\(offsetY) dots").monospacedDigit() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.dialect) private var dialect = TSPLDialect.standard.rawValue
    @AppStorage(SettingsKey.keepConnected) private var keepConnected = false
    @AppStorage(SettingsKey.dpi) private var dpi = 300
    @AppStorage(SettingsKey.maxWidthDots) private var maxWidthDots = 1280

    var body: some View {
        Form {
            Section {
                Picker("Command dialect", selection: $dialect) {
                    ForEach(TSPLDialect.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Resolution", selection: $dpi) {
                    Text("300 dpi (941BP)").tag(300)
                    Text("203 dpi").tag(203)
                }
                LabeledContent("Print head width") {
                    Stepper(value: $maxWidthDots, in: 384...1600, step: 8) {
                        Text("\(maxWidthDots) dots (\(String(format: "%.2f", Double(maxWidthDots) / Double(dpi)))\")").monospacedDigit()
                    }
                }
            } header: {
                Text("Protocol")
            } footer: {
                Text("The 941BP speaks Standard TSPL II. The Aimo/LabeLife dialects are for other Munbyn models; on the 941BP they print blank labels.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bluetooth") {
                Toggle("Stay connected between jobs", isOn: $keepConnected)
                if let link = model.printer.link {
                    LabeledContent("Address", value: link.address)
                    LabeledContent("Service", value: "\(link.service) · RFCOMM channel \(link.channel)")
                    LabeledContent("Packet size", value: "\(link.mtu) B")
                }
                if model.printer.savedName != nil {
                    Button("Forget printer", role: .destructive) { model.printer.forget() }
                }
            }

            Section("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.printer.log.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .onChange(of: model.printer.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.simulate) private var simulate = false
    @AppStorage(SettingsKey.saveJobs) private var saveJobs = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("macOS can only print to the 941BP while Munbyn Easy Print is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("macOS printer queue") {
                LabeledContent("Queue", value: CUPSQueue.name)
                LabeledContent("Device URI", value: IPPPrinterService.printerURI)
                HStack {
                    if model.queueInstalled == true {
                        Button("Re-create queue") { Task { await model.reinstallQueue() } }
                        Button("Remove from macOS", role: .destructive) { Task { await model.removeQueue() } }
                    } else {
                        Button("Add to macOS") { Task { await model.installQueue() } }
                    }
                    if model.queueBusy { ProgressView().controlSize(.small) }
                }
                .disabled(model.queueBusy)
                Text("Re-create the queue after changing resolution so the Print dialog picks up the new settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Troubleshooting") {
                Toggle("Simulate printer (render only, don't send)", isOn: $simulate)
                Toggle("Save TSPL and preview of every job", isOn: $saveJobs)
                Button("Show job files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([PrintSettings.jobsDirectory])
                }
            }
        }
        .formStyle(.grouped)
    }
}
