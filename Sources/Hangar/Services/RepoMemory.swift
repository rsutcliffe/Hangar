import Foundation

/// Repositories Hangar has seen runners for, kept between polls and launches. A runner is found by scanning a host, and a host's runner
/// VM can be stopped while it has nothing to do (the orchestrator stops it when idle), so a repo whose runners are all in a stopped VM
/// would otherwise vanish: its queue and its on-demand runners would no longer be read.
enum RepoMemory {
    static let key = "knownRepos"

    /// "owner/name", only when both parts are boring enough to go into a URL.
    static func parse(_ s: String) -> LiveBackend.RepoRef? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Config.isSafeName(parts[0]), Config.isSafeName(parts[1]), parts[1] != "..", parts[1] != "." else { return nil }
        return LiveBackend.RepoRef(owner: parts[0], repo: parts[1])
    }

    static func encode(_ repos: Set<LiveBackend.RepoRef>) -> [String] {
        repos.map { "\($0.owner)/\($0.repo)" }.sorted()
    }

    static func merge(found: Set<LiveBackend.RepoRef>, remembered: [String]) -> Set<LiveBackend.RepoRef> {
        found.union(remembered.compactMap(parse))
    }
}
