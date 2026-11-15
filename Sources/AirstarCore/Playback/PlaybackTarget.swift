import Foundation

/// What a playback destination reports about the stream it is playing.
public struct TargetStatus: Sendable, Equatable {
    /// Seconds into the currently loaded stream (not the source file).
    public var position: Double
    public var isPlaying: Bool
    public var isReady: Bool
    /// True once a receiver that was playing reports that nothing is loaded any more.
    public var isIdle: Bool
    public var error: String?

    public init(position: Double = 0, isPlaying: Bool = false, isReady: Bool = false, isIdle: Bool = false, error: String? = nil) {
        self.position = position
        self.isPlaying = isPlaying
        self.isReady = isReady
        self.isIdle = isIdle
        self.error = error
    }
}

/// A destination that can play an HLS URL: the local AVPlayer window or an AirPlay receiver.
public protocol PlaybackTarget: AnyObject, Sendable {
    var displayName: String { get }
    /// Loads and starts an HLS playlist whose segments use `segmentFormat`.
    func load(url: URL, segmentFormat: SegmentFormat) async throws
    func play() async throws
    func pause() async throws
    /// Seeks within the currently loaded stream.
    func seek(to seconds: Double) async throws
    /// Returns false when the destination ignores volume changes.
    func setVolume(_ fraction: Double) async throws -> Bool
    func status() async throws -> TargetStatus
    func stop() async
}

/// Plays on an AirPlay receiver through `AirPlayClient`.
public final class AirPlayTarget: PlaybackTarget {
    public let client: AirPlayClient
    public let displayName: String

    public init(client: AirPlayClient, displayName: String) {
        self.client = client
        self.displayName = displayName
    }

    public func load(url: URL, segmentFormat: SegmentFormat) async throws {
        try await client.play(url: url)
    }

    public func play() async throws {
        try await client.setRate(1)
    }

    public func pause() async throws {
        try await client.setRate(0)
    }

    public func seek(to seconds: Double) async throws {
        try await client.scrub(to: seconds)
    }

    public func setVolume(_ fraction: Double) async throws -> Bool {
        try await client.setVolume(fraction)
    }

    public func status() async throws -> TargetStatus {
        let info = try await client.playbackInfo()
        return TargetStatus(
            position: info.position ?? 0,
            isPlaying: (info.rate ?? 0) > 0,
            isReady: info.readyToPlay,
            isIdle: info.duration == nil && !info.readyToPlay,
            error: info.errorDescription
        )
    }

    public func stop() async {
        await client.stop()
        await client.close()
    }
}
