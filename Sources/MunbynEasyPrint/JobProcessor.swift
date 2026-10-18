import AppKit
import Foundation
import Observation
import PrintCore
import UserNotifications

/// Serially renders queued jobs to TSPL and streams them over Bluetooth.
@MainActor @Observable
final class JobProcessor {
    private(set) var lastPreview: NSImage?
    private(set) var lastPreviewInfo = ""

    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private let printer: BluetoothPrinter
    @ObservationIgnored private var queue: [JobSubmission] = []
    @ObservationIgnored private var draining = false

    init(store: JobStore, printer: BluetoothPrinter) {
        self.store = store
        self.printer = printer
    }

    func submit(_ job: JobSubmission) {
        queue.append(job)
        guard !draining else { return }
        draining = true
        Task {
            while !queue.isEmpty { await process(queue.removeFirst()) }
            draining = false
            printer.scheduleIdleDisconnect()
        }
    }

    private struct Rendered: @unchecked Sendable {
        var bytes: [UInt8]
        var pages: Int
        var preview: CGImage?
        var summary: String
    }

    private func process(_ submission: JobSubmission) async {
        let id = submission.jobID
        guard let job = store.get(id), job.state != .canceled else { return }
        store.update(id) { $0.state = .processing; $0.message = "Rendering…"; $0.progress = 0 }

        let settings = PrintSettings.current
        let ticket = store.ticket(id)

        do {
            let rendered = try await Task.detached(priority: .userInitiated) {
                try Self.render(submission, ticket: ticket, settings: settings)
            }.value

            if let preview = rendered.preview {
                lastPreview = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
                lastPreviewInfo = "\(job.name) — \(rendered.summary)"
            }
            if settings.saveJobs { save(rendered, jobID: id) }
            store.update(id) { $0.pages = rendered.pages }

            if settings.simulate {
                store.update(id) { $0.state = .completed; $0.progress = 1; $0.message = "Simulated · \(rendered.summary)" }
                return
            }

            try await deliver(rendered, jobID: id, jobName: job.name)
        } catch is CancellationError {
            store.update(id) { $0.message = "Canceled" }
        } catch {
            let message = error.localizedDescription
            store.update(id) { if !$0.state.isTerminal { $0.state = .aborted }; $0.message = message }
            notify(title: "Couldn't print “\(job.name)”", body: message)
        }
    }

    /// Waits as long as it takes for the printer (macOS keeps showing the job
    /// as printing), and resends from scratch if the link drops mid-job.
    private func deliver(_ rendered: Rendered, jobID id: Int, jobName: String) async throws {
        var notified = false
        var attempts = 0
        defer { store.waitingReason = nil }
        while true {
            guard store.get(id)?.state == .processing else { throw CancellationError() }
            do {
                store.update(id) { $0.message = "Connecting to printer…"; $0.progress = 0 }
                try await printer.ensureReady(timeout: 20)
                store.waitingReason = nil
                store.update(id) { $0.message = "Sending \(rendered.bytes.count / 1024) KB…" }
                let store = self.store
                try await printer.send(
                    rendered.bytes,
                    progress: { p in store.update(id) { $0.progress = p } }
                )
                store.update(id) { $0.state = .completed; $0.progress = 1; $0.message = rendered.summary }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PrinterError where error.isRecoverable {
                attempts += 1
                let reason = error.localizedDescription
                store.waitingReason = reason
                store.update(id) { $0.message = "Waiting for printer — \(reason)" }
                if !notified {
                    notified = true
                    notify(title: "“\(jobName)” is waiting for the printer", body: "\(reason) It will print automatically.")
                }
                try await Task.sleep(for: .seconds(attempts < 3 ? 3 : 10))
            }
        }
    }

    nonisolated private static func render(_ s: JobSubmission, ticket: JobTicket, settings: PrintSettings) throws -> Rendered {
        let labels: [RenderedLabel]
        switch s.source {
        case .document(let data, let mimeType):
            guard let format = DocumentFormat.resolve(mimeType: mimeType, data: data) else {
                throw DecodeError.unsupportedFormat(mimeType ?? "unknown")
            }
            let fallback = (ticket.media ?? settings.defaultMedia).sizePoints
            labels = try DocumentDecoder.render(data: data, format: format, fallbackLabelSize: fallback, options: settings.raster)
        case .image(let image, let media):
            labels = [Rasterizer.render(image: image, labelSize: media.sizePoints, options: settings.raster)]
        case .raw(let bytes, let summary):
            return Rendered(bytes: bytes, pages: 0, preview: nil, summary: summary)
        }
        guard let first = labels.first else { throw DecodeError.malformed("document has no pages") }

        var tspl = settings.tspl
        tspl.copies = ticket.copies
        let bytes = labels.flatMap { TSPLEncoder.encode($0.bitmap, options: tspl) }

        let dpi = Double(settings.tspl.dpi)
        let size = String(format: "%.2f×%.2f in", Double(first.bitmap.width) / dpi, Double(first.bitmap.height) / dpi)
        var summary = "\(labels.count) label\(labels.count == 1 ? "" : "s") · \(size)"
        if ticket.copies > 1 { summary += " · ×\(ticket.copies)" }
        if first.rotated { summary += " · rotated" }
        return Rendered(bytes: bytes, pages: labels.count, preview: Rasterizer.previewImage(first.bitmap), summary: summary)
    }

    private func save(_ r: Rendered, jobID: Int) {
        let dir = PrintSettings.jobsDirectory
        try? Data(r.bytes).write(to: dir.appendingPathComponent("job-\(jobID).tspl"))
        if let preview = r.preview {
            let rep = NSBitmapImageRep(cgImage: preview)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("job-\(jobID).png"))
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

#if DEBUG
extension JobProcessor {
    /// Sample state for `--render-screenshots`.
    func loadDemoPreview(_ image: NSImage, info: String) {
        lastPreview = image
        lastPreviewInfo = info
    }
}
#endif
