import Foundation

struct VMInfo: Equatable, Sendable {
    var running: Bool
    var arch: Arch
    var cpus: Int
    var memoryGB: Double
}

/// One runner directory found inside a VM.
struct RunnerFacts: Equatable, Sendable {
    var dir: String
    var name: String            // agentName from .runner
    var owner: String
    var repo: String
    var listenerRunning: Bool
    var lastOutputAt: Date?
}

/// Everything learned from one ssh round trip into a VM.
struct VMSnapshot: Equatable, Sendable {
    var cpuPercent: Double
    var memUsedGB: Double
    var runners: [RunnerFacts]
}

enum VMSnapshotParser {
    /// Parses the script output: cpu line, ---, meminfo, ---, `date +%s`, then `R|dir|name|url|listener|mtime` lines.
    static func parse(_ out: String, prevCPU: ProcParser.CPUTimes?) -> (VMSnapshot, ProcParser.CPUTimes?)? {
        let parts = out.components(separatedBy: "---\n")
        guard parts.count == 3 else { return nil }
        let times = ProcParser.cpuTimes(fromStatLine: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
        var cpu = 0.0
        if let t = times, let p = prevCPU, let pct = ProcParser.cpuPercent(prev: p, now: t) { cpu = pct }
        let lines = parts[2].split(separator: "\n").map(String.init)
        let vmNow = lines.first.flatMap(TimeInterval.init)
        var runners: [RunnerFacts] = []
        for line in lines.dropFirst() where line.hasPrefix("R|") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let (owner, repo) = ownerRepo(fromURL: f[3]), !f[2].isEmpty else { continue }
            var last: Date?
            if let m = TimeInterval(f[5]), let now = vmNow { last = Date(timeIntervalSinceNow: -(now - m)) }
            runners.append(RunnerFacts(dir: f[1], name: f[2], owner: owner, repo: repo, listenerRunning: f[4] == "1", lastOutputAt: last))
        }
        let snap = VMSnapshot(cpuPercent: cpu, memUsedGB: ProcParser.memUsedGB(fromMeminfo: parts[1]) ?? 0,
                              runners: runners.sorted { $0.name < $1.name })
        return (snap, times)
    }

    static func ownerRepo(fromURL url: String) -> (String, String)? {
        let c = url.split(separator: "/").map(String.init)
        guard c.count >= 2, Config.isSafeName(c[c.count - 2]), Config.isSafeName(c[c.count - 1]) else { return nil }
        return (c[c.count - 2], c[c.count - 1])
    }
}

actor ColimaService {
    private let colima: String?
    private var prevCPU: [String: ProcParser.CPUTimes] = [:]

    init() { colima = Shell.find("colima") }

    private func bin() throws -> String {
        guard let colima else { throw ShellError.notFound("colima") }
        return colima
    }

    /// `colima list --json` prints one JSON object per line.
    func list() async throws -> [String: VMInfo] {
        let out = try await Shell.run(bin(), ["list", "--json"])
        var result: [String: VMInfo] = [:]
        for line in out.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = d["name"] as? String else { continue }
            let status = (d["status"] as? String ?? "").lowercased()
            let arch: Arch = (d["arch"] as? String ?? "").contains("x86") ? .x86 : .arm64
            let mem = (d["memory"] as? Double) ?? 0
            result[name] = VMInfo(running: status == "running", arch: arch,
                                  cpus: d["cpus"] as? Int ?? 0, memoryGB: mem / 1_073_741_824)
        }
        return result
    }

    // Reads only: CPU/mem counters, the runner dirs' .runner name and repo URL (never credentials),
    // listener process, and newest worker log mtime.
    private static let script = #"""
    head -1 /proc/stat; echo ---; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; echo ---; date +%s
    for d in "$HOME"/actions-runner*; do
      [ -f "$d/.runner" ] || continue
      j=$(sed 's/^\xEF\xBB\xBF//' "$d/.runner" | tr -d '\n')
      n=$(echo "$j" | grep -oE '"agentName": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
      u=$(echo "$j" | grep -oE '"gitHubUrl": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
      f=$(ls -t "$d"/_diag/Worker_*.log 2>/dev/null | head -1)
      m=none; [ -n "$f" ] && m=$(stat -c %Y "$f")
      if pgrep -f "$d/bin/Runner.Listener" >/dev/null; then l=1; else l=0; fi
      echo "R|$d|$n|$u|$l|$m"
    done
    """#

    func snapshot(profile: String) async throws -> VMSnapshot {
        guard Config.isSafeName(profile) else { throw ShellError.failed(2, "unsafe name") }
        let out = try await Shell.run(bin(), ["ssh", "-p", profile, "--", "sh", "-c", Self.script], timeout: 25)
        guard let (snap, times) = VMSnapshotParser.parse(out, prevCPU: prevCPU[profile]) else {
            throw ShellError.failed(0, "unexpected output from VM")
        }
        prevCPU[profile] = times
        return snap
    }

    /// Start or stop one runner's service inside the VM. `dir` comes from discovery, never from the user.
    func setRunnerService(profile: String, dir: String, running: Bool) async throws {
        guard Config.isSafeName(profile), dir.hasPrefix("/"), Config.isSafePath(dir) else { throw ShellError.failed(2, "unsafe name") }
        _ = try await Shell.run(bin(), ["ssh", "-p", profile, "--", "sh", "-c",
                                        "cd \(dir) && sudo -n ./svc.sh \(running ? "start" : "stop")"], timeout: 60)
    }

    func restartRunner(profile: String, dir: String) async throws {
        try await setRunnerService(profile: profile, dir: dir, running: false)
        try await setRunnerService(profile: profile, dir: dir, running: true)
    }
}
