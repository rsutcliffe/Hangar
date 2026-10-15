import Foundation

/// The result of Settings > Test connection: one line per check, each saying what to fix when it failed.
struct ConnectionReport: Equatable, Sendable {
    struct Line: Equatable, Sendable { var ok: Bool; var text: String }
    var lines: [Line] = []

    var allOK: Bool { !lines.isEmpty && lines.allSatisfy(\.ok) }

    static func host(_ label: String, error: String?, runners: Int) -> Line {
        if let error { return Line(ok: false, text: "\(label): unreachable (\(error)). Check SSH key login and that the host is awake.") }
        return runners == 0 ? Line(ok: false, text: "\(label): reachable, but no runners found in ~/actions-runner*.")
                            : Line(ok: true, text: "\(label): reachable, \(runners) runner\(runners == 1 ? "" : "s") found.")
    }

    static func repo(_ name: String, error: Error?) -> Line {
        guard let error else { return Line(ok: true, text: "\(name): runners readable.") }
        switch error {
        case GitHubError.unauthorized: return Line(ok: false, text: "\(name): GitHub rejected the token. Replace it in Settings.")
        case GitHubError.http(403): return Line(ok: false, text: "\(name): token lacks permission. It needs Actions and Administration: read for this repo.")
        case GitHubError.http(404): return Line(ok: false, text: "\(name): not found, or the token was not given this repo.")
        case GitHubError.rateLimited: return Line(ok: false, text: "\(name): GitHub rate limit reached; try again shortly.")
        default: return Line(ok: false, text: "\(name): \((error as? LocalizedError)?.errorDescription ?? "request failed").")
        }
    }

    static let noToken = Line(ok: false, text: "No GitHub token saved. Paste one into the token field above.")
}
