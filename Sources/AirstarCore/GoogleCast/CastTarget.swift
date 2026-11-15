import Foundation

/// Plays on a Google Cast device through the Default Media Receiver.
public final class CastTarget: PlaybackTarget {
    public let client: CastClient
    public let displayName: String
    let title: String
    private let launchState = LaunchState()

    public init(client: CastClient, displayName: String, title: String) {
        self.client = client
        self.displayName = displayName
        self.title = title
    }

    public func load(url: URL, segmentFormat: SegmentFormat) async throws {
        if launchState.needsLaunch() {
            try await client.launch()
        }
        try await client.load(url: url, segmentFormat: segmentFormat, title: title)
    }

    public func play() async throws { try await client.play() }
    public func pause() async throws { try await client.pause() }
    public func seek(to seconds: Double) async throws { try await client.seek(to: seconds) }

    public func setVolume(_ fraction: Double) async throws -> Bool {
        try await client.setVolume(fraction)
        return true
    }

    public func status() async throws -> TargetStatus {
        Self.targetStatus(from: try await client.status())
    }

    public func stop() async {
        await client.stop()
    }

    /// BUFFERING counts as neither playing nor ready, so the controller keeps its current state meanwhile.
    static func targetStatus(from status: CastMediaStatus) -> TargetStatus {
        TargetStatus(
            position: status.currentTime,
            isPlaying: status.playerState == "PLAYING",
            isReady: status.playerState == "PLAYING" || status.playerState == "PAUSED",
            isIdle: status.playerState == "IDLE",
            error: status.idleReason == "ERROR" ? "the Cast receiver could not play the stream" : nil
        )
    }

    private final class LaunchState: @unchecked Sendable {
        private let lock = NSLock()
        private var launched = false

        func needsLaunch() -> Bool {
            lock.withLock {
                defer { launched = true }
                return !launched
            }
        }
    }
}
