import Foundation
import Darwin

/// Optional command-line helpers. Finder-launched apps have a minimal PATH.
public enum ExternalTools {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    public static func locate(_ name: String) -> URL? {
        var dirs = searchDirectories
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public struct Output: Sendable {
        public var status: Int32
        public var standardError: String
        public var standardOutput: String
    }

    /// Drains both pipes concurrently; cancellation is latched even before process launch.
    /// A helper which ignores SIGTERM is killed after one second.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String]) async throws -> Output {
        try Task.checkCancellation()
        let runner = ProcessRunner(executable: executable, arguments: arguments)
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                runner.start(continuation)
            }
        } onCancel: {
            runner.cancel()
        }
        try Task.checkCancellation()
        return output
    }

    public static func runChecked(_ executable: URL, _ arguments: [String]) async throws {
        let result = try await run(executable, arguments)
        guard result.status == 0 else {
            let tail = result.standardError.split(separator: "\n").suffix(12).joined(separator: "\n")
            let reason = tail.isEmpty ? "进程没有返回错误详情。" : tail
            let codecHint = tail.localizedCaseInsensitiveContains("unknown encoder") || tail.contains("Encoder not found")
                ? " 当前 FFmpeg 缺少所需编码器，请使用包含此编码器的 FFmpeg 构建。" : ""
            throw KumquatError.processFailed("\(executable.lastPathComponent) 失败（退出码 \(result.status)）。\(codecHint)\n\(reason)")
        }
    }
}

private final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<ExternalTools.Output, Error>) {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let out = ProcessOutputCollector(), err = ProcessOutputCollector()
        let readers = DispatchGroup()
        for (pipe, collector) in [(stdout, out), (stderr, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    collector.append(data)
                }
                try? pipe.fileHandleForReading.close()
                readers.leave()
            }
        }
        process.terminationHandler = { process in
            // Waiting for EOF also makes the final diagnostics deterministic.
            readers.notify(queue: .global(qos: .utility)) {
                continuation.resume(returning: .init(status: process.terminationStatus,
                                                     standardError: err.text, standardOutput: out.text))
            }
        }
        lock.lock()
        do {
            if cancelled { throw CancellationError() }
            try process.run()
            lock.unlock()
        } catch {
            process.terminationHandler = nil
            lock.unlock()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            readers.notify(queue: .global(qos: .utility)) { continuation.resume(throwing: error) }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        guard running else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private var truncated = false
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 1_048_576 {
            data = data.suffix(1_048_576)
            truncated = true
        }
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return (truncated ? "[output truncated]\n" : "") + String(decoding: data, as: UTF8.self)
    }
}
