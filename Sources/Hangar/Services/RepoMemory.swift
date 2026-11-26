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

    /// The "Repositories to watch" setting: one owner/name per line (commas also split).
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func encode(_ repos: Set<LiveBackend.RepoRef>) -> [String] {
        repos.map { "\($0.owner)/\($0.repo)" }.sorted()
    }

    /// GitHub ignores capital letters in owner and repo names, so spellings that differ only in them are one repo: reading both
    /// listed its on-demand runners twice. A spelling seen in a runner folder beats a remembered one; ties go to the first in
    /// sort order, so the choice does not change between polls.
    static func merge(found: Set<LiveBackend.RepoRef>, remembered: [String]) -> Set<LiveBackend.RepoRef> {
        var chosen: [String: LiveBackend.RepoRef] = [:]
        for refs in [Array(found), remembered.compactMap(parse)] {
            for r in refs.sorted(by: { name($0) < name($1) }) where chosen[name(r).lowercased()] == nil {
                chosen[name(r).lowercased()] = r
            }
        }
        return Set(chosen.values)
    }

    private static func name(_ r: LiveBackend.RepoRef) -> String { "\(r.owner)/\(r.repo)" }

    /// The spelling `repos` uses for `ref`. Runner folders must use it too: runners and jobs are matched to them by repo name.
    static func spelled(_ ref: LiveBackend.RepoRef, in repos: Set<LiveBackend.RepoRef>) -> LiveBackend.RepoRef {
        repos.first { name($0).lowercased() == name(ref).lowercased() } ?? ref
    }
}
