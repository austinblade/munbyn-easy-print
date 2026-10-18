import Foundation
import PrintCore

/// IPP `job-state` values.
enum JobState: Int, Sendable {
    case pending = 3
    case held = 4
    case processing = 5
    case canceled = 7
    case aborted = 8
    case completed = 9

    var isTerminal: Bool { rawValue >= 7 }

    var label: String {
        switch self {
        case .pending: return "Waiting"
        case .held: return "Receiving"
        case .processing: return "Printing"
        case .canceled: return "Canceled"
        case .aborted: return "Failed"
        case .completed: return "Printed"
        }
    }

    var ippReason: String {
        switch self {
        case .pending: return "none"
        case .held: return "job-incoming"
        case .processing: return "job-printing"
        case .canceled: return "job-canceled-by-user"
        case .aborted: return "aborted-by-system"
        case .completed: return "job-completed-successfully"
        }
    }
}

struct PrintJob: Identifiable, Sendable {
    let id: Int
    var name: String
    var user: String
    var state: JobState
    var message: String = ""
    var created = Date()
    var processingAt: Date?
    var completedAt: Date?
    var progress: Double = 0
    var pages = 0
}

/// Per-job print options pulled from the IPP request.
struct JobTicket: Sendable {
    var copies = 1
    var media: LabelMedia?
}

/// Thread-safe job table shared by the IPP server (its own queue) and the UI.
final class JobStore: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [Int: PrintJob] = [:]
    private var tickets: [Int: JobTicket] = [:]
    private var nextID = 1
    private var _waitingReason: String?
    let startedAt = Date()

    /// Called (on the main queue) after every mutation.
    var onChange: (@MainActor () -> Void)?

    func create(name: String, user: String, state: JobState = .pending, ticket: JobTicket = JobTicket()) -> PrintJob {
        let job: PrintJob = lock.withLock {
            let job = PrintJob(id: nextID, name: name, user: user, state: state)
            nextID += 1
            jobs[job.id] = job
            tickets[job.id] = ticket
            prune()
            return job
        }
        notify()
        return job
    }

    func update(_ id: Int, _ mutate: (inout PrintJob) -> Void) {
        lock.withLock {
            guard var job = jobs[id] else { return }
            mutate(&job)
            if job.state == .processing, job.processingAt == nil { job.processingAt = Date() }
            if job.state.isTerminal, job.completedAt == nil { job.completedAt = Date() }
            jobs[id] = job
        }
        notify()
    }

    /// Set while a job is blocked on the printer; reported to CUPS as offline.
    var waitingReason: String? {
        get { lock.withLock { _waitingReason } }
        set { lock.withLock { _waitingReason = newValue } }
    }

    func get(_ id: Int) -> PrintJob? { lock.withLock { jobs[id] } }

    func ticket(_ id: Int) -> JobTicket { lock.withLock { tickets[id] ?? JobTicket() } }

    func all() -> [PrintJob] { lock.withLock { jobs.values.sorted { $0.id > $1.id } } }

    var activeCount: Int { lock.withLock { jobs.values.filter { !$0.state.isTerminal }.count } }

    /// Returns false if the job is unknown or already finished.
    func cancel(_ id: Int) -> Bool {
        var ok = false
        lock.withLock {
            guard var job = jobs[id], !job.state.isTerminal else { return }
            job.state = .canceled
            job.message = "Canceled"
            job.completedAt = Date()
            jobs[id] = job
            ok = true
        }
        if ok { notify() }
        return ok
    }

    func uptime(_ date: Date?) -> Int {
        guard let date else { return 0 }
        return max(1, Int(date.timeIntervalSince(startedAt)) + 1)
    }

    private func prune() {
        let finished = jobs.values.filter { $0.state.isTerminal }.sorted { $0.id < $1.id }
        for job in finished.dropLast(50) {
            jobs[job.id] = nil
            tickets[job.id] = nil
        }
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }
}
