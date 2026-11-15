import Foundation

public enum AirstarError: Error, LocalizedError, Equatable {
    case toolNotFound(String)
    case processFailed(tool: String, status: Int32, stderrTail: String)
    case invalidMedia(String)
    case noVideoStream
    case noAudioTrackMatching(String)
    case deviceNotFound(String)
    case ambiguousDevice(String, matches: [String])
    case deviceLacksVideoSupport(String)
    case pairingRequired(String)
    case pairingFailed(String)
    case protocolError(String)
    case connectionFailed(String)
    case timeout(String)
    case playbackFailed(String)
    case urlPlaybackUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) was not found. Install it with: brew install ffmpeg"
        case .processFailed(let tool, let status, let tail):
            return "\(tool) exited with status \(status)\(tail.isEmpty ? "" : ":\n\(tail)")"
        case .invalidMedia(let reason):
            return "Could not read media: \(reason)"
        case .noVideoStream:
            return "The file has no video stream."
        case .noAudioTrackMatching(let selector):
            return "No audio track matches '\(selector)'. Run `airstar-cli info <file>` to list tracks."
        case .deviceNotFound(let query):
            return "No AirPlay device matching '\(query)' was found. Run `airstar-cli devices` to list receivers."
        case .ambiguousDevice(let query, let matches):
            return "'\(query)' matches several devices: \(matches.joined(separator: ", ")). Use a more specific name or the device ID."
        case .deviceLacksVideoSupport(let name):
            return "\(name) does not advertise AirPlay HLS video playback."
        case .pairingRequired(let name):
            return "\(name) requires pairing. Run `airstar-cli pair \"\(name)\"` first (and check the TV's AirPlay setting allows new devices)."
        case .pairingFailed(let reason):
            return "Pairing failed: \(reason)"
        case .protocolError(let reason):
            return "AirPlay protocol error: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .timeout(let what):
            return "Timed out waiting for \(what)."
        case .playbackFailed(let reason):
            return "Playback failed: \(reason)"
        case .urlPlaybackUnsupported(let name):
            return "\(name) paired successfully but has no AirPlay URL-playback endpoint (/play returned 404). TVs built on Apple's AirPlay SDK only take video through Apple's private AirPlay 2 video protocol, which airstar-cli does not implement."
        }
    }
}

/// Runs `operation`, throwing `AirstarError.timeout` if it does not finish within `seconds`.
public func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ what: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AirstarError.timeout(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
