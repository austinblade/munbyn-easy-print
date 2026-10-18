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

    let printer = BluetoothPrinter()
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

    init() {
        PrintSettings.registerDefaults()
        service = IPPPrinterService(store: store)
        processor = JobProcessor(store: store, printer: printer)

        store.onChange = { [weak self] in self?.refreshJobs() }
        service.onSubmit = { [weak self] submission in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processor.submit(submission) } }
        }
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
