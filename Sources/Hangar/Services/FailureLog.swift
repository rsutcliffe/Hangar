import Foundation

/// One failed job, as first seen. Names and times only: never log output.
struct FailureRecord: Codable, Equatable, Sendable, Identifiable {
    var jobID: Int
    var runner: String
    var repo: String
    var workflow: String
    var job: String
    var stepName: String?
    var stepNumber: Int?
    var at: Date
    var url: String?

    var id: Int { jobID }

    /// "Checkout" when GitHub named the step, otherwise "step 4".
    var reason: String {
        if let s = stepName, !s.isEmpty { return s }
        return stepNumber.map { "step \($0)" } ?? "unknown step"
    }

    /// "CI / unit-tests": the workflow, plus the job when it has a different name.
    var title: String { job.isEmpty || job == workflow ? workflow : "\(workflow) / \(job)" }
}

/// The last failures across all runners, kept on disk for 30 days (issue 20).
struct FailureLog: Codable, Equatable, Sendable {
    static let maxEntries = 200
    static let retention: TimeInterval = 30 * 24 * 3600

    private(set) var entries: [FailureRecord] = []        // newest first

    /// True if it was new. A failure is recorded once, however many polls see it.
    @discardableResult
    mutating func record(_ r: FailureRecord, now: Date = Date()) -> Bool {
        guard !entries.contains(where: { $0.jobID == r.jobID }) else { return false }
        entries.insert(r, at: 0)
        entries.sort { $0.at > $1.at }
        prune(now: now)
        return true
    }

    mutating func prune(now: Date) {
        let oldest = now.addingTimeInterval(-Self.retention)
        entries = Array(entries.filter { $0.at >= oldest }.prefix(Self.maxEntries))
    }

    func recent(_ n: Int, runner: String? = nil) -> [FailureRecord] {
        Array(entries.filter { runner == nil || $0.runner == runner }.prefix(n))
    }

    // MARK: persistence

    static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Hangar", isDirectory: true).appendingPathComponent("failures.json")
    }

    static func load(from url: URL? = defaultURL(), now: Date = Date()) -> FailureLog {
        guard let url, let d = try? Data(contentsOf: url) else { return FailureLog() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard var log = try? dec.decode(FailureLog.self, from: d) else { return FailureLog() }
        log.prune(now: now)
        return log
    }

    func save(to url: URL? = defaultURL()) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(self) { try? d.write(to: url, options: .atomic) }
    }

    /// A few plausible failures so the Capacity window can be checked in demo mode.
    static func demo(now: Date) -> FailureLog {
        var log = FailureLog()
        let rows: [(String, String, String, String, Int, TimeInterval)] = [
            ("arm-02", "web", "Run unit tests", "test", 4, 2 * 3600), ("arm-01", "api-server", "Checkout", "build", 2, 5 * 3600),
            ("arm-02", "web", "Run unit tests", "test", 4, 26 * 3600), ("x86-01", "ios-app", "Install dependencies", "Unit tests", 3, 3 * 86_400),
        ]
        for (i, r) in rows.enumerated() {
            log.record(FailureRecord(jobID: 9_000 + i, runner: r.0, repo: r.1, workflow: r.3, job: r.3, stepName: r.2, stepNumber: r.4,
                                     at: now.addingTimeInterval(-r.5), url: nil), now: now)
        }
        return log
    }
}
