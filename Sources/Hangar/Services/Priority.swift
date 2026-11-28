import Foundation

/// What Hangar last asked the orchestrator for. A nil `repo` asks it to stop.
struct PriorityAsk: Equatable, Sendable {
    var repo: String?
    var since: Date
}

enum PriorityStatus: Equatable {
    case off
    case asking(repo: String?, since: Date)
    case on(repo: String, until: Date)
    case failed(String)
}

/// Putting one project first. The orchestrator reads a small file; only its own report says whether priority is on.
enum PriorityRule {
    static let confirmWithin: TimeInterval = 60
    static let duration: TimeInterval = 2 * 3600
    private static let forgetAfter: TimeInterval = 5 * 60

    /// The file's name is fixed and its content arrives on standard input, so a project's name never reaches a shell.
    static let writeScript = #"f="$HOME/.config/runner-orchestrator/priority.json"; cat > "$f.tmp" && mv "$f.tmp" "$f""#

    /// The projects that can be chosen. None unless a current orchestrator says it supports priority.
    static func choices(state: OrchestratorState?, now: Date) -> [String] {
        guard let state, !state.isStale(now: now) else { return [] }
        return (state.priorityRepos ?? []).filter(Config.isSafeName)
    }

    /// True when a current report shows what was asked.
    static func confirms(_ state: OrchestratorState?, _ repo: String?, now: Date) -> Bool {
        guard let state, !state.isStale(now: now) else { return false }
        guard let repo else { return reported(state, now: now) == nil }
        return reported(state, now: now)?.repo.caseInsensitiveCompare(repo) == .orderedSame
    }

    private static func reported(_ state: OrchestratorState?, now: Date) -> (repo: String, until: Date)? {
        guard let state, !state.isStale(now: now), let repo = state.priority?.repo.nonEmpty, let until = state.priority?.until,
              until > now else { return nil }
        return (repo, until)
    }

    static func status(state: OrchestratorState?, asked: PriorityAsk?, writeError: String?, now: Date) -> PriorityStatus {
        let shown: PriorityStatus = reported(state, now: now).map { .on(repo: $0.repo, until: $0.until) } ?? .off
        guard let asked, now.timeIntervalSince(asked.since) < forgetAfter else { return shown }
        let says = reported(state, now: now).map { "\($0.repo) first" } ?? "no priority"
        if let writeError { return .failed("Could not send the choice: \(writeError). The orchestrator reports \(says).") }
        if confirms(state, asked.repo, now: now) { return shown }
        if now.timeIntervalSince(asked.since) >= confirmWithin { return .failed("The orchestrator has not confirmed it. It reports \(says).") }
        return .asking(repo: asked.repo, since: asked.since)
    }

    /// The file's content: the project and when its turn ends, or an empty name to stop. `repo` has passed `choices`.
    static func file(repo: String?, now: Date) -> String {
        guard let repo else { return "{\"repo\":\"\"}\n" }
        return "{\"repo\":\"\(repo)\",\"until\":\"\(now.addingTimeInterval(duration).formatted(.iso8601))\"}\n"
    }
}
