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

enum RunLabel {
    /// The pull request's number when the run belongs to one, otherwise the run's own.
    static func number(run: Int, pr: Int?) -> String { pr.map { "PR \($0)" } ?? "#\(run)" }
}

struct ActiveJob: Equatable, Sendable {
    var id: Int
    var repo: String
    var workflow: String
    var runNumber: Int
    var prNumber: Int? = nil
    var numberLabel: String { RunLabel.number(run: runNumber, pr: prNumber) }
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

    var title: String { "\(workflow) · \(repo) \(numberLabel)" }
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
    /// The figures are for a Colima VM's disk, which its runners share (not a Mac's own disk).
    var diskIsVM = false
    /// Paused by Hangar because its Mac is low on memory.
    var held = false
    /// The Mac's memory state; set on one runner per host, like the disk figures.
    var hostMemory: HostMemory?
    var version: String?
    var latestVersion: String?
    /// When that release came out; a runner that has not caught up with an old release is not updating itself.
    var latestPublished: Date?
    /// Times longer than this job usually takes, when notably long.
    var longRunFactor: Double?
    /// Consecutive failures of the same job on this runner, when three or more.
    var failStreak: Int?

    struct Note: Equatable { var text: String; var urgent: Bool; var help: String? = nil }

    /// Extra lines for the card, most important first.
    var notes: [Note] { notes(now: Date()) }

    func notes(now: Date) -> [Note] {
        var n: [Note] = []
        if let d = DiskRule.warning(freeKB: diskFreeKB, usedPct: diskUsedPct, vm: diskIsVM) { n.append(Note(text: d, urgent: true)) }
        if let w = MemoryRule.warning(hostMemory) { n.append(Note(text: w.text, urgent: true, help: w.help)) }
        else if let w = MemoryRule.overcommit(hostMemory) { n.append(Note(text: w.text, urgent: false, help: w.help)) }
        if let s = failStreak { n.append(Note(text: "Failed \(s) times in a row here", urgent: true)) }
        if let f = longRunFactor { n.append(Note(text: String(format: "Running %.1fx longer than usual", f), urgent: true)) }
        if let v = version, let l = latestVersion, VersionCheck.isBehind(current: v, latest: l) {
            let help = "GitHub Actions runner \(v) is installed; \(l) is the latest release"
            switch latestPublished.map({ now.timeIntervalSince($0) }) {
            case let age? where age < RunnerUpdate.grace: break                // runners normally update themselves within days
            case .some: n.append(Note(text: "Runner update overdue: \(l)", urgent: true, help: help + ". It has not updated itself, and GitHub stops giving a runner jobs about 30 days after a release."))
            case nil: n.append(Note(text: "Runner update available: \(l)", urgent: false, help: help))
            }
        }
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
    var prNumber: Int? = nil
    var numberLabel: String { RunLabel.number(run: runNumber, pr: prNumber) }
    var arch: Arch
    var queuedAt: Date
    var job = ""
    var labels: [String] = []
    /// Names of online runners that could take this job; nil when runner data was unavailable.
    var eligible: [String]? = nil
    /// Job labels that no online runner of the repo has (empty if each label exists but not all on one runner).
    var missingLabels: [String] = []
    var url: URL? = nil
    /// Waits for an on-demand runner: the orchestrator starts one when a slot is free, so no runner exists yet and none is "missing".
    var onDemand = false

    var isStuck: Bool { eligible?.isEmpty == true }
}

/// A short-lived runner the orchestrator started for one job, named `<set>-<unix nanoseconds>`.
struct OnDemandRunner: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var repo: String
    /// The scale set it belongs to: its name without the trailing number.
    var set: String
    var busy: Bool
    var job: ActiveJob?
    /// The Mac whose orchestrator VM runs it ("iMac", "mac-mini"); nil when no host reported the container.
    var host: String? = nil

    /// The set name when `name` ends in `-` and at least ten digits (the orchestrator's naming), else nil.
    static func setName(of name: String) -> String? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let set = String(name[..<dash]), digits = name[name.index(after: dash)...]
        guard !set.isEmpty, digits.count >= 10, digits.allSatisfy(\.isNumber) else { return nil }
        return set
    }
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

    /// A job for an orchestrator scale set: not for a GitHub-hosted runner and not an ordinary `self-hosted` job, so its only
    /// labels are the set's name. Prefixes are those of GitHub's own runner labels.
    static func isOnDemand(labels: [String]) -> Bool {
        let l = labels.map { $0.lowercased() }
        guard !l.isEmpty, !l.contains("self-hosted") else { return false }
        return !l.allSatisfy { $0.hasPrefix("ubuntu-") || $0.hasPrefix("windows-") || $0.hasPrefix("macos-") }
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
