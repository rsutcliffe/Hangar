import Foundation

enum GitHubError: Error, Equatable, LocalizedError {
    case noToken, unauthorized, rateLimited(until: Date?), http(Int), badURL

    var errorDescription: String? {
        switch self {
        case .noToken: "No GitHub token set"
        case .unauthorized: "GitHub rejected the token"
        case .rateLimited(let until):
            until.map { "GitHub rate limit: next poll at \($0.formatted(date: .omitted, time: .shortened))" } ?? "GitHub rate limit reached"
        case .http(403): "Token lacks permission (needs Actions and Administration: read)"
        case .http(404): "Repo not found or token cannot see it"
        case .http(let c): "GitHub returned HTTP \(c)"
        case .badURL: "Invalid owner or repo name"
        }
    }
}

struct GHRunner: Equatable, Sendable {
    var name: String; var online: Bool; var busy: Bool; var labels: [String]
    /// The repo this runner is registered to (repo-level runners only take that repo's jobs).
    var repo = ""
    /// A fallback runner, marked with a "standby" label (e.g. `macbook-standby`). GitHub labels are case-insensitive.
    var isStandby: Bool { labels.contains { $0.localizedCaseInsensitiveContains("standby") } }
}

struct GHJob: Equatable, Sendable {
    var id: Int; var runId: Int; var repo: String; var workflow: String; var runNumber: Int
    var branch: String; var status: String; var conclusion: String?
    var labels: [String]; var runnerName: String?
    var createdAt: Date; var startedAt: Date?; var completedAt: Date?
    var steps: [Step]
    var name = ""
    var htmlURL = ""
    struct Step: Equatable, Sendable { var number: Int; var status: String; var conclusion: String?; var name = "" }
}

actor GitHubService {
    private let session: URLSession
    private var expiry: Date?

    /// From the `GitHub-Authentication-Token-Expiration` header on the latest response; nil if the token has none.
    func tokenExpiry() -> Date? { expiry }
    init(session: URLSession = .shared) { self.session = session }

    private func get(_ path: String, token: String) async throws -> Any {
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let h = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "GitHub-Authentication-Token-Expiration") { expiry = TokenExpiry.parse(h) }
        switch code {
        case 200..<300: return try JSONSerialization.jsonObject(with: data)
        case 401: throw GitHubError.unauthorized
        case 403, 429:
            let h = resp as? HTTPURLResponse
            let retry = h?.value(forHTTPHeaderField: "retry-after")
            if h?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || retry != nil || code == 429 {
                let wait = RateLimit.delay(retryAfter: retry, resetEpoch: h?.value(forHTTPHeaderField: "x-ratelimit-reset"), now: Date())
                throw GitHubError.rateLimited(until: wait.map { Date().addingTimeInterval($0) })
            }
            throw GitHubError.http(code)
        default: throw GitHubError.http(code)
        }
    }

    private var latestRunner: (version: String, fetched: Date)?
    private var latestApp: (release: AppRelease, fetched: Date)?

    /// Latest published Hangar release, from the public endpoint with no token, cached for six hours.
    func latestAppRelease(now: Date = Date()) async -> AppRelease? {
        if let c = latestApp, now.timeIntervalSince(c.fetched) < 6 * 3600 { return c.release }
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest") else { return latestApp?.release }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = Self.parseAppRelease(data) else { return latestApp?.release }
        latestApp = (r, now)
        return r
    }

    static func parseAppRelease(_ data: Data) -> AppRelease? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, VersionCheck.parse(tag) != nil,
              j["draft"] as? Bool != true, j["prerelease"] as? Bool != true,
              let page = (j["html_url"] as? String).flatMap(GitHubLink.safe) else { return nil }
        return AppRelease(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), name: j["name"] as? String ?? "", url: page)
    }

    /// Latest actions/runner release tag, from a public endpoint, cached for six hours. nil if it cannot be read.
    func latestRunnerVersion(now: Date = Date()) async -> String? {
        if let c = latestRunner, now.timeIntervalSince(c.fetched) < 6 * 3600 { return c.version }
        guard let url = URL(string: "https://api.github.com/repos/actions/runner/releases/latest") else { return latestRunner?.version }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")        // no token: it is a public repo
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String,
              VersionCheck.parse(tag) != nil else { return latestRunner?.version }
        let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        latestRunner = (v, now)
        return v
    }

    /// Repo-level runners (needs Administration: read on the repo).
    func runners(owner: String, repo: String, token: String) async throws -> [GHRunner] {
        guard Config.isSafeName(owner), Config.isSafeName(repo) else { throw GitHubError.badURL }
        return Self.parseRunners(try await get("/repos/\(owner)/\(repo)/actions/runners?per_page=100", token: token))
    }

    /// Recent runs for a repo, then the jobs for runs that matter (queued, running, recently failed).
    func jobs(owner: String, repo: String, token: String, now: Date = Date()) async throws -> [GHJob] {
        guard Config.isSafeName(owner), Config.isSafeName(repo) else { throw GitHubError.badURL }
        let runsJSON = try await get("/repos/\(owner)/\(repo)/actions/runs?per_page=20", token: token)
        let runs = Self.parseRuns(runsJSON)
        var out: [GHJob] = []
        for run in runs where run.status != "completed" || (run.conclusion == "failure" && now.timeIntervalSince(run.updatedAt) < 600) {
            let j = try await get("/repos/\(owner)/\(repo)/actions/runs/\(run.id)/jobs?per_page=100", token: token)
            out += Self.parseJobs(j, repo: repo, run: run)
        }
        return out
    }

    // MARK: parsing (pure, unit-tested)

    struct Run: Equatable, Sendable {
        var id: Int; var name: String; var number: Int; var branch: String
        var status: String; var conclusion: String?; var updatedAt: Date
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    static func parseRunners(_ json: Any) -> [GHRunner] {
        let list = (json as? [String: Any])?["runners"] as? [[String: Any]] ?? []
        return list.map {
            GHRunner(name: $0["name"] as? String ?? "", online: ($0["status"] as? String) == "online",
                     busy: $0["busy"] as? Bool ?? false,
                     labels: ($0["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        }
    }

    static func parseRuns(_ json: Any) -> [Run] {
        let list = (json as? [String: Any])?["workflow_runs"] as? [[String: Any]] ?? []
        return list.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            return Run(id: id, name: r["name"] as? String ?? "", number: r["run_number"] as? Int ?? 0,
                       branch: r["head_branch"] as? String ?? "", status: r["status"] as? String ?? "",
                       conclusion: r["conclusion"] as? String, updatedAt: date(r["updated_at"]) ?? .distantPast)
        }
    }

    static func parseJobs(_ json: Any, repo: String, run: Run) -> [GHJob] {
        let list = (json as? [String: Any])?["jobs"] as? [[String: Any]] ?? []
        return list.compactMap { j in
            guard let id = j["id"] as? Int, let created = date(j["created_at"]) else { return nil }
            let steps = (j["steps"] as? [[String: Any]] ?? []).map {
                GHJob.Step(number: $0["number"] as? Int ?? 0, status: $0["status"] as? String ?? "", conclusion: $0["conclusion"] as? String,
                            name: $0["name"] as? String ?? "")
            }
            return GHJob(id: id, runId: run.id, repo: repo, workflow: run.name, runNumber: run.number,
                         branch: run.branch, status: j["status"] as? String ?? "", conclusion: j["conclusion"] as? String,
                         labels: j["labels"] as? [String] ?? [], runnerName: j["runner_name"] as? String,
                         createdAt: created, startedAt: date(j["started_at"]), completedAt: date(j["completed_at"]), steps: steps,
                         name: j["name"] as? String ?? "", htmlURL: j["html_url"] as? String ?? "")
        }
    }
}

struct AppRelease: Equatable, Sendable {
    var version: String
    var name: String
    var url: URL
}

enum AppInfo {
    /// Where Hangar's releases are published (a public repository).
    static let repo = "rsutcliffe/Hangar"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// The release to offer: only when it is newer than the running version.
    static func update(current: String, latest: AppRelease?) -> AppRelease? {
        guard let latest, VersionCheck.isBehind(current: current, latest: latest.version) else { return nil }
        return latest
    }
}
