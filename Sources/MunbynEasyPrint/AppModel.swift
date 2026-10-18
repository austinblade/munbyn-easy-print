import AppKit
import Foundation
import Network
import Observation
import PrintCore
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class AppModel {
    enum ServerState: Equatable {
        case starting, listening, failed(String)
    }

    let printer: BluetoothPrinter
    let processor: JobProcessor

    private(set) var jobs: [PrintJob] = []
    private(set) var serverState: ServerState = .starting
    private(set) var queueInstalled: Bool?
    private(set) var queueBusy = false
    private(set) var queueError: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let store = JobStore()
    @ObservationIgnored private let service: IPPPrinterService
    @ObservationIgnored private var server: HTTPServer?

    /// `demo` skips the IPP server, Bluetooth and notifications; see `loadDemoState()`.
    init(demo: Bool = false) {
        PrintSettings.registerDefaults()
        service = IPPPrinterService(store: store)
        printer = BluetoothPrinter(demo: demo)
        processor = JobProcessor(store: store, printer: printer)

        store.onChange = { [weak self] in self?.refreshJobs() }
        service.onSubmit = { [weak self] submission in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processor.submit(submission) } }
        }
        guard !demo else { return }
        startServer()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var activeJob: PrintJob? { jobs.first { $0.state == .processing } }

    var menuBarSymbol: String {
        if activeJob != nil { return "printer.fill" }
        if case .failed = serverState { return "exclamationmark.triangle" }
        return "printer"
    }

    // MARK: - IPP server & CUPS queue

    private func startServer() {
        let service = self.service
        let server = HTTPServer(port: IPPPrinterService.port) { service.handle($0) }
        do {
            try server.start { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.serverStateChanged(state) }
                }
            }
            self.server = server
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    private func serverStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            serverState = .listening
            Task { await firstRunSetup() }
        case .failed(let error):
            serverState = .failed("Port \(IPPPrinterService.port): \(error.localizedDescription)")
        default:
            break
        }
    }

    private func firstRunSetup() async {
        await refreshQueue()
        let defaults = UserDefaults.standard
        if queueInstalled == false, !defaults.bool(forKey: SettingsKey.queueDeclined) {
            await installQueue()
        }
        if !defaults.bool(forKey: SettingsKey.didFirstLaunch) {
            defaults.set(true, forKey: SettingsKey.didFirstLaunch)
            setLaunchAtLogin(true)
        }
    }

    func refreshQueue() async {
        queueInstalled = await CUPSQueue.isInstalled()
    }

    func installQueue() async {
        queueBusy = true
        queueError = nil
        defer { queueBusy = false }
        do {
            try await CUPSQueue.install()
            UserDefaults.standard.set(false, forKey: SettingsKey.queueDeclined)
        } catch {
            queueError = error.localizedDescription
        }
        await refreshQueue()
    }

    func removeQueue() async {
        queueBusy = true
        queueError = nil
        defer { queueBusy = false }
        do {
            try await CUPSQueue.remove()
            UserDefaults.standard.set(true, forKey: SettingsKey.queueDeclined)
        } catch {
            queueError = error.localizedDescription
        }
        await refreshQueue()
    }

    /// Re-creating the queue regenerates the PPD (e.g. after a DPI change).
    func reinstallQueue() async {
        if queueInstalled == true { try? await CUPSQueue.remove() }
        await installQueue()
    }

    // MARK: - Jobs

    private func refreshJobs() {
        jobs = store.all()
    }

    func printTestLabel() {
        let settings = PrintSettings.current
        guard let image = TestLabel.make(media: settings.defaultMedia, dpi: settings.tspl.dpi, printerName: printer.savedName) else { return }
        let job = store.create(name: "Test label", user: NSUserName())
        processor.submit(JobSubmission(jobID: job.id, source: .image(image, settings.defaultMedia)))
    }

    /// Has the printer measure the loaded labels so each print starts at the
    /// top of a label (what the Munbyn app's calibration does).
    func calibratePaper() {
        let settings = PrintSettings.current
        let size = settings.defaultMedia.sizePoints
        let bytes = TSPLEncoder.calibration(widthMM: size.width / 72 * 25.4, heightMM: size.height / 72 * 25.4, options: settings.tspl)
        let job = store.create(name: "Paper calibration", user: NSUserName())
        processor.submit(JobSubmission(jobID: job.id, source: .raw(bytes, summary: "Calibrated for \(settings.defaultMedia.displayName) labels")))
    }

    func cancel(_ job: PrintJob) {
        _ = store.cancel(job.id)
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

#if DEBUG
extension AppModel {
    /// Sample state for `--render-screenshots`.
    func loadDemoState() {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        serverState = .listening
        queueInstalled = true
        launchAtLogin = true
        jobs = [
            PrintJob(id: 5, name: "USPS Priority Mail label.pdf", user: "demo", state: .processing,
                     message: "Sending 69 KB…", created: ago(0.2), processingAt: ago(0.1), progress: 0.62),
            PrintJob(id: 4, name: "Order #1042 packing slip.pdf", user: "demo", state: .completed,
                     message: "1 label · 4.00×6.00 in", created: ago(12), completedAt: ago(12), pages: 1),
            PrintJob(id: 3, name: "Pantry jar labels", user: "demo", state: .completed,
                     message: "6 labels · 2.25×1.25 in", created: ago(48), completedAt: ago(47), pages: 6),
            PrintJob(id: 2, name: "Test label", user: "demo", state: .completed,
                     message: "1 label · 4.00×6.00 in", created: ago(95), completedAt: ago(95), pages: 1),
        ]
        printer.loadDemoState()
        if let image = TestLabel.make(media: .default, dpi: 300, printerName: printer.savedName) {
            processor.loadDemoPreview(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                                      info: "Test label — 1 label · 4.00×6.00 in")
        }
    }
}
#endif
