import Foundation

enum RunnerState: String, Equatable, Sendable {
    case running, stalled, failed, restarting, idle, paused, offline

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
}

extension [QueuedJob] {
    func count(for arch: Arch) -> Int { filter { $0.arch == arch }.count }
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
        }
    }
}
