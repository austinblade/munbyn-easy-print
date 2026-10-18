import PrintCore
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            printerSection
            Divider()
            queueSection
            if let preview = model.processor.lastPreview {
                Divider()
                previewSection(preview)
            }
            Divider()
            jobsSection
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "printer.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Munbyn Easy Print").font(.headline)
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var headerSubtitle: String {
        if let job = model.activeJob { return "Printing “\(job.name)”" }
        if case .failed(let why) = model.serverState { return why }
        return model.printer.savedName.map { "\($0) · \(statusText)" } ?? "No printer selected"
    }

    private var printerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Bluetooth printer")
            HStack {
                StatusDot(color: statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.printer.savedName ?? "None selected").font(.body.weight(.medium))
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.printer.savedName != nil {
                    if model.printer.status == .ready {
                        Button("Disconnect") { model.printer.disconnect() }.controlSize(.small)
                    } else if model.printer.status == .idle {
                        Button("Connect") { Task { try? await model.printer.ensureReady(timeout: 20) } }.controlSize(.small)
                    }
                }
            }
            Button {
                choosing.toggle()
                if choosing { model.printer.startScan() } else { model.printer.stopScan() }
            } label: {
                Label(choosing ? "Done" : (model.printer.savedName == nil ? "Find printer…" : "Change printer…"),
                      systemImage: choosing ? "checkmark" : "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.link)
            .font(.caption)

            if choosing { picker }
        }
        .padding(14)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.printer.isScanning ? "Scanning…" : "Bluetooth devices").font(.caption).foregroundStyle(.secondary)
                if model.printer.isScanning { ProgressView().controlSize(.mini) }
                Spacer()
                if !model.printer.isScanning {
                    Button("Rescan") { model.printer.startScan() }.buttonStyle(.link).font(.caption)
                }
            }
            if model.printer.discovered.isEmpty {
                Text("Turn the printer on. It should appear here within about 10 seconds.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.printer.discovered) { device in
                        Button {
                            model.printer.select(device)
                            choosing = false
                        } label: {
                            HStack {
                                Image(systemName: device.looksLikePrinter ? "printer" : "dot.radiowaves.left.and.right")
                                    .frame(width: 18)
                                Text(device.name).lineLimit(1)
                                Spacer()
                                if device.id == model.printer.savedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                if let rssi = device.rssi { SignalBars(rssi: rssi) } else if device.paired { Text("Paired").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 5)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        .background(device.looksLikePrinter ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .frame(maxHeight: 160)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("macOS printer")
            HStack {
                switch model.queueInstalled {
                case .some(true):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(CUPSQueue.displayName)” is installed")
                        Text("Pick it in any app's Print dialog (⌘P)").font(.caption).foregroundStyle(.secondary)
                    }
                case .some(false):
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                    Text("Not added to macOS yet")
                case .none:
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                }
                Spacer()
                if model.queueBusy {
                    ProgressView().controlSize(.small)
                } else if model.queueInstalled == false {
                    Button("Add") { Task { await model.installQueue() } }
                        .controlSize(.small)
                        .disabled(model.serverState != .listening)
                }
            }
            if let error = model.queueError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(14)
    }

    private func previewSection(_ image: NSImage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 80)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.separator))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Last label")
                Text(model.processor.lastPreviewInfo).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
        }
        .padding(14)
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Recent jobs")
            if model.jobs.isEmpty {
                Text("Nothing printed yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.jobs.prefix(5)) { job in
                JobRow(job: job) { model.cancel(job) }
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button {
                model.printTestLabel()
            } label: {
                Label("Test Label", systemImage: "doc.text.image")
            }
            Button {
                model.calibratePaper()
            } label: {
                Label("Calibrate", systemImage: "ruler")
            }
            .help("Feeds a few labels so the printer learns where each label starts. Run it after loading a new roll.")
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit — macOS won't be able to print to the 941BP until you reopen the app")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Status

    private var statusText: String {
        switch model.printer.status {
        case .starting: return "Starting Bluetooth…"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission needed"
        case .notSelected: return "Choose your printer below"
        case .idle: return "Connects automatically when printing"
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .sending: return "Sending…"
        }
    }

    private var statusColor: Color {
        switch model.printer.status {
        case .ready, .sending: return .green
        case .connecting, .starting: return .orange
        case .idle: return .secondary
        default: return .red
        }
    }
}

private struct JobRow: View {
    let job: PrintJob
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 16)
                Text(job.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if job.state.isTerminal {
                    Text((job.completedAt ?? job.created).formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
                }
            }
            if job.state == .processing, job.progress > 0, job.progress < 1 {
                ProgressView(value: job.progress).controlSize(.small).padding(.leading, 22)
            }
            if !job.message.isEmpty {
                Text(job.message)
                    .font(.caption)
                    .foregroundStyle(job.state == .aborted ? .red : .secondary)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
        }
    }

    private var icon: String {
        switch job.state {
        case .completed: return "checkmark.circle.fill"
        case .aborted: return "exclamationmark.circle.fill"
        case .canceled: return "minus.circle.fill"
        case .processing: return "arrow.up.circle.fill"
        default: return "clock"
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .aborted: return .red
        case .processing: return .accentColor
        default: return .secondary
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.5)
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

private struct SignalBars: View {
    let rssi: Int
    var body: some View {
        let level = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.primary.opacity(0.7) : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .help("\(rssi) dBm")
    }
}
