import Foundation

public enum PlaybackState: Sendable, Equatable {
    case idle
    case preparing
    case playing
    case paused
    case seeking
    case ended
    case failed(String)

    public enum Event: Sendable, Equatable {
        case prepare
        case started
        case paused
        case resumed
        case seekBegan
        case seekEnded(playing: Bool)
        case reachedEnd
        case failed(String)
        case stopped
    }

    /// Next state for `event`; events that make no sense in the current state are ignored.
    public func applying(_ event: Event) -> PlaybackState {
        switch (self, event) {
        case (_, .failed(let message)): return .failed(message)
        case (_, .stopped): return .idle
        case (.idle, .prepare), (.ended, .prepare), (.failed, .prepare): return .preparing
        case (.preparing, .started): return .playing
        case (.playing, .paused): return .paused
        case (.paused, .resumed): return .playing
        case (.playing, .seekBegan), (.paused, .seekBegan), (.ended, .seekBegan): return .seeking
        case (.seeking, .seekEnded(let playing)): return playing ? .playing : .paused
        case (.playing, .reachedEnd), (.paused, .reachedEnd): return .ended
        default: return self
        }
    }

    public var symbol: String {
        switch self {
        case .idle: return "■"
        case .preparing: return "…"
        case .playing: return "▶"
        case .paused: return "❚❚"
        case .seeking: return "»"
        case .ended: return "■"
        case .failed: return "✕"
        }
    }
}

public enum SeekDecision: Sendable, Equatable {
    /// Seek inside the stream already being served, to this many seconds into it.
    case inPlace(Double)
    /// Restart ffmpeg at this absolute position in the source file.
    case restart(Double)
}

public enum SeekPlanner {
    /// Decides whether `target` (seconds into the source) is reachable in the current HLS generation.
    /// A margin of two segments keeps players from seeking into a segment ffmpeg has not finished writing.
    public static func decide(
        target: Double,
        mediaDuration: Double,
        generationStart: Double,
        available: Double,
        complete: Bool,
        segmentSeconds: Double = Double(TranscodePlan.segmentSeconds)
    ) -> SeekDecision {
        let clamped = min(max(target, 0), max(0, mediaDuration - 1))
        let relative = clamped - generationStart
        let limit = complete ? available : available - 2 * segmentSeconds
        if relative >= 0 && relative <= limit {
            return .inPlace(relative)
        }
        return .restart(clamped)
    }
}
