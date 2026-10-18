import CoreGraphics
import Foundation
import PrintCore

/// A finished document, ready to rasterize and send.
struct JobSubmission: @unchecked Sendable {
    enum Source {
        case document(data: [UInt8], mimeType: String?)
        case image(CGImage, LabelMedia)
        /// Printer commands sent as-is (e.g. calibration).
        case raw([UInt8], summary: String)
    }

    var jobID: Int
    var source: Source
}

/// IPP Everywhere printer that CUPS talks to over loopback. Runs on the HTTP
/// server queue; hands completed documents to `onSubmit`.
final class IPPPrinterService: @unchecked Sendable {
    static let port: UInt16 = 8631
    static let resourcePath = "/ipp/print"
    static var printerURI: String { "ipp://127.0.0.1:\(port)\(resourcePath)" }

    let store: JobStore
    var onSubmit: (@Sendable (JobSubmission) -> Void)?

    private let uuid: String

    init(store: JobStore) {
        self.store = store
        if let saved = UserDefaults.standard.string(forKey: SettingsKey.printerUUID) {
            uuid = saved
        } else {
            uuid = UUID().uuidString.lowercased()
            UserDefaults.standard.set(uuid, forKey: SettingsKey.printerUUID)
        }
    }

    func handle(_ http: HTTPRequest) -> HTTPResponse {
        if http.method == "GET" {
            return statusPage()
        }
        guard http.method == "POST", http.path.hasPrefix("/ipp") else { return .notFound() }
        guard let request = try? IPPMessage.parse(http.body) else {
            return HTTPResponse(status: 400, reason: "Bad Request", contentType: "text/plain")
        }
        return HTTPResponse(body: dispatch(request).serialize())
    }

    private func dispatch(_ req: IPPMessage) -> IPPMessage {
        guard req.versionMajor == 1 || req.versionMajor == 2 else {
            return response(to: req, status: IPPStatus.serverVersionNotSupported)
        }
        switch req.code {
        case IPPOperation.getPrinterAttributes: return getPrinterAttributes(req)
        case IPPOperation.validateJob: return validateJob(req)
        case IPPOperation.printJob: return printJob(req)
        case IPPOperation.createJob: return createJob(req)
        case IPPOperation.sendDocument: return sendDocument(req)
        case IPPOperation.cancelJob: return cancelJob(req)
        case IPPOperation.getJobAttributes: return getJobAttributes(req)
        case IPPOperation.getJobs: return getJobs(req)
        case IPPOperation.closeJob: return closeJob(req)
        case IPPOperation.identifyPrinter: return response(to: req, status: IPPStatus.ok)
        default: return response(to: req, status: IPPStatus.serverOperationNotSupported)
        }
    }

    // MARK: - Operations

    private func validateJob(_ req: IPPMessage) -> IPPMessage {
        if let format = req.value("document-format")?.stringValue, !isSupported(format) {
            return response(to: req, status: IPPStatus.clientDocumentFormatNotSupported, message: "Unsupported format \(format)")
        }
        return response(to: req, status: IPPStatus.ok)
    }

    private func printJob(_ req: IPPMessage) -> IPPMessage {
        let format = req.value("document-format")?.stringValue
        if let format, !isSupported(format) {
            return response(to: req, status: IPPStatus.clientDocumentFormatNotSupported, message: "Unsupported format \(format)")
        }
        if let problem = Self.validate(req.data, mimeType: format) {
            return response(to: req, status: IPPStatus.clientDocumentFormatError, message: problem)
        }
        let job = store.create(name: jobName(req), user: userName(req), ticket: ticket(from: req))
        onSubmit?(JobSubmission(jobID: job.id, source: .document(data: req.data, mimeType: format)))
        return jobResponse(to: req, job: store.get(job.id) ?? job)
    }

    private func createJob(_ req: IPPMessage) -> IPPMessage {
        let job = store.create(name: jobName(req), user: userName(req), state: .held, ticket: ticket(from: req))
        return jobResponse(to: req, job: job)
    }

    private func sendDocument(_ req: IPPMessage) -> IPPMessage {
        guard let id = req.value("job-id")?.intValue, let job = store.get(id) else {
            return response(to: req, status: IPPStatus.clientNotFound, message: "No such job")
        }
        guard job.state == .held else {
            // A trailing empty last-document after the real one is harmless.
            if req.data.isEmpty { return jobResponse(to: req, job: job) }
            return response(to: req, status: IPPStatus.clientNotPossible, message: "Job is not accepting documents")
        }
        let format = req.value("document-format")?.stringValue
        if let format, !isSupported(format) {
            store.update(id) { $0.state = .aborted; $0.message = "Unsupported format \(format)" }
            return response(to: req, status: IPPStatus.clientDocumentFormatNotSupported)
        }
        if !req.data.isEmpty, let problem = Self.validate(req.data, mimeType: format) {
            store.update(id) { $0.state = .aborted; $0.message = problem }
            return response(to: req, status: IPPStatus.clientDocumentFormatError, message: problem)
        }
        // One document per job: a trailing empty "last-document" just closes it.
        if req.data.isEmpty {
            store.update(id) { $0.state = .completed; $0.message = "Empty document" }
        } else {
            store.update(id) { $0.state = .pending; if let n = req.value("document-name")?.stringValue, $0.name == "Untitled" { $0.name = n } }
            onSubmit?(JobSubmission(jobID: id, source: .document(data: req.data, mimeType: format)))
        }
        return jobResponse(to: req, job: store.get(id) ?? job)
    }

    private func closeJob(_ req: IPPMessage) -> IPPMessage {
        guard let id = req.value("job-id")?.intValue, let job = store.get(id) else {
            return response(to: req, status: IPPStatus.clientNotFound)
        }
        if job.state == .held { store.update(id) { $0.state = .completed; $0.message = "No document" } }
        return jobResponse(to: req, job: store.get(id) ?? job)
    }

    private func cancelJob(_ req: IPPMessage) -> IPPMessage {
        guard let id = jobID(req), store.get(id) != nil else {
            return response(to: req, status: IPPStatus.clientNotFound, message: "No such job")
        }
        return store.cancel(id) ? response(to: req, status: IPPStatus.ok)
            : response(to: req, status: IPPStatus.clientNotPossible, message: "Job already finished")
    }

    private func getJobAttributes(_ req: IPPMessage) -> IPPMessage {
        guard let id = jobID(req), let job = store.get(id) else {
            return response(to: req, status: IPPStatus.clientNotFound, message: "No such job")
        }
        var res = response(to: req, status: IPPStatus.ok)
        res.groups.append(IPPAttributeGroup(tag: IPPTag.jobAttributes, attributes: jobAttributes(job, full: true)))
        return res
    }

    private func getJobs(_ req: IPPMessage) -> IPPMessage {
        let which = req.value("which-jobs")?.stringValue ?? "not-completed"
        let limit = req.value("limit")?.intValue ?? Int.max
        let jobs = store.all().filter { job in
            switch which {
            case "completed": return job.state.isTerminal
            case "all": return true
            default: return !job.state.isTerminal
            }
        }.prefix(limit)
        var res = response(to: req, status: IPPStatus.ok)
        for job in jobs {
            res.groups.append(IPPAttributeGroup(tag: IPPTag.jobAttributes, attributes: jobAttributes(job, full: false)))
        }
        return res
    }

    private func getPrinterAttributes(_ req: IPPMessage) -> IPPMessage {
        var res = response(to: req, status: IPPStatus.ok)
        res.groups.append(IPPAttributeGroup(tag: IPPTag.printerAttributes, attributes: printerAttributes()))
        return res
    }

    // MARK: - Attribute builders

    private func response(to req: IPPMessage, status: UInt16, message: String? = nil) -> IPPMessage {
        var ops = [
            IPPAttribute("attributes-charset", .charset("utf-8")),
            IPPAttribute("attributes-natural-language", .language("en")),
        ]
        if let message { ops.append(IPPAttribute("status-message", .text(message))) }
        var res = IPPMessage(code: status, requestID: req.requestID, groups: [IPPAttributeGroup(tag: IPPTag.operationAttributes, attributes: ops)])
        res.versionMajor = min(req.versionMajor, 2)
        res.versionMinor = req.versionMajor >= 2 ? 0 : req.versionMinor
        return res
    }

    private func jobResponse(to req: IPPMessage, job: PrintJob) -> IPPMessage {
        var res = response(to: req, status: IPPStatus.ok)
        res.groups.append(IPPAttributeGroup(tag: IPPTag.jobAttributes, attributes: jobAttributes(job, full: false)))
        return res
    }

    private func jobAttributes(_ job: PrintJob, full: Bool) -> [IPPAttribute] {
        var attrs = [
            IPPAttribute("job-id", .int(job.id)),
            IPPAttribute("job-uri", .uri("\(Self.printerURI)/\(job.id)")),
            IPPAttribute("job-state", .enumValue(job.state.rawValue)),
            IPPAttribute("job-state-reasons", .keyword(job.state.ippReason)),
        ]
        if !job.message.isEmpty { attrs.append(IPPAttribute("job-state-message", .text(job.message))) }
        guard full else { return attrs }
        let none = IPPValue.outOfBand(tag: IPPTag.noValue)
        attrs += [
            IPPAttribute("job-name", .name(job.name)),
            IPPAttribute("job-originating-user-name", .name(job.user)),
            IPPAttribute("job-printer-uri", .uri(Self.printerURI)),
            IPPAttribute("job-printer-up-time", .int(store.uptime(Date()))),
            IPPAttribute("time-at-creation", .int(store.uptime(job.created))),
            IPPAttribute("time-at-processing", job.processingAt.map { .int(store.uptime($0)) } ?? none),
            IPPAttribute("time-at-completed", job.completedAt.map { .int(store.uptime($0)) } ?? none),
            IPPAttribute("job-impressions-completed", .int(job.state == .completed ? job.pages : 0)),
            IPPAttribute("job-media-sheets-completed", .int(job.state == .completed ? job.pages : 0)),
        ]
        return attrs
    }

    private func mediaCol(_ m: LabelMedia) -> IPPValue {
        .collection([
            IPPAttribute("media-size", .collection([
                IPPAttribute("x-dimension", .int(m.width)),
                IPPAttribute("y-dimension", .int(m.height)),
            ])),
            IPPAttribute("media-size-name", .keyword(m.keyword)),
            IPPAttribute("media-top-margin", .int(0)),
            IPPAttribute("media-bottom-margin", .int(0)),
            IPPAttribute("media-left-margin", .int(0)),
            IPPAttribute("media-right-margin", .int(0)),
            IPPAttribute("media-source", .keyword("main-roll")),
            IPPAttribute("media-type", .keyword("labels")),
        ])
    }

    private func printerAttributes() -> [IPPAttribute] {
        let settings = PrintSettings.current
        let dpi = settings.tspl.dpi
        let media = LabelMedia.catalog
        let defaultMedia = settings.defaultMedia
        let busy = store.activeCount > 0
        let minW = LabelMedia.customMin, maxW = LabelMedia.customMax
        let customMin = "custom_min_\(Double(minW.width) / 2540)x\(Double(minW.height) / 2540)in"
        let customMax = "custom_max_\(Double(maxW.width) / 2540)x\(Double(maxW.height) / 2540)in"

        return [
            IPPAttribute("printer-uri-supported", .uri(Self.printerURI)),
            IPPAttribute("uri-security-supported", .keyword("none")),
            IPPAttribute("uri-authentication-supported", .keyword("none")),
            IPPAttribute("printer-name", .name("MUNBYN 941BP")),
            IPPAttribute("printer-info", .text("MUNBYN 941BP (Bluetooth)")),
            IPPAttribute("printer-location", .text("Bluetooth via Munbyn Easy Print")),
            IPPAttribute("printer-make-and-model", .text("MUNBYN 941BP")),
            IPPAttribute("printer-device-id", .text("MFG:MUNBYN;MDL:941BP;CMD:TSPL;CLS:PRINTER;")),
            IPPAttribute("printer-uuid", .uri("urn:uuid:\(uuid)")),
            IPPAttribute("printer-kind", .keyword("labels")),
            IPPAttribute("printer-state", .enumValue(busy ? 4 : 3)),
            IPPAttribute("printer-state-reasons", .keyword(store.waitingReason == nil ? "none" : "offline-report")),
            IPPAttribute("printer-state-message", .text(store.waitingReason.map { "Waiting for printer: \($0)" } ?? (busy ? "Printing" : "Ready"))),
            IPPAttribute("printer-is-accepting-jobs", .boolean(true)),
            IPPAttribute("printer-up-time", .int(store.uptime(Date()))),
            IPPAttribute("printer-state-change-time", .int(1)),
            IPPAttribute("printer-config-change-time", .int(1)),
            IPPAttribute("queued-job-count", .int(store.activeCount)),
            IPPAttribute("ipp-versions-supported", [.keyword("1.1"), .keyword("2.0")]),
            IPPAttribute("ipp-features-supported", .keyword("ipp-everywhere")),
            IPPAttribute("operations-supported", [
                IPPOperation.printJob, IPPOperation.validateJob, IPPOperation.createJob, IPPOperation.sendDocument,
                IPPOperation.cancelJob, IPPOperation.getJobAttributes, IPPOperation.getJobs,
                IPPOperation.getPrinterAttributes, IPPOperation.closeJob, IPPOperation.identifyPrinter,
            ].map { .enumValue(Int($0)) }),
            IPPAttribute("charset-configured", .charset("utf-8")),
            IPPAttribute("charset-supported", .charset("utf-8")),
            IPPAttribute("natural-language-configured", .language("en")),
            IPPAttribute("generated-natural-language-supported", .language("en")),
            IPPAttribute("document-format-default", .mimeType("application/pdf")),
            IPPAttribute("document-format-supported", DocumentFormat.supportedMIMETypes.map { .mimeType($0) } + [.mimeType("application/octet-stream")]),
            IPPAttribute("document-format-preferred", .mimeType("application/pdf")),
            IPPAttribute("pdl-override-supported", .keyword("attempted")),
            IPPAttribute("compression-supported", .keyword("none")),
            IPPAttribute("multiple-document-jobs-supported", .boolean(false)),
            IPPAttribute("multiple-operation-time-out", .int(120)),
            IPPAttribute("job-ids-supported", .boolean(true)),
            IPPAttribute("which-jobs-supported", [.keyword("completed"), .keyword("not-completed"), .keyword("all")]),
            IPPAttribute("job-creation-attributes-supported", [
                "copies", "media", "media-col", "print-quality", "print-scaling", "orientation-requested",
                "print-color-mode", "printer-resolution", "sides",
            ].map { .keyword($0) }),

            IPPAttribute("color-supported", .boolean(false)),
            IPPAttribute("print-color-mode-supported", [.keyword("monochrome"), .keyword("bi-level")]),
            IPPAttribute("print-color-mode-default", .keyword("monochrome")),
            IPPAttribute("printer-resolution-supported", .dpi(dpi, dpi)),
            IPPAttribute("printer-resolution-default", .dpi(dpi, dpi)),
            IPPAttribute("print-quality-supported", [.enumValue(4)]),
            IPPAttribute("print-quality-default", .enumValue(4)),
            IPPAttribute("pwg-raster-document-resolution-supported", .dpi(dpi, dpi)),
            IPPAttribute("pwg-raster-document-type-supported", [.keyword("black_1"), .keyword("sgray_8")]),
            IPPAttribute("pwg-raster-document-sheet-back", .keyword("normal")),
            IPPAttribute("urf-supported", [.keyword("V1.4"), .keyword("CP1"), .keyword("W8"), .keyword("RS\(dpi)")]),

            IPPAttribute("copies-supported", .range(1, 999)),
            IPPAttribute("copies-default", .int(1)),
            IPPAttribute("sides-supported", .keyword("one-sided")),
            IPPAttribute("sides-default", .keyword("one-sided")),
            IPPAttribute("finishings-supported", .enumValue(3)),
            IPPAttribute("finishings-default", .enumValue(3)),
            IPPAttribute("orientation-requested-supported", [3, 4, 5, 6].map { .enumValue($0) }),
            IPPAttribute("orientation-requested-default", .enumValue(3)),
            IPPAttribute("print-scaling-supported", [.keyword("auto"), .keyword("fit"), .keyword("fill"), .keyword("none")]),
            IPPAttribute("print-scaling-default", .keyword("fit")),
            IPPAttribute("output-bin-supported", .keyword("face-up")),
            IPPAttribute("output-bin-default", .keyword("face-up")),
            IPPAttribute("pages-per-minute", .int(30)),

            IPPAttribute("media-supported", media.map { .keyword($0.keyword) } + [.keyword(customMin), .keyword(customMax)]),
            IPPAttribute("media-default", .keyword(defaultMedia.keyword)),
            IPPAttribute("media-ready", .keyword(defaultMedia.keyword)),
            IPPAttribute("media-col-supported", [
                "media-size", "media-size-name", "media-top-margin", "media-bottom-margin",
                "media-left-margin", "media-right-margin", "media-source", "media-type",
            ].map { .keyword($0) }),
            IPPAttribute("media-col-database", media.map(mediaCol) + [
                .collection([IPPAttribute("media-size", .collection([
                    IPPAttribute("x-dimension", .range(Int32(minW.width), Int32(maxW.width))),
                    IPPAttribute("y-dimension", .range(Int32(minW.height), Int32(maxW.height))),
                ]))]),
            ]),
            IPPAttribute("media-col-default", mediaCol(defaultMedia)),
            IPPAttribute("media-col-ready", mediaCol(defaultMedia)),
            IPPAttribute("media-size-supported", media.map { m in
                .collection([IPPAttribute("x-dimension", .int(m.width)), IPPAttribute("y-dimension", .int(m.height))])
            } + [.collection([
                IPPAttribute("x-dimension", .range(Int32(minW.width), Int32(maxW.width))),
                IPPAttribute("y-dimension", .range(Int32(minW.height), Int32(maxW.height))),
            ])]),
            IPPAttribute("media-top-margin-supported", .int(0)),
            IPPAttribute("media-bottom-margin-supported", .int(0)),
            IPPAttribute("media-left-margin-supported", .int(0)),
            IPPAttribute("media-right-margin-supported", .int(0)),
            IPPAttribute("media-source-supported", .keyword("main-roll")),
            IPPAttribute("media-type-supported", .keyword("labels")),
        ]
    }

    // MARK: - Helpers

    /// Cheap structural check, returning a reason if the document can't be printed.
    private static func validate(_ data: [UInt8], mimeType: String?) -> String? {
        guard let format = DocumentFormat.resolve(mimeType: mimeType, data: data) else {
            return "Unrecognized document format"
        }
        if format == .pdf {
            guard let provider = CGDataProvider(data: Data(data) as CFData),
                  let doc = CGPDFDocument(provider), doc.numberOfPages > 0
            else { return "Unreadable PDF" }
        }
        return nil
    }

    private func isSupported(_ format: String) -> Bool {
        format == "application/octet-stream" || DocumentFormat.supportedMIMETypes.contains(format)
    }

    private func jobID(_ req: IPPMessage) -> Int? {
        if let id = req.value("job-id")?.intValue { return id }
        if let uri = req.value("job-uri")?.stringValue, let last = uri.split(separator: "/").last { return Int(last) }
        return nil
    }

    private func jobName(_ req: IPPMessage) -> String {
        req.value("job-name")?.stringValue ?? req.value("document-name")?.stringValue ?? "Untitled"
    }

    private func userName(_ req: IPPMessage) -> String {
        req.value("requesting-user-name")?.stringValue ?? NSUserName()
    }

    private func ticket(from req: IPPMessage) -> JobTicket {
        var t = JobTicket()
        if let copies = req.value("copies")?.intValue { t.copies = max(1, min(999, copies)) }
        if let col = req.value("media-col")?.collectionValue, let m = LabelMedia.from(mediaCol: col) {
            t.media = m
        } else if let keyword = req.value("media")?.stringValue {
            t.media = LabelMedia.find(keyword: keyword)
        }
        return t
    }

    private func statusPage() -> HTTPResponse {
        let rows = store.all().prefix(20).map { "<tr><td>\($0.id)</td><td>\(escape($0.name))</td><td>\($0.state.label)</td><td>\(escape($0.message))</td></tr>" }.joined()
        let html = """
        <!doctype html><meta charset="utf-8"><title>Munbyn Easy Print</title>
        <style>body{font:14px -apple-system,sans-serif;margin:2em}td,th{padding:4px 12px;text-align:left}</style>
        <h1>MUNBYN 941BP</h1><p>IPP endpoint: <code>\(Self.printerURI)</code></p>
        <table><tr><th>Job</th><th>Name</th><th>State</th><th>Detail</th></tr>\(rows)</table>
        """
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: Array(html.utf8))
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
