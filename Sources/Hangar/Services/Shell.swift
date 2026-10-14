import Foundation

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

enum ShellError: Error, Equatable { case notFound(String), timedOut, failed(Int32, String) }

/// Runs a binary with an argument array (never a shell string) and returns stdout.
enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: ShellError.notFound(path)); return }
                let timedOutFlag = Flag()
                let timer = DispatchWorkItem { if p.isRunning { timedOutFlag.set(); p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Drain both pipes before waiting so a chatty child cannot deadlock on a full pipe.
                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                p.waitUntilExit()
                timer.cancel()
                if timedOutFlag.value { cont.resume(throwing: ShellError.timedOut); return }
                let text = String(decoding: data, as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume(returning: text) }
                else { cont.resume(throwing: ShellError.failed(p.terminationStatus, String(decoding: errData, as: UTF8.self))) }
            }
        }
    }

    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
