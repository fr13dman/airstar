import Foundation
import Testing
@testable import AirstarCore

@Suite struct KeyDecoderTests {
    @Test func mapsKeysToCommands() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array(" +-aq".utf8)) == [.togglePause, .volume(0.1), .volume(-0.1), .cycleAudio, .quit])
    }

    @Test func mapsArrowKeys() {
        var decoder = KeyDecoder()
        let arrows: [UInt8] = [0x1B, 0x5B, 0x43, 0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x42]
        #expect(decoder.decode(arrows) == [.seek(10), .seek(-10), .seek(60), .seek(-60)])
    }

    @Test func buffersSplitEscapeSequences() {
        var decoder = KeyDecoder()
        #expect(decoder.decode([0x1B]) == [])
        #expect(decoder.decode([0x5B]) == [])
        #expect(decoder.decode([0x43, UInt8(ascii: " ")]) == [.seek(10), .togglePause])
    }

    @Test func ctrlCAndCtrlDQuit() {
        var decoder = KeyDecoder()
        #expect(decoder.decode([0x03]) == [.quit])
        #expect(decoder.decode([0x04]) == [.quit])
    }

    @Test func ignoresUnknownKeys() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("xyz".utf8)) == [])
    }
}

@Suite struct PlaybackStateTests {
    @Test func normalLifecycle() {
        var state = PlaybackState.idle
        state = state.applying(.prepare)
        #expect(state == .preparing)
        state = state.applying(.started)
        #expect(state == .playing)
        state = state.applying(.paused)
        #expect(state == .paused)
        state = state.applying(.resumed)
        #expect(state == .playing)
        state = state.applying(.seekBegan)
        #expect(state == .seeking)
        state = state.applying(.seekEnded(playing: false))
        #expect(state == .paused)
        state = state.applying(.reachedEnd)
        #expect(state == .ended)
        state = state.applying(.prepare)
        #expect(state == .preparing)
    }

    @Test func ignoresInvalidEvents() {
        #expect(PlaybackState.idle.applying(.paused) == .idle)
        #expect(PlaybackState.preparing.applying(.reachedEnd) == .preparing)
        #expect(PlaybackState.playing.applying(.started) == .playing)
    }

    @Test func failureAndStopWinFromAnyState() {
        #expect(PlaybackState.playing.applying(.failed("boom")) == .failed("boom"))
        #expect(PlaybackState.failed("x").applying(.stopped) == .idle)
    }
}

@Suite struct SeekPlannerTests {
    @Test func seeksInPlaceWithinTranscodedRange() {
        let decision = SeekPlanner.decide(target: 50, mediaDuration: 600, generationStart: 0, available: 120, complete: false)
        #expect(decision == .inPlace(50))
    }

    @Test func restartsPastTheTranscodedRangeWithSafetyMargin() {
        #expect(SeekPlanner.decide(target: 115, mediaDuration: 600, generationStart: 0, available: 120, complete: false) == .restart(115))
        #expect(SeekPlanner.decide(target: 115, mediaDuration: 600, generationStart: 0, available: 120, complete: true) == .inPlace(115))
    }

    @Test func restartsBeforeTheGenerationStart() {
        #expect(SeekPlanner.decide(target: 100, mediaDuration: 600, generationStart: 300, available: 60, complete: false) == .restart(100))
    }

    @Test func positionIsRelativeToGenerationStart() {
        #expect(SeekPlanner.decide(target: 320, mediaDuration: 600, generationStart: 300, available: 60, complete: false) == .inPlace(20))
    }

    @Test func clampsToMediaBounds() {
        #expect(SeekPlanner.decide(target: -30, mediaDuration: 600, generationStart: 0, available: 600, complete: true) == .inPlace(0))
        #expect(SeekPlanner.decide(target: 9_999, mediaDuration: 600, generationStart: 0, available: 600, complete: true) == .inPlace(599))
    }
}

@Suite struct StatusFormatterTests {
    @Test func formatsTimes() {
        #expect(StatusFormatter.time(0) == "00:00")
        #expect(StatusFormatter.time(83.9) == "01:23")
        #expect(StatusFormatter.time(3_725) == "1:02:05")
        #expect(StatusFormatter.time(.nan) == "00:00")
    }

    @Test func formatsStatusLine() {
        let snapshot = PlayerSnapshot(state: .playing, position: 83, duration: 2_700, volume: 0.8, audioLabel: "#1 eng ac3 6ch", targetName: "TCL TV", message: "Volume 80%")
        #expect(StatusFormatter.line(snapshot) == "▶ 01:23 / 45:00  vol 80%  audio #1 eng ac3 6ch  -> TCL TV  Volume 80%")
    }

    @Test func showsErrorsAndEnd() {
        var snapshot = PlayerSnapshot(state: .failed("ffmpeg died"), position: 0, duration: 10, volume: 1, audioLabel: nil, targetName: "this Mac", message: nil)
        #expect(StatusFormatter.line(snapshot).hasSuffix("error: ffmpeg died"))
        snapshot.state = .ended
        #expect(StatusFormatter.line(snapshot).contains("ended"))
    }
}

/// Records calls and pretends to play, fetching the playlist like a real player would.
final class FakeTarget: PlaybackTarget, @unchecked Sendable {
    let displayName = "fake"
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _loaded: [URL] = []
    var statusToReport = TargetStatus(position: 0, isPlaying: true, isReady: true)
    var acceptsVolume = true

    var calls: [String] { lock.withLock { _calls } }
    var loaded: [URL] { lock.withLock { _loaded } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func load(url: URL, segmentFormat: SegmentFormat) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, String(decoding: data, as: UTF8.self).contains("#EXTM3U") else {
            throw AirstarError.playbackFailed("playlist not served")
        }
        lock.withLock { _loaded.append(url) }
        record("load")
    }
    func play() async throws { record("play") }
    func pause() async throws { record("pause") }
    func seek(to seconds: Double) async throws { record("seek \(Int(seconds))") }
    func setVolume(_ fraction: Double) async throws -> Bool {
        record(String(format: "volume %.1f", fraction))
        return acceptsVolume
    }
    func status() async throws -> TargetStatus { lock.withLock { statusToReport } }
    func stop() async { record("stop") }
}

@Suite(.enabled(if: TestMedia.available, "ffmpeg not installed"), .serialized)
struct PlaybackControllerTests {
    func makeController(target: FakeTarget, dir: URL, seekVerificationDelay: Double = 1.5) async throws -> (PlaybackController, HLSPackager) {
        let tools = try #require(TestMedia.tools)
        let input = try await TestMedia.h264TwoAudioTracks(in: dir, seconds: 12)
        let media = try await MediaProbe.probe(input, tools: tools)
        let packager = try HLSPackager(input: input, tools: tools, root: dir.appendingPathComponent("hls"))
        let server = MediaHTTPServer(root: packager.root)
        try await server.start(host: "127.0.0.1")
        let controller = try PlaybackController(
            input: input, media: media, audio: .automatic, capabilities: .local,
            packager: packager, server: server, urlHost: "127.0.0.1", target: target,
            seekVerificationDelay: seekVerificationDelay
        )
        return (controller, packager)
    }

    @Test func ignoredSeekFallsBackToRestartingTheStream() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FakeTarget()
        let (controller, _) = try await makeController(target: target, dir: dir, seekVerificationDelay: 0)
        try await controller.start()
        for _ in 0..<100 where !(await packagerComplete(controller)) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // The fake keeps reporting 2 s no matter what it is asked to seek to.
        target.statusToReport = TargetStatus(position: 2, isPlaying: true, isReady: true)
        _ = await controller.tick()

        _ = await controller.handle(.seek(8))
        #expect(target.calls.contains("seek 10"))
        #expect(target.loaded.count == 1)
        _ = await controller.tick()
        #expect(target.loaded.count == 2)
        #expect(await controller.generation?.startOffset == 10)
        #expect(await controller.inPlaceSeekUnreliable)
        #expect(await controller.snapshot().message?.contains("ignored the seek") == true)

        // Later seeks skip /scrub and restart directly.
        _ = await controller.tick()
        _ = await controller.handle(.seek(-4))
        #expect(target.loaded.count == 3)
        #expect(await controller.generation?.startOffset == 8)
        await controller.shutdown()
    }

    @Test func startLoadsServedPlaylistAndReportsPlaying() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FakeTarget()
        let (controller, packager) = try await makeController(target: target, dir: dir)
        try await controller.start()
        #expect(target.loaded.first?.path == "/gen-1/index.m3u8")
        #expect(await controller.state == .preparing)

        target.statusToReport = TargetStatus(position: 2.5, isPlaying: true, isReady: true)
        let snapshot = await controller.tick()
        #expect(snapshot.state == .playing)
        #expect(snapshot.position == 2.5)
        #expect(snapshot.audioLabel?.hasPrefix("#1 eng") == true)

        await controller.shutdown()
        #expect(target.calls.last == "stop")
        #expect(!FileManager.default.fileExists(atPath: packager.root.path))
    }

    @Test func pauseSeekAndVolumeCommands() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FakeTarget()
        let (controller, _) = try await makeController(target: target, dir: dir)
        try await controller.start()
        target.statusToReport = TargetStatus(position: 1, isPlaying: true, isReady: true)
        _ = await controller.tick()

        #expect(await controller.handle(.togglePause) == false)
        #expect(await controller.state == .paused)
        #expect(await controller.handle(.togglePause) == false)
        #expect(await controller.state == .playing)

        // Wait for ffmpeg to finish so the whole file is seekable in place.
        for _ in 0..<100 where !(await packagerComplete(controller)) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = await controller.handle(.seek(5))
        #expect(target.calls.contains("seek 6"))

        _ = await controller.handle(.volume(-0.1))
        #expect(target.calls.contains("volume 0.9"))
        #expect(await controller.snapshot().volume == 0.9)

        target.acceptsVolume = false
        _ = await controller.handle(.volume(-0.1))
        #expect(await controller.snapshot().message?.contains("does not accept volume") == true)
        #expect(await controller.handle(.quit) == true)
        await controller.shutdown()
    }

    @Test func cyclingAudioRestartsPackagerWithNextTrack() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FakeTarget()
        let (controller, _) = try await makeController(target: target, dir: dir)
        try await controller.start()
        target.statusToReport = TargetStatus(position: 3, isPlaying: true, isReady: true)
        _ = await controller.tick()

        _ = await controller.handle(.cycleAudio)
        #expect(await controller.plan.audio?.language == "jpn")
        #expect(target.loaded.last?.path == "/gen-2/index.m3u8")
        #expect(await controller.generation?.startOffset == 3)
        #expect(await controller.snapshot().message?.hasPrefix("Audio #2") == true)

        _ = await controller.handle(.cycleAudio)
        #expect(await controller.plan.audio?.language == "eng")
        await controller.shutdown()
    }

    @Test func detectsEndOfMedia() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FakeTarget()
        let (controller, _) = try await makeController(target: target, dir: dir)
        try await controller.start()
        target.statusToReport = TargetStatus(position: 1, isPlaying: true, isReady: true)
        _ = await controller.tick()
        for _ in 0..<100 where !(await packagerComplete(controller)) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        target.statusToReport = TargetStatus(position: 11.9, isPlaying: false, isReady: true)
        #expect(await controller.tick().state == .ended)

        _ = await controller.handle(.togglePause)
        #expect(await controller.state == .preparing)
        #expect(target.loaded.count == 2)
        await controller.shutdown()
    }

    @Test func targetErrorsFailTheSession() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FakeTarget()
        let (controller, _) = try await makeController(target: target, dir: dir)
        try await controller.start()
        target.statusToReport = TargetStatus(error: "error -12938 (CoreMediaErrorDomain)")
        #expect(await controller.tick().state == .failed("error -12938 (CoreMediaErrorDomain)"))
        await controller.shutdown()
    }

    private func packagerComplete(_ controller: PlaybackController) async -> Bool {
        await controller.packager.progress().isComplete
    }
}
