import Foundation

/// What the status line shows.
public struct PlayerSnapshot: Sendable, Equatable {
    public var state: PlaybackState
    /// Seconds into the source file.
    public var position: Double
    public var duration: Double
    public var volume: Double
    public var audioLabel: String?
    public var targetName: String
    public var message: String?
}

/// Drives one playback session: packages the file with ffmpeg, serves it, and steers the target
/// (local window or AirPlay receiver) in response to keyboard commands.
public actor PlaybackController {
    let input: URL
    let media: MediaInfo
    let packager: HLSPackager
    let server: MediaHTTPServer
    let urlHost: String
    let target: PlaybackTarget
    let capabilities: ReceiverCapabilities

    public private(set) var plan: TranscodePlan
    public private(set) var state: PlaybackState = .idle
    private(set) var generation: HLSGeneration?
    private var position: Double = 0
    private var volume: Double = 1
    private var message: String?
    private var messageExpiry = Date.distantPast
    private var sawPlayback = false
    /// Pending check that an in-place seek actually moved the target.
    private var seekCheck: (target: Double, due: Date)?
    /// Set once the target ignores an in-place seek; later seeks restart ffmpeg instead.
    private(set) var inPlaceSeekUnreliable = false
    let seekVerificationDelay: Double

    public init(
        input: URL,
        media: MediaInfo,
        audio: AudioSelection,
        capabilities: ReceiverCapabilities,
        packager: HLSPackager,
        server: MediaHTTPServer,
        urlHost: String,
        target: PlaybackTarget,
        seekVerificationDelay: Double = 1.5
    ) throws {
        self.input = input
        self.media = media
        self.capabilities = capabilities
        self.packager = packager
        self.server = server
        self.urlHost = urlHost
        self.target = target
        self.seekVerificationDelay = seekVerificationDelay
        self.plan = try TranscodePlanner.plan(for: media, audio: audio, capabilities: capabilities)
    }

    public func start() async throws {
        state = state.applying(.prepare)
        do {
            try await begin(at: 0)
        } catch {
            state = state.applying(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Applies a keyboard command. Returns true when the session should end.
    public func handle(_ command: PlayerCommand) async -> Bool {
        do {
            switch command {
            case .quit:
                return true
            case .togglePause:
                try await togglePause()
            case .seek(let delta):
                try await seek(to: position + delta)
            case .volume(let delta):
                try await changeVolume(by: delta)
            case .cycleAudio:
                try await cycleAudio()
            }
        } catch {
            show(error.localizedDescription)
        }
        return false
    }

    /// Polls the target and packager; call a couple of times per second.
    public func tick() async -> PlayerSnapshot {
        if let failure = await packager.failure() {
            state = state.applying(.failed(failure.localizedDescription))
        }
        if case .failed = state { return snapshot() }

        if let status = try? await target.status(), let generation {
            if let error = status.error {
                state = state.applying(.failed(error))
                return snapshot()
            }
            if status.isReady || status.position > 0 {
                position = generation.startOffset + status.position
            }
            if status.isPlaying {
                sawPlayback = true
                switch state {
                case .preparing: state = state.applying(.started)
                case .paused: state = state.applying(.resumed)
                case .seeking: state = state.applying(.seekEnded(playing: true))
                default: break
                }
            } else if status.isReady {
                switch state {
                case .playing: state = state.applying(.paused)
                case .seeking: state = state.applying(.seekEnded(playing: false))
                default: break
                }
            }
            let progress = await packager.progress()
            let atEnd = progress.isComplete && status.position >= progress.availableDuration - 1.5
            if sawPlayback && !status.isPlaying && (atEnd || status.isIdle) {
                state = state.applying(.reachedEnd)
            }
            await verifySeek()
        }
        return snapshot()
    }

    /// Some receivers (e.g. ones that treated the growing playlist as live) acknowledge `/scrub`
    /// but keep playing from the old position. Detect that and restart the stream at the target.
    private func verifySeek() async {
        guard let check = seekCheck, Date() >= check.due else { return }
        seekCheck = nil
        guard abs(position - check.target) > 5 else { return }
        inPlaceSeekUnreliable = true
        show("\(target.displayName) ignored the seek; restarting at \(StatusFormatter.time(check.target))…")
        state = state.applying(.seekBegan)
        do {
            try await begin(at: check.target)
        } catch {
            state = state.applying(.failed(error.localizedDescription))
        }
    }

    public func snapshot() -> PlayerSnapshot {
        if Date() > messageExpiry { message = nil }
        return PlayerSnapshot(
            state: state,
            position: position,
            duration: media.duration,
            volume: volume,
            audioLabel: plan.audio?.label,
            targetName: target.displayName,
            message: message
        )
    }

    /// Stops the target, ffmpeg and the HTTP server, and deletes temporary files.
    public func shutdown() async {
        await target.stop()
        await packager.cleanup()
        server.stop()
        state = state.applying(.stopped)
    }

    // MARK: Commands

    private func begin(at offset: Double) async throws {
        let generation = try await packager.start(plan: plan, at: offset)
        self.generation = generation
        guard let url = server.url(for: generation.playlistPath, host: urlHost) else {
            throw AirstarError.playbackFailed("HTTP server is not running")
        }
        try await target.load(url: url, segmentFormat: generation.plan.segmentFormat)
        position = offset
        sawPlayback = false
        seekCheck = nil
    }

    private func togglePause() async throws {
        switch state {
        case .playing:
            try await target.pause()
            state = state.applying(.paused)
        case .paused:
            try await target.play()
            state = state.applying(.resumed)
        case .ended:
            state = state.applying(.prepare)
            try await begin(at: 0)
        default:
            break
        }
    }

    private func seek(to absolute: Double) async throws {
        guard let generation else { return }
        let progress = await packager.progress()
        var decision = SeekPlanner.decide(
            target: absolute,
            mediaDuration: media.duration,
            generationStart: generation.startOffset,
            available: progress.availableDuration,
            complete: progress.isComplete
        )
        if inPlaceSeekUnreliable, case .inPlace(let relative) = decision {
            decision = .restart(generation.startOffset + relative)
        }
        state = state.applying(.seekBegan)
        switch decision {
        case .inPlace(let relative):
            // Seeking keeps the current rate on both AVPlayer and AirPlay receivers; sending a play/rate
            // right after a scrub makes some receivers resume from the old position.
            try await target.seek(to: relative)
            position = generation.startOffset + relative
            seekCheck = (position, Date().addingTimeInterval(seekVerificationDelay))
        case .restart(let offset):
            show("Transcoding from \(StatusFormatter.time(offset))…")
            try await begin(at: offset)
        }
    }

    private func changeVolume(by delta: Double) async throws {
        let next = min(max(volume + delta, 0), 1)
        if try await target.setVolume(next) {
            volume = next
            show("Volume \(Int((next * 100).rounded()))%")
        } else {
            show("\(target.displayName) does not accept volume changes; use the TV remote")
        }
    }

    private func cycleAudio() async throws {
        let tracks = media.audioStreams
        guard tracks.count > 1 else {
            show("Only one audio track")
            return
        }
        let current = plan.audio?.trackNumber ?? 0
        let next = tracks.first(where: { $0.trackNumber > current }) ?? tracks[0]
        plan = try TranscodePlanner.plan(for: media, audio: .track(next.trackNumber), capabilities: capabilities)
        show("Audio \(next.label)")
        state = state.applying(.seekBegan)
        try await begin(at: position)
    }

    private func show(_ text: String) {
        message = text
        messageExpiry = Date().addingTimeInterval(4)
    }
}

public enum StatusFormatter {
    public static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    public static let keyHelp = "space pause  ←/→ 10s  ↑/↓ 60s  +/- volume  a audio  q quit"

    /// One status line, e.g. "▶ 01:23 / 45:00  vol 80%  audio #1 eng ac3 6ch  → TCL TV".
    public static func line(_ snapshot: PlayerSnapshot) -> String {
        var parts = ["\(snapshot.state.symbol) \(time(snapshot.position)) / \(time(snapshot.duration))"]
        parts.append("vol \(Int((snapshot.volume * 100).rounded()))%")
        if let audio = snapshot.audioLabel { parts.append("audio \(audio)") }
        parts.append("-> \(snapshot.targetName)")
        if case .failed(let reason) = snapshot.state {
            parts.append("error: \(reason)")
        } else if snapshot.state == .ended {
            parts.append("ended (space replays, q quits)")
        } else if let message = snapshot.message {
            parts.append(message)
        }
        return parts.joined(separator: "  ")
    }
}
