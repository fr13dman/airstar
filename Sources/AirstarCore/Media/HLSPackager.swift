import Foundation

/// One ffmpeg run writing an HLS playlist that starts at `startOffset` seconds into the source file.
public struct HLSGeneration: Sendable, Equatable {
    public let number: Int
    public let directory: URL
    public let startOffset: Double
    public let plan: TranscodePlan

    /// Path of the playlist relative to the packager's root, used to build the HTTP URL.
    public var playlistPath: String { "gen-\(number)/\(HLSPackager.playlistName)" }
}

public struct PackagerProgress: Sendable, Equatable {
    /// Seconds of output available, counted from the generation's start offset.
    public let availableDuration: Double
    public let isComplete: Bool
}

/// Runs ffmpeg to turn the source file into an fMP4 HLS event playlist under a temporary root directory.
/// Each seek past the transcoded range or audio-track change starts a new generation in its own folder.
public actor HLSPackager {
    public static let playlistName = "index.m3u8"
    static let minimumSegmentsBeforeReady = 2

    public nonisolated let root: URL
    let input: URL
    let tools: FFmpegTools
    private var process: Process?
    private var stderrBuffer: OutputCollector?
    private var generationCount = 0
    public private(set) var current: HLSGeneration?

    public init(input: URL, tools: FFmpegTools, root: URL? = nil) throws {
        self.input = input
        self.tools = tools
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("airstar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// Starts ffmpeg for `plan` at `startOffset` and waits until the playlist is playable.
    @discardableResult
    public func start(plan: TranscodePlan, at startOffset: Double = 0, readyTimeout: Double = 30) async throws -> HLSGeneration {
        await stopProcess()
        generationCount += 1
        let directory = root.appendingPathComponent("gen-\(generationCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeGenerations(olderThan: generationCount - 1)

        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = plan.ffmpegArguments(input: input, outputDirectory: directory, startAt: startOffset)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        let collector = OutputCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendStderr(data)
            }
        }
        process.standardError = stderrPipe
        try process.run()
        self.process = process
        self.stderrBuffer = collector

        let generation = HLSGeneration(number: generationCount, directory: directory, startOffset: startOffset, plan: plan)
        current = generation
        try await waitUntilReady(generation, process: process, collector: collector, timeout: readyTimeout)
        return generation
    }

    /// Progress of the current generation, read from its playlist.
    public func progress() -> PackagerProgress {
        guard let current, let playlist = readPlaylist(current) else {
            return PackagerProgress(availableDuration: 0, isComplete: false)
        }
        return PackagerProgress(availableDuration: playlist.totalDuration, isComplete: playlist.isComplete)
    }

    /// Error output if ffmpeg exited unsuccessfully.
    public func failure() -> AirstarError? {
        guard let process, !process.isRunning, process.terminationStatus != 0 else { return nil }
        let stderr = stderrBuffer?.snapshot().1 ?? Data()
        return .processFailed(tool: "ffmpeg", status: process.terminationStatus, stderrTail: ProcessRunner.tail(stderr))
    }

    public func stop() async {
        await stopProcess()
    }

    /// Stops ffmpeg and deletes every generated file.
    public func cleanup() async {
        await stopProcess()
        try? FileManager.default.removeItem(at: root)
    }

    /// `Process.waitUntilExit()` can block forever on a cooperative-pool thread with no run loop, so poll instead.
    private func stopProcess() async {
        guard let process else { return }
        self.process = nil
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func readPlaylist(_ generation: HLSGeneration) -> HLSPlaylist? {
        let url = generation.directory.appendingPathComponent(Self.playlistName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return HLSPlaylist.parse(text)
    }

    private func waitUntilReady(_ generation: HLSGeneration, process: Process, collector: OutputCollector, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let playlist = readPlaylist(generation),
               playlist.isComplete || playlist.segmentCount >= Self.minimumSegmentsBeforeReady {
                return
            }
            if !process.isRunning {
                if process.terminationStatus != 0 {
                    let stderr = ProcessRunner.tail(collector.snapshot().1)
                    throw AirstarError.processFailed(tool: "ffmpeg", status: process.terminationStatus, stderrTail: stderr)
                }
                if readPlaylist(generation) != nil { return }
                throw AirstarError.processFailed(tool: "ffmpeg", status: 0, stderrTail: "no playlist was written")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AirstarError.timeout("ffmpeg to produce the first HLS segments")
    }

    private func removeGenerations(olderThan number: Int) {
        guard number > 1 else { return }
        for old in 1..<number {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("gen-\(old)", isDirectory: true))
        }
    }
}
