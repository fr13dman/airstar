import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum ProcessRunner {
    /// Runs a process to completion and captures its output.
    public static func run(_ executable: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let collector = OutputCollector()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.appendStdout(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.appendStderr(handle.availableData)
            }
            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                collector.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                collector.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let (out, err) = collector.snapshot()
                continuation.resume(returning: ProcessResult(status: proc.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Last `lines` lines of a process's stderr, for error messages.
    public static func tail(_ data: Data, lines: Int = 8) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) { lock.withLock { stdout.append(data) } }
    func appendStderr(_ data: Data) { lock.withLock { stderr.append(data) } }
    func snapshot() -> (Data, Data) { lock.withLock { (stdout, stderr) } }
}
