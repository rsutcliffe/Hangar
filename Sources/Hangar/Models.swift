import AppKit
import Foundation

enum RunnerState: String, Equatable, Sendable {
    case running, stalled, failed, restarting, idle, paused, offline
    /// Its whole host could not be reached; shown from the last known state.
    case unreachable

    /// Stalled or failed: needs the user, so it is shown in red.
    var isProblem: Bool { self == .stalled || self == .failed }
}

enum Arch: String, Equatable, Sendable {
    case arm64, x86

    var label: String { rawValue }
}

struct ActiveJob: Equatable, Sendable {
    var id: Int
    var repo: String
    var workflow: String
    var runNumber: Int
    var branch: String
    var totalSteps: Int
    var currentStep: Int
    var startedAt: Date
    var lastOutputAt: Date
    var failedStep: Int?
    var exitCode: Int?
    var failedStepName: String? = nil
    var url: URL? = nil
    var jobName = ""

    var historyKey: String { JobHistory.key(repo: repo, workflow: workflow, job: jobName) }

    /// 0...1, currentStep/totalSteps.
    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return min(1, max(0, Double(currentStep) / Double(totalSteps)))
    }

    var title: String { "\(workflow) · \(repo) #\(runNumber)" }
}

struct Runner: Identifiable, Equatable, Sendable {
    let id: String              // Colima profile name, e.g. "arm-01"
    var arch: Arch
    var cpus: Int
    var memoryGB: Double
    var state: RunnerState
    var draining = false
    var job: ActiveJob?
    var cpuHistory: [Double] = []   // last 10 samples, 0-100
    var memUsedGB = 0.0
    var lastJobEndedAt: Date?
    var failedAt: Date?
    var host = ""
    var standby = false
    /// Recent average CPU of this runner's own processes (percent of one core), when known.
    var runnerCPU: Double?
    /// When the runner was last seen; set while its host is unreachable.
    var lastSeenAt: Date?
    /// The last restart did not bring the runner back online within the timeout.
    var restartFailed = false
    var diskFreeKB: Int?
    var diskUsedPct: Int?
    var version: String?
    var latestVersion: String?
    /// Times longer than this job usually takes, when notably long.
    var longRunFactor: Double?
    /// Consecutive failures of the same job on this runner, when three or more.
    var failStreak: Int?

    struct Note: Equatable { var text: String; var urgent: Bool; var help: String? = nil }

    /// Extra lines for the card, most important first.
    var notes: [Note] {
        var n: [Note] = []
        if let d = DiskRule.warning(freeKB: diskFreeKB, usedPct: diskUsedPct) { n.append(Note(text: d, urgent: true)) }
        if let s = failStreak { n.append(Note(text: "Failed \(s) times in a row here", urgent: true)) }
        if let f = longRunFactor { n.append(Note(text: String(format: "Running %.1fx longer than usual", f), urgent: true)) }
        if let v = version, let l = latestVersion, VersionCheck.isBehind(current: v, latest: l) { n.append(Note(text: "Runner update available: \(l)", urgent: false, help: "GitHub Actions runner \(v) is installed; \(l) is the latest release")) }
        return n
    }

    var spec: String {
        let hw = "\(cpus) CPU · \(Format.gb(memoryGB))"
        return host.isEmpty ? hw : "\(host) · \(hw)"
    }
    var cpuNow: Int { Int((cpuHistory.last ?? 0).rounded()) }
}

struct QueuedJob: Identifiable, Equatable, Sendable {
    let id: Int
    var repo: String
    var workflow: String
    var branch: String
    var runNumber: Int
    var arch: Arch
    var queuedAt: Date
    var job = ""
    var labels: [String] = []
    /// Names of online runners that could take this job; nil when runner data was unavailable.
    var eligible: [String]? = nil
    /// Job labels that no online runner of the repo has (empty if each label exists but not all on one runner).
    var missingLabels: [String] = []
    var url: URL? = nil

    var isStuck: Bool { eligible?.isEmpty == true }
}

enum GitHubLink {
    /// Job and run links come from the API; only open https links on github.com.
    static func safe(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme == "https", let h = u.host?.lowercased(), h == "github.com" || h == "www.github.com" else { return nil }
        return u
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

enum QueueAnalysis {
    /// Online runners registered to the job's repo whose labels include every label the job asks for (case-insensitive).
    static func eligible(labels: [String], repo: String, runners: [GHRunner]) -> [String] {
        let need = Set(labels.map { $0.lowercased() })
        return runners.filter { $0.online && ($0.repo.isEmpty || $0.repo == repo) && need.isSubset(of: Set($0.labels.map { $0.lowercased() })) }
            .map(\.name).sorted()
    }

    static func missingLabels(labels: [String], repo: String, runners: [GHRunner]) -> [String] {
        let have = Set(runners.filter { $0.online && ($0.repo.isEmpty || $0.repo == repo) }.flatMap { $0.labels.map { $0.lowercased() } })
        return labels.filter { !have.contains($0.lowercased()) }
    }
}

extension [QueuedJob] {
    func count(for arch: Arch) -> Int { filter { $0.arch == arch }.count }
    var stuckCount: Int { filter(\.isStuck).count }
}

extension Runner {
    /// One spoken line for VoiceOver: "arm-02, Stalled, test · web #1190, no output for 14m".
    func accessibilitySummary(now: Date) -> String {
        var parts = [id, state.spoken]
        if let j = job {
            parts.append(j.title)
            switch state {
            case .stalled: parts.append("no output for \(Format.duration(now.timeIntervalSince(j.lastOutputAt)))")
            case .failed: parts.append("failed at step \(j.failedStep ?? j.currentStep)")
            case .running: parts.append("step \(j.currentStep) of \(j.totalSteps), \(Int(j.progress * 100)) percent")
            default: break
            }
        }
        if standby { parts.append("standby") }
        if draining { parts.append("draining") }
        return parts.joined(separator: ", ")
    }
}

extension RunnerState {
    var spoken: String {
        switch self {
        case .running: "Running"
        case .stalled: "Stalled"
        case .failed: "Failed"
        case .restarting: "Restarting"
        case .idle: "Idle"
        case .paused: "Paused"
        case .offline: "Offline"
        case .unreachable: "Unreachable"
        }
    }
}
