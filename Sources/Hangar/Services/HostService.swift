import Foundation

struct VMInfo: Equatable, Sendable {
    var running: Bool
    var arch: Arch
    var cpus: Int
    var memoryGB: Double
}

/// One runner directory found on a host (inside its Colima VM, or native).
struct RunnerFacts: Equatable, Sendable {
    var dir: String
    var name: String            // agentName from .runner
    var owner: String
    var repo: String
    var listenerRunning: Bool
    var lastOutputAt: Date?
    /// Cumulative CPU seconds of the runner listener and everything it started; nil if the probe could not read it.
    var cpuSeconds: Double? = nil
    /// Percent of one core since the previous poll, filled in by `HostService`.
    var runnerCPU: Double? = nil
    var diskFreeKB: Int? = nil
    var diskUsedPct: Int? = nil
    var version: String? = nil
}

enum CPURate {
    /// Percent of one core between two cumulative readings; nil when time did not advance or the counter fell
    /// (a job's processes exited, so the sum dropped).
    static func percent(prev: (seconds: Double, at: Date)?, now: (seconds: Double, at: Date)) -> Double? {
        guard let prev else { return nil }
        let dt = now.at.timeIntervalSince(prev.at), d = now.seconds - prev.seconds
        guard dt >= 1, d >= 0 else { return nil }
        return d / dt * 100
    }
}

/// Everything learned from one probe of a VM or a native macOS host.
struct VMSnapshot: Equatable, Sendable {
    var cpuPercent: Double
    var memUsedGB: Double
    var runners: [RunnerFacts]
    var hostname = ""
    var cpus: Int?              // native only; VMs get this from `colima list`
    var memTotalGB: Double?
}

/// "local" (nil target) or an SSH target.
struct HostSpec: Hashable, Sendable {
    var target: String?
    init(_ s: String) { target = s == "local" ? nil : s }
    var isLocal: Bool { target == nil }
}

enum SnapshotParser {
    /// Linux VM output: cpu line, ---, meminfo, ---, `date +%s`, `H|hostname`, then `R|dir|name|url|listener|mtime`.
    static func parseVM(_ out: String, prevCPU: ProcParser.CPUTimes?) -> (VMSnapshot, ProcParser.CPUTimes?)? {
        let parts = out.components(separatedBy: "---\n")
        guard parts.count == 3 else { return nil }
        let times = ProcParser.cpuTimes(fromStatLine: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
        var cpu = 0.0
        if let t = times, let p = prevCPU, let pct = ProcParser.cpuPercent(prev: p, now: t) { cpu = pct }
        let lines = parts[2].split(separator: "\n").map(String.init)
        let vmNow = lines.first.flatMap(TimeInterval.init)
        let snap = VMSnapshot(cpuPercent: cpu, memUsedGB: ProcParser.memUsedGB(fromMeminfo: parts[1]) ?? 0,
                              runners: runners(lines, now: vmNow), hostname: hostname(lines))
        return (snap, times)
    }

    /// macOS output: `H|`, `D|date`, `N|ncpu|memsize`, `C|cpu%`, `M|usedBytes`, `R|...`; or `NONE` when no runner dirs exist.
    static func parseNative(_ out: String) -> VMSnapshot? {
        let lines = out.split(separator: "\n").map(String.init)
        guard !lines.isEmpty, lines.first != "NONE" else { return nil }
        func field(_ p: String) -> [String]? {
            lines.first { $0.hasPrefix(p + "|") }.map { $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().map(String.init) }
        }
        let now = field("D").flatMap { $0.first }.flatMap(TimeInterval.init)
        let n = field("N")
        return VMSnapshot(cpuPercent: field("C")?.first.flatMap(Double.init).map { min(100, max(0, $0)) } ?? 0,
                          memUsedGB: (field("M")?.first.flatMap(Double.init) ?? 0) / 1_073_741_824,
                          runners: runners(lines, now: now), hostname: hostname(lines),
                          cpus: n?.first.flatMap(Int.init), memTotalGB: n.flatMap { $0.count > 1 ? Double($0[1]) : nil }.map { $0 / 1_073_741_824 })
    }

    static func hostname(_ lines: [String]) -> String {
        lines.first { $0.hasPrefix("H|") }.map { String($0.dropFirst(2)) } ?? ""
    }

    static func runners(_ lines: [String], now: TimeInterval?) -> [RunnerFacts] {
        var out: [RunnerFacts] = []
        for line in lines where line.hasPrefix("R|") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let (owner, repo) = ownerRepo(fromURL: f[3]), !f[2].isEmpty else { continue }
            var last: Date?
            if let m = TimeInterval(f[5]), let now { last = Date(timeIntervalSinceNow: -(now - m)) }
            out.append(RunnerFacts(dir: f[1], name: f[2], owner: owner, repo: repo, listenerRunning: f[4] == "1", lastOutputAt: last,
                                   cpuSeconds: f.count > 6 ? Double(f[6]) : nil,
                                   diskFreeKB: f.count > 7 ? Int(f[7]) : nil, diskUsedPct: f.count > 8 ? Int(f[8]) : nil,
                                   version: f.count > 9 && !f[9].isEmpty ? f[9] : nil))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func ownerRepo(fromURL url: String) -> (String, String)? {
        let c = url.split(separator: "/").map(String.init)
        guard c.count >= 2, Config.isSafeName(c[c.count - 2]), Config.isSafeName(c[c.count - 1]) else { return nil }
        return (c[c.count - 2], c[c.count - 1])
    }

    /// "mac-mini.local" -> "mac-mini".
    static func shortName(_ h: String) -> String { h.split(separator: ".").first.map(String.init) ?? h }
}

/// Runs commands on this Mac or over SSH (key auth only; BatchMode never prompts for a password).
actor HostService {
    private let colima = Shell.find("colima")
    private var prevCPU: [String: ProcParser.CPUTimes] = [:]
    private var prevRunnerCPU: [String: (seconds: Double, at: Date)] = [:]
    private static let remotePath = "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; "

    // Probe scripts only read: counters, the runner dirs' .runner (name and repo URL, never credentials),
    // listener process, newest worker log mtime. BOM stripped with tr so it works with BSD and GNU tools.
    /// Sums CPU time (the third column of `ps -o pid=,ppid=,<cpu time>=`) over `root` and all its descendants.
    /// Accepts plain seconds (Linux `cputimes`) and `m:ss.ss` / `h:mm:ss` (macOS `time`).
    static let treeAwk = #"""
    function secs(s, n, a, v, i) { n = split(s, a, ":"); v = 0; for (i = 1; i <= n; i++) v = v * 60 + a[i]; return v } { pid[NR] = $1; par[$1] = $2; tm[NR] = $3; N = NR } END { total = 0; for (i = 1; i <= N; i++) { p = pid[i]; k = 0; while (p != "" && p != 0 && k < 40) { if (p == root) { total += secs(tm[i]); break } p = par[p]; k++ } } printf "%.2f", total }
    """#

    private static let runnerLoop = #"""
    ps_all=$(PSCMD)
    for d in "$HOME"/actions-runner*; do
      [ -f "$d/.runner" ] || continue
      j=$(tr -d '\357\273\277\n' < "$d/.runner")
      n=$(echo "$j" | grep -oE '"agentName": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
      u=$(echo "$j" | grep -oE '"gitHubUrl": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
      f=$(ls -t "$d"/_diag/Worker_*.log 2>/dev/null | head -1)
      m=none; if [ -n "$f" ]; then m=$(STATCMD "$f"); fi
      if pgrep -f "$d/bin/Runner.Listener" >/dev/null; then l=1; else l=0; fi
      lp=$(pgrep -f "$d/bin/Runner.Listener" | head -1)
      t=none
      if [ -n "$lp" ]; then
        t=$(echo "$ps_all" | awk -v root="$lp" 'TREEAWK')
      fi
      dfo=$(df -Pk "$d" 2>/dev/null | tail -1)
      dfree=$(echo "$dfo" | awk '{print $4}'); dpct=$(echo "$dfo" | awk '{print $5}' | tr -d '%')
      ver=$(grep -o '"Runner.Listener/[0-9.]*"' "$d/bin/Runner.Listener.deps.json" 2>/dev/null | head -1 | sed 's/.*\///;s/"//')
      echo "R|$d|$n|$u|$l|$m|$t|$dfree|$dpct|$ver"
    done
    """#.replacingOccurrences(of: "TREEAWK", with: treeAwk)

    private static let vmScript = #"""
    head -1 /proc/stat; echo ---; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; echo ---; date +%s
    echo "H|$(hostname)"
    """# + "\n" + runnerLoop.replacingOccurrences(of: "STATCMD", with: "stat -c %Y")
        .replacingOccurrences(of: "PSCMD", with: "ps -eo pid=,ppid=,cputimes=")

    private static let nativeScript = #"""
    export PATH=$PATH:/usr/sbin:/sbin
    set -- "$HOME"/actions-runner*/.runner
    if [ ! -f "$1" ]; then echo NONE; exit 0; fi
    echo "H|$(hostname)"; echo "D|$(date +%s)"
    echo "N|$(sysctl -n hw.ncpu)|$(sysctl -n hw.memsize)"
    echo "C|$(top -l 2 -n 0 -s 1 | awk '/CPU usage/ {l=$0} END {split(l,a," "); gsub("%","",a[7]); print 100-a[7]}')"
    echo "M|$(vm_stat | awk '/page size of/ {ps=$8} /^Pages active/ {a=$3} /^Pages wired down/ {w=$4} /^Pages occupied by compressor/ {c=$5} END {printf "%.0f", (a+w+c)*ps}')"
    """# + "\n" + runnerLoop.replacingOccurrences(of: "STATCMD", with: "stat -f %m")
        .replacingOccurrences(of: "PSCMD", with: "ps -axo pid=,ppid=,time=")

    private func ssh(_ target: String, _ command: String, stdin: String? = nil, timeout: TimeInterval = 25) async throws -> String {
        try await Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", target, command],
                            stdin: stdin, timeout: timeout)
    }

    private func colimaBin() throws -> String {
        guard let colima else { throw ShellError.notFound("colima") }
        return colima
    }

    /// `colima list --json` prints one JSON object per line.
    func listVMs(_ host: HostSpec) async throws -> [String: VMInfo] {
        let out: String
        if let t = host.target { out = try await ssh(t, Self.remotePath + "colima list --json") }
        else { out = try await Shell.run(colimaBin(), ["list", "--json"]) }
        var result: [String: VMInfo] = [:]
        for line in out.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = d["name"] as? String else { continue }
            let status = (d["status"] as? String ?? "").lowercased()
            let arch: Arch = (d["arch"] as? String ?? "").contains("x86") ? .x86 : .arm64
            result[name] = VMInfo(running: status == "running", arch: arch, cpus: d["cpus"] as? Int ?? 0,
                                  memoryGB: ((d["memory"] as? Double) ?? 0) / 1_073_741_824)
        }
        return result
    }

    func vmSnapshot(_ host: HostSpec, profile: String) async throws -> VMSnapshot {
        guard Config.isSafeName(profile) else { throw ShellError.failed(2, "unsafe name") }
        let out: String
        if let t = host.target { out = try await ssh(t, Self.remotePath + "colima ssh -p \(profile) -- sh -s", stdin: Self.vmScript) }
        else { out = try await Shell.run(colimaBin(), ["ssh", "-p", profile, "--", "sh", "-s"], stdin: Self.vmScript, timeout: 25) }
        let key = "\(host.target ?? "local")/\(profile)"
        guard let (snap, times) = SnapshotParser.parseVM(out, prevCPU: prevCPU[key]) else {
            throw ShellError.failed(0, "unexpected output from VM")
        }
        prevCPU[key] = times
        return withRunnerCPU(snap, key: key)
    }

    /// nil when the host has no native runner dirs.
    func nativeSnapshot(_ host: HostSpec) async throws -> VMSnapshot? {
        let out: String
        if let t = host.target { out = try await ssh(t, "sh -s", stdin: Self.nativeScript, timeout: 30) }
        else { out = try await Shell.run("/bin/sh", ["-s"], stdin: Self.nativeScript, timeout: 30) }
        return SnapshotParser.parseNative(out).map { withRunnerCPU($0, key: "\(host.target ?? "local")/native") }
    }

    /// Turns each runner's cumulative CPU seconds into a rate against the previous poll.
    private func withRunnerCPU(_ snap: VMSnapshot, key: String) -> VMSnapshot {
        var s = snap
        let now = Date()
        s.runners = s.runners.map { r in
            var r = r
            guard let secs = r.cpuSeconds else { return r }
            let k = "\(key)/\(r.dir)"
            r.runnerCPU = CPURate.percent(prev: prevRunnerCPU[k], now: (secs, now))
            prevRunnerCPU[k] = (secs, now)
            return r
        }
        return s
    }

    /// Start or stop one runner's service. `dir` and `profile` come from discovery, never from the user.
    func setService(_ host: HostSpec, profile: String?, dir: String, running: Bool) async throws {
        guard dir.hasPrefix("/"), Config.isSafePath(dir), profile.map(Config.isSafeName) ?? true else { throw ShellError.failed(2, "unsafe name") }
        let verb = running ? "start" : "stop"
        let inner = profile == nil ? "cd '\(dir)' && ./svc.sh \(verb)" : "cd '\(dir)' && sudo -n ./svc.sh \(verb)"
        if let t = host.target {
            let cmd = profile.map { Self.remotePath + "colima ssh -p \($0) -- sh -c \"\(inner)\"" } ?? inner
            _ = try await ssh(t, cmd, timeout: 60)
        } else if let p = profile {
            _ = try await Shell.run(colimaBin(), ["ssh", "-p", p, "--", "sh", "-c", inner], timeout: 60)
        } else {
            _ = try await Shell.run("/bin/sh", ["-c", inner], timeout: 60)
        }
    }

    func restartRunner(_ host: HostSpec, profile: String?, dir: String) async throws {
        try await setService(host, profile: profile, dir: dir, running: false)
        try await setService(host, profile: profile, dir: dir, running: true)
    }
}
