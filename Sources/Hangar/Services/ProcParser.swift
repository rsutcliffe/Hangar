import Foundation

/// Parses `/proc/stat` and `/proc/meminfo` text captured from inside a Colima VM.
enum ProcParser {
    struct CPUTimes: Equatable, Sendable { var idle: UInt64; var total: UInt64 }

    static func cpuTimes(fromStatLine line: String) -> CPUTimes? {
        let f = line.split(separator: " ").map(String.init)
        guard f.first == "cpu", f.count >= 5 else { return nil }
        let n = f.dropFirst().compactMap(UInt64.init)
        guard n.count >= 4 else { return nil }
        let idle = n[3] + (n.count > 4 ? n[4] : 0)      // idle + iowait
        return CPUTimes(idle: idle, total: n.prefix(8).reduce(0, +))
    }

    /// Busy percentage between two samples; nil if no time elapsed.
    static func cpuPercent(prev: CPUTimes, now: CPUTimes) -> Double? {
        guard now.total > prev.total else { return nil }
        let dt = Double(now.total - prev.total)
        let di = Double(now.idle >= prev.idle ? now.idle - prev.idle : 0)
        return min(100, max(0, (1 - di / dt) * 100))
    }

    /// Used GB = MemTotal - MemAvailable.
    static func memUsedGB(fromMeminfo text: String) -> Double? {
        func kb(_ key: String) -> Double? {
            for l in text.split(separator: "\n") where l.hasPrefix(key + ":") {
                let digits = l.split(separator: " ").dropFirst().first
                return digits.flatMap { Double($0) }
            }
            return nil
        }
        guard let total = kb("MemTotal"), let avail = kb("MemAvailable") else { return nil }
        return max(0, (total - avail) / 1024 / 1024)
    }
}
