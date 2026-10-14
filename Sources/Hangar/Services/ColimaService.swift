import Foundation

struct VMInfo: Equatable, Sendable {
    var running: Bool
    var arch: Arch
    var cpus: Int
    var memoryGB: Double
}

struct VMSample: Equatable, Sendable {
    var cpuPercent: Double
    var memUsedGB: Double
    var lastOutputAt: Date?
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

    /// One ssh round trip: CPU counters, memory, newest runner worker log mtime, VM clock.
    func sample(profile: String, runnerDir: String) async throws -> VMSample {
        guard Config.isSafeName(profile), Config.isSafePath(runnerDir) else { throw ShellError.failed(2, "unsafe name") }
        let dir = runnerDir.hasPrefix("~/") ? "$HOME/" + runnerDir.dropFirst(2) : runnerDir
        let script = """
        head -1 /proc/stat; echo ---; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; echo ---; \
        f=$(ls -t \(dir)/_diag/Worker_*.log 2>/dev/null | head -1); \
        if [ -n "$f" ]; then stat -c %Y "$f"; else echo none; fi; date +%s
        """
        let out = try await Shell.run(bin(), ["ssh", "-p", profile, "--", "sh", "-c", script], timeout: 25)
        let parts = out.components(separatedBy: "---\n")
        guard parts.count == 3 else { throw ShellError.failed(0, "unexpected output") }
        let times = ProcParser.cpuTimes(fromStatLine: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
        var cpu = 0.0
        if let t = times {
            if let p = prevCPU[profile], let pct = ProcParser.cpuPercent(prev: p, now: t) { cpu = pct }
            prevCPU[profile] = t
        }
        let tail = parts[2].split(separator: "\n").map(String.init)
        var last: Date?
        if tail.count >= 2, let mtime = TimeInterval(tail[0]), let vmNow = TimeInterval(tail[1]) {
            last = Date(timeIntervalSinceNow: -(vmNow - mtime))   // age is clock-skew proof
        }
        return VMSample(cpuPercent: cpu, memUsedGB: ProcParser.memUsedGB(fromMeminfo: parts[1]) ?? 0, lastOutputAt: last)
    }

    func restart(profile: String) async throws {
        guard Config.isSafeName(profile) else { throw ShellError.failed(2, "unsafe name") }
        _ = try await Shell.run(bin(), ["restart", "-p", profile], timeout: 300)
        prevCPU[profile] = nil
    }

    /// Start or stop the runner service inside the VM.
    func setRunnerService(profile: String, runnerDir: String, running: Bool) async throws {
        guard Config.isSafeName(profile), Config.isSafePath(runnerDir) else { throw ShellError.failed(2, "unsafe name") }
        let dir = runnerDir.hasPrefix("~/") ? "$HOME/" + runnerDir.dropFirst(2) : runnerDir
        _ = try await Shell.run(bin(), ["ssh", "-p", profile, "--", "sh", "-c",
                                        "cd \(dir) && sudo ./svc.sh \(running ? "start" : "stop")"], timeout: 60)
    }
}
