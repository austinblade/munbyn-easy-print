import CoreBluetooth
import Foundation
import IOBluetooth
import Observation

enum PrinterError: LocalizedError {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothNotReady
    case noPrinterSelected
    case timedOut
    case connectFailed(String)
    case disconnected
    case stalled
    case writeFailed(String)

    /// Every transport error is worth waiting on: the printer may be
    /// switched on, brought into range, or chosen later.
    var isRecoverable: Bool { true }

    var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "Bluetooth is turned off."
        case .bluetoothNotReady: return "Bluetooth isn't ready. If macOS is asking for Bluetooth permission, click Allow."
        case .bluetoothUnauthorized: return "Bluetooth access is off for Munbyn Easy Print. Allow it in System Settings › Privacy & Security › Bluetooth."
        case .noPrinterSelected: return "No printer selected. Choose one from the menu bar."
        case .timedOut: return "The printer didn't respond. Is it on and nearby?"
        case .connectFailed(let why): return "Couldn't connect to the printer (\(why))."
        case .disconnected: return "The printer disconnected mid-job."
        case .stalled: return "The printer stopped accepting data. If this keeps happening, turn it off and on."
        case .writeFailed(let why): return "Bluetooth write failed (\(why))."
        }
    }
}

/// Classic Bluetooth (RFCOMM / Serial Port Profile) transport. The 941BP
/// exposes "SPP Dev" on RFCOMM and doesn't advertise over BLE. Connects on
/// demand and streams jobs with a small window of async writes.
@MainActor @Observable
final class BluetoothPrinter: NSObject {
    enum Status: Equatable {
        case starting
        case bluetoothOff
        case unauthorized
        case notSelected
        case idle
        case connecting
        case ready
        case sending
    }

    struct Discovered: Identifiable {
        /// Bluetooth address, e.g. `00-11-22-33-44-55`.
        let id: String
        var name: String
        var rssi: Int?
        var paired: Bool
        var looksLikePrinter: Bool
    }

    struct Link: Equatable {
        var address: String
        var service: String
        var channel: Int
        var mtu: Int
    }

    private(set) var status: Status = .starting
    private(set) var discovered: [Discovered] = []
    private(set) var isScanning = false
    private(set) var link: Link?
    private(set) var log: [String] = []
    private(set) var savedName: String? = UserDefaults.standard.string(forKey: SettingsKey.printerName)
    private(set) var savedID: String? = UserDefaults.standard.string(forKey: SettingsKey.printerID)

    /// Only used for the power/permission state: unlike IOBluetooth it never
    /// blocks, and IOBluetooth calls made before Bluetooth access is granted
    /// hang the calling thread.
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var poweredOnWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var device: IOBluetoothDevice?
    @ObservationIgnored private var channel: IOBluetoothRFCOMMChannel?
    @ObservationIgnored private var inquiry: IOBluetoothDeviceInquiry?
    @ObservationIgnored private var connecting: Task<Void, Error>?
    @ObservationIgnored private var connectWaiter: CheckedContinuation<IOReturn, Never>?
    @ObservationIgnored private var sdpWaiter: CheckedContinuation<IOReturn, Never>?
    @ObservationIgnored private var openWaiter: CheckedContinuation<IOReturn, Never>?
    @ObservationIgnored private var writeWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var writeError: Error?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var rx = Data()

    /// Writes queued in the controller at once; each is at most one RFCOMM MTU.
    private static let window = 8

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    /// Lists paired devices immediately, then runs a ~10 s inquiry for
    /// discoverable ones nearby.
    func startScan() {
        guard isPoweredOn else { refreshIdleStatus(); return }
        stopScan()
        discovered = []
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] { remember(d, rssi: nil) }
        let inquiry = IOBluetoothDeviceInquiry(delegate: self)!
        inquiry.inquiryLength = 10
        inquiry.updateNewDeviceNames = true
        if inquiry.start() == kIOReturnSuccess {
            self.inquiry = inquiry
            isScanning = true
        }
    }

    func stopScan() {
        inquiry?.stop()
        inquiry = nil
        isScanning = false
    }

    func select(_ device: Discovered) {
        stopScan()
        if device.id != savedID { disconnect() }
        save(id: device.id, name: device.name)
        refreshIdleStatus()
        Task { try? await ensureReady(timeout: 20) }
    }

    func forget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: SettingsKey.printerID)
        UserDefaults.standard.removeObject(forKey: SettingsKey.printerName)
        savedID = nil
        savedName = nil
        device = nil
        refreshIdleStatus()
    }

    func disconnect() {
        idleTask?.cancel()
        channel?.close()
        channel = nil
        link = nil
        if isPoweredOn { device?.closeConnection() }
        refreshIdleStatus()
    }

    /// Connect (if needed) and open the printer's serial port channel.
    func ensureReady(timeout: TimeInterval) async throws {
        idleTask?.cancel()
        if let channel, channel.isOpen() { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await connect(timeout: timeout) }
        connecting = task
        defer { connecting = nil }
        do {
            try await task.value
        } catch {
            refreshIdleStatus()
            throw error
        }
    }

    /// Sends a whole job. Deliberately not cancellable once started: a job
    /// cut off inside a `BITMAP` leaves the printer waiting for raster bytes
    /// and it stops accepting data until it's power cycled.
    func send(_ bytes: [UInt8], progress: @escaping (Double) -> Void) async throws {
        guard let channel, channel.isOpen() else { throw PrinterError.disconnected }
        idleTask?.cancel()
        status = .sending
        defer { if status == .sending { status = .ready } }
        do {
            try await stream(bytes, over: channel, progress: progress)
        } catch {
            log("Send failed: \(error.localizedDescription)")
            disconnect()
            throw error
        }
    }

    private func stream(_ bytes: [UInt8], over channel: IOBluetoothRFCOMMChannel, progress: @escaping (Double) -> Void) async throws {

        let mtu = max(32, Int(channel.getMTU()))
        log("Sending \(bytes.count) bytes in \(mtu)-byte packets")
        let started = Date()
        writeError = nil
        var offset = 0
        var lastReport = 0
        while offset < bytes.count {
            if let writeError { throw writeError }
            while inFlight >= Self.window { try await waitForWrite() }
            guard channel.isOpen() else { throw PrinterError.disconnected }

            let end = min(offset + mtu, bytes.count)
            let count = end - offset
            // IOBluetooth holds on to the buffer until the write completes;
            // it's freed in rfcommChannelWriteComplete.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: count) }
            // Counted first: the completion can arrive before writeAsync returns.
            inFlight += 1
            let rc = channel.writeAsync(buffer, length: UInt16(count), refcon: buffer)
            guard rc == kIOReturnSuccess else {
                inFlight -= 1
                buffer.deallocate()
                throw PrinterError.writeFailed(Self.describe(rc))
            }
            offset = end
            if offset - lastReport >= 4096 || offset == bytes.count {
                lastReport = offset
                progress(Double(offset) / Double(bytes.count))
            }
        }
        try await drain()
        let secs = Date().timeIntervalSince(started)
        log(String(format: "Sent in %.1fs (%.1f KB/s)", secs, Double(bytes.count) / 1024 / max(secs, 0.001)))
    }

    /// Drop the link after a quiet period so phones can still reach the printer.
    func scheduleIdleDisconnect() {
        idleTask?.cancel()
        guard !UserDefaults.standard.bool(forKey: SettingsKey.keepConnected) else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, self.status == .ready else { return }
            self.log("Idle — disconnecting")
            self.disconnect()
        }
    }

    // MARK: - Connection

    private var isPoweredOn: Bool { central.state == .poweredOn }

    private func waitForPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw PrinterError.bluetoothUnauthorized
        case .poweredOff, .unsupported: throw PrinterError.bluetoothOff
        default: break
        }
        let key = UUID()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            poweredOnWaiters[key] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.poweredOnWaiters.removeValue(forKey: key)?.resume(throwing: PrinterError.bluetoothNotReady)
            }
        }
    }

    private func connect(timeout: TimeInterval) async throws {
        try await waitForPoweredOn()
        if savedID == nil { adoptPairedPrinter() }
        guard let id = savedID, let device = IOBluetoothDevice(addressString: id) else { throw PrinterError.noPrinterSelected }
        self.device = device
        status = .connecting

        if !device.isConnected() {
            log("Connecting to \(savedName ?? id)…")
            // Page timeout is in 0.625 ms slots.
            let slots = BluetoothHCIPageTimeout(min(0xFFFF, max(0x2000, timeout * 1600)))
            let rc = await withCheckedContinuation { (c: CheckedContinuation<IOReturn, Never>) in
                connectWaiter = c
                let started = device.openConnection(self, withPageTimeout: slots, authenticationRequired: false)
                if started != kIOReturnSuccess { connectWaiter = nil; c.resume(returning: started) }
            }
            guard rc == kIOReturnSuccess else {
                log("Connect failed: \(Self.describe(rc))")
                throw rc == kIOReturnTimeout ? PrinterError.timedOut : PrinterError.connectFailed(Self.describe(rc))
            }
        }

        var (service, channelID) = serialPort(of: device)
        if service == nil {
            log("Looking up services…")
            let rc = await withCheckedContinuation { (c: CheckedContinuation<IOReturn, Never>) in
                sdpWaiter = c
                let started = device.performSDPQuery(self)
                if started != kIOReturnSuccess { sdpWaiter = nil; c.resume(returning: started) }
            }
            if rc == kIOReturnSuccess { (service, channelID) = serialPort(of: device) }
        }

        var opened: IOBluetoothRFCOMMChannel?
        let rc = await withCheckedContinuation { (c: CheckedContinuation<IOReturn, Never>) in
            openWaiter = c
            let started = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
            if started != kIOReturnSuccess { openWaiter = nil; c.resume(returning: started) }
        }
        guard rc == kIOReturnSuccess, let opened, opened.isOpen() else {
            log("Opening RFCOMM channel \(channelID) failed: \(Self.describe(rc))")
            opened?.close()
            throw PrinterError.connectFailed(Self.describe(rc))
        }
        channel = opened
        if let name = device.name, name != savedName { save(id: id, name: name) }
        link = Link(address: id, service: service ?? "RFCOMM", channel: Int(channelID), mtu: Int(opened.getMTU()))
        log("Connected — \(service ?? "RFCOMM") on channel \(channelID), MTU \(opened.getMTU())")
        status = .ready
    }

    /// The SPP record's RFCOMM channel, falling back to channel 1.
    private func serialPort(of device: IOBluetoothDevice) -> (String?, BluetoothRFCOMMChannelID) {
        let serialPort = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassSerialPort.rawValue))
        var fallback: (String?, BluetoothRFCOMMChannelID)?
        for case let record as IOBluetoothSDPServiceRecord in device.services ?? [] {
            var ch: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&ch) == kIOReturnSuccess else { continue }
            let name = record.getServiceName()
            if record.hasService(from: [serialPort as Any]) || name?.localizedCaseInsensitiveContains("SPP") == true {
                return (name ?? "Serial Port", ch)
            }
            if fallback == nil { fallback = (name ?? "RFCOMM", ch) }
        }
        return fallback ?? (nil, 1)
    }

    /// Picks the paired 941BP (it pairs as `ITPP941BP-xxxx`) when none is chosen.
    private func adoptPairedPrinter() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let match = paired.first(where: { Self.looksLikePrinter($0) }), let address = match.addressString else { return }
        save(id: address, name: match.name ?? address)
        log("Using paired printer \(match.name ?? address)")
    }

    private func save(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: SettingsKey.printerID)
        UserDefaults.standard.set(name, forKey: SettingsKey.printerName)
        savedID = id
        savedName = name
    }

    private static func looksLikePrinter(_ d: IOBluetoothDevice) -> Bool {
        let name = (d.name ?? "").lowercased()
        if ["itpp", "941", "munbyn"].contains(where: name.contains) { return true }
        // Class of Device: major class Imaging (6), minor "printer" bit.
        return d.deviceClassMajor == kBluetoothDeviceClassMajorImaging && d.deviceClassMinor & 0x20 != 0
    }

    private func remember(_ d: IOBluetoothDevice, rssi: Int?) {
        guard let address = d.addressString else { return }
        let name = d.name ?? address
        if let i = discovered.firstIndex(where: { $0.id == address }) {
            discovered[i].name = name
            if let rssi { discovered[i].rssi = rssi }
        } else {
            discovered.append(Discovered(id: address, name: name, rssi: rssi, paired: d.isPaired(), looksLikePrinter: Self.looksLikePrinter(d)))
        }
        discovered.sort { a, b in
            let ka = (a.looksLikePrinter ? 2 : 0) + (a.paired ? 1 : 0), kb = (b.looksLikePrinter ? 2 : 0) + (b.paired ? 1 : 0)
            return ka != kb ? ka > kb : (a.rssi ?? -127) > (b.rssi ?? -127)
        }
    }

    // MARK: - Writes

    /// Waits for one write completion; fails if the printer stops draining.
    private func waitForWrite() async throws {
        writeGeneration += 1
        let generation = writeGeneration
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeWaiter = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.writeGeneration == generation, let w = self.writeWaiter else { return }
                self.writeWaiter = nil
                w.resume(throwing: PrinterError.stalled)
            }
        }
    }

    private func drain() async throws {
        while inFlight > 0 { try await waitForWrite() }
        if let writeError { throw writeError }
    }

    private func linkLost(_ error: Error) {
        channel = nil
        link = nil
        writeError = error
        inFlight = 0
        let w = writeWaiter
        writeWaiter = nil
        w?.resume(throwing: error)
        refreshIdleStatus()
    }

    // MARK: - Misc

    private func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        NSLog("Bluetooth: %@", line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func refreshIdleStatus() {
        switch central.state {
        case .poweredOn: break
        case .unauthorized: status = .unauthorized; return
        case .unknown, .resetting: status = .starting; return
        default: status = .bluetoothOff; return
        }
        if channel?.isOpen() == true { status = .ready }
        else { status = savedID == nil ? .notSelected : .idle }
    }

    private static func describe(_ rc: IOReturn) -> String {
        switch rc {
        case kIOReturnTimeout: return "no response — is the printer on and in range?"
        case kIOReturnNotPermitted, kIOReturnNotPrivileged: return "Bluetooth permission denied"
        case kIOReturnBusy: return "busy — another device may be connected to it"
        default: return String(format: "error 0x%08X", UInt32(bitPattern: rc))
        }
    }

    private func handleIncoming(_ data: Data) {
        rx.append(data)
        while let nl = rx.firstIndex(of: 0x0A) {
            let lineData = rx[rx.startIndex...nl]
            rx.removeSubrange(rx.startIndex...nl)
            let text = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { log("Printer: \(text)") }
        }
        if rx.count > 64 {
            log("Printer: \(rx.map { String(format: "%02x", $0) }.joined(separator: " "))")
            rx.removeAll()
        }
    }
}

// MARK: - Bluetooth callbacks (delivered on the main run loop)

extension BluetoothPrinter: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                if savedID == nil { adoptPairedPrinter() }
                let waiters = poweredOnWaiters
                poweredOnWaiters.removeAll()
                waiters.values.forEach { $0.resume() }
                if UserDefaults.standard.bool(forKey: SettingsKey.keepConnected), savedID != nil {
                    Task { try? await ensureReady(timeout: 30) }
                }
            } else if central.state != .unknown, central.state != .resetting {
                let error: PrinterError = central.state == .unauthorized ? .bluetoothUnauthorized : .bluetoothOff
                let waiters = poweredOnWaiters
                poweredOnWaiters.removeAll()
                waiters.values.forEach { $0.resume(throwing: error) }
                if channel != nil { linkLost(error) }
            }
            refreshIdleStatus()
        }
    }
}

extension BluetoothPrinter: IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceInquiryDelegate {
    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated {
            let c = connectWaiter
            connectWaiter = nil
            c?.resume(returning: status)
        }
    }

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated {
            let c = sdpWaiter
            sdpWaiter = nil
            c?.resume(returning: status)
        }
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated {
            let c = openWaiter
            openWaiter = nil
            c?.resume(returning: error)
        }
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        MainActor.assumeIsolated {
            refcon?.deallocate()
            if inFlight > 0 { inFlight -= 1 }
            if error != kIOReturnSuccess, writeError == nil { writeError = PrinterError.writeFailed(Self.describe(error)) }
            let w = writeWaiter
            writeWaiter = nil
            w?.resume()
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let data = Data(bytes: dataPointer, count: dataLength)
        MainActor.assumeIsolated { handleIncoming(data) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            guard rfcommChannel === channel else { return }
            log("Disconnected")
            linkLost(PrinterError.disconnected)
        }
    }

    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        MainActor.assumeIsolated { remember(device, rssi: Int(device.rawRSSI())) }
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        MainActor.assumeIsolated { remember(device, rssi: nil) }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        MainActor.assumeIsolated {
            guard sender === inquiry else { return }
            inquiry = nil
            isScanning = false
        }
    }
}
