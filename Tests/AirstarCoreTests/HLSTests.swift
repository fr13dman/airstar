import Foundation
import Testing
@testable import AirstarCore

@Suite struct HLSPlaylistTests {
    @Test func parsesEventPlaylistInProgress() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.000000,
        seg_00000.m4s
        #EXTINF:4.000000,
        seg_00001.m4s
        #EXTINF:2.500000,
        seg_00002.m4s
        """
        let playlist = HLSPlaylist.parse(text)
        #expect(playlist.segmentCount == 3)
        #expect(playlist.totalDuration == 10.5)
        #expect(!playlist.isComplete)
    }

    @Test func detectsEndList() {
        let playlist = HLSPlaylist.parse("#EXTM3U\n#EXTINF:1.5,\na.m4s\n#EXT-X-ENDLIST\n")
        #expect(playlist.isComplete)
        #expect(playlist.totalDuration == 1.5)
    }

    @Test func emptyTextHasNoSegments() {
        #expect(HLSPlaylist.parse("") == HLSPlaylist(segmentDurations: [], isComplete: false))
    }
}

@Suite struct MediaHTTPServerCORSTests {
    @Test func servesCORSHeadersAndAnswersPreflight() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("gen-1"), withIntermediateDirectories: true)
        try Data("#EXTM3U\n".utf8).write(to: dir.appendingPathComponent("gen-1/index.m3u8"))
        try Data(repeating: 0x47, count: 1000).write(to: dir.appendingPathComponent("gen-1/seg_00000.ts"))

        var paths: [String] = []
        let lock = NSLock()
        let server = MediaHTTPServer(root: dir) { path in lock.withLock { paths.append(path) } }
        try await server.start(host: "127.0.0.1")
        defer { server.stop() }

        var preflight = URLRequest(url: try #require(server.url(for: "gen-1/seg_00000.ts", host: "127.0.0.1")))
        preflight.httpMethod = "OPTIONS"
        preflight.setValue("https://www.gstatic.com", forHTTPHeaderField: "Origin")
        preflight.setValue("range", forHTTPHeaderField: "Access-Control-Request-Headers")
        let (_, preflightResponse) = try await URLSession.shared.data(for: preflight)
        let options = try #require(preflightResponse as? HTTPURLResponse)
        #expect(options.statusCode == 204)
        #expect(options.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(options.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("Range") == true)

        var get = URLRequest(url: try #require(server.url(for: "gen-1/seg_00000.ts", host: "127.0.0.1")))
        get.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let (data, getResponse) = try await URLSession.shared.data(for: get)
        let http = try #require(getResponse as? HTTPURLResponse)
        #expect(http.statusCode == 206 && data.count == 10)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(http.value(forHTTPHeaderField: "Access-Control-Expose-Headers")?.contains("Content-Range") == true)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")
        #expect(lock.withLock { paths } == ["/gen-1/seg_00000.ts", "/gen-1/seg_00000.ts"])
    }
}

@Suite(.enabled(if: TestMedia.available, "ffmpeg not installed"), .serialized)
struct HLSPackagerIntegrationTests {
    @Test func remuxesH264AndServesItOverHTTP() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try #require(TestMedia.tools)
        let input = try await TestMedia.h264TwoAudioTracks(in: dir)
        let info = try await MediaProbe.probe(input, tools: tools)
        #expect(info.audioStreams.count == 2)

        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        #expect(plan.videoAction == .copy(tagAsHVC1: false))
        let packager = try HLSPackager(input: input, tools: tools, root: dir.appendingPathComponent("hls"))
        let generation = try await packager.start(plan: plan)
        #expect(generation.playlistPath == "gen-1/index.m3u8")

        try await waitForCompletion(packager)
        let progress = await packager.progress()
        #expect(progress.isComplete)
        #expect(abs(progress.availableDuration - 10) < 1.0)
        let files = try FileManager.default.contentsOfDirectory(atPath: generation.directory.path)
        #expect(files.contains("init.mp4"))
        #expect(files.contains("seg_00000.m4s"))

        let server = MediaHTTPServer(root: await packager.root)
        let port = try await server.start()
        defer { server.stop() }
        #expect(port > 0)

        let playlistURL = try #require(server.url(for: generation.playlistPath, host: "127.0.0.1"))
        let (playlistData, playlistResponse) = try await URLSession.shared.data(from: playlistURL)
        let http = try #require(playlistResponse as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(http.value(forHTTPHeaderField: "Cache-Control")?.contains("no-cache") == true)
        #expect(String(decoding: playlistData, as: UTF8.self).contains("#EXT-X-MAP:URI=\"init.mp4\""))

        var rangeRequest = URLRequest(url: try #require(server.url(for: "gen-1/seg_00000.m4s", host: "127.0.0.1")))
        rangeRequest.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
        let rangeHTTP = try #require(rangeResponse as? HTTPURLResponse)
        #expect(rangeHTTP.statusCode == 206)
        #expect(rangeData.count == 100)
        #expect(rangeHTTP.value(forHTTPHeaderField: "Content-Type") == "video/iso.segment")

        let (_, missing) = try await URLSession.shared.data(from: try #require(server.url(for: "gen-1/nope.m4s", host: "127.0.0.1")))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)

        await packager.cleanup()
        #expect(!FileManager.default.fileExists(atPath: await packager.root.path))
    }

    @Test func restartAtOffsetCreatesNewGenerationWithSelectedAudio() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try #require(TestMedia.tools)
        let input = try await TestMedia.h264TwoAudioTracks(in: dir)
        let info = try await MediaProbe.probe(input, tools: tools)
        let packager = try HLSPackager(input: input, tools: tools, root: dir.appendingPathComponent("hls"))

        try await packager.start(plan: try TranscodePlanner.plan(for: info, capabilities: .local))
        let japanese = try TranscodePlanner.plan(for: info, audio: .language("jpn"), capabilities: .local)
        let second = try await packager.start(plan: japanese, at: 6)
        #expect(second.number == 2)
        #expect(second.startOffset == 6)
        #expect(second.plan.audioAction == .copy)

        try await waitForCompletion(packager)
        let progress = await packager.progress()
        #expect(progress.availableDuration < 6)
        await packager.cleanup()
    }

    @Test func transcodesVP9WithVideoToolbox() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try #require(TestMedia.tools)
        let input = try await TestMedia.vp9Opus(in: dir)
        let info = try await MediaProbe.probe(input, tools: tools)
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        #expect(plan.videoAction == .transcodeH264(bitrateKbps: 2_500))

        let packager = try HLSPackager(input: input, tools: tools, root: dir.appendingPathComponent("hls"))
        let generation = try await packager.start(plan: plan)
        try await waitForCompletion(packager)
        #expect(await packager.failure() == nil)

        let output = generation.directory.appendingPathComponent("init.mp4")
        let probe = try await ProcessRunner.run(tools.ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0",
            generation.directory.appendingPathComponent(HLSPackager.playlistName).path,
        ])
        #expect(FileManager.default.fileExists(atPath: output.path))
        let codecs = String(decoding: probe.stdout, as: UTF8.self)
        #expect(codecs.contains("h264"))
        #expect(codecs.contains("aac"))
        await packager.cleanup()
    }

    @Test func failingInputSurfacesFFmpegError() async throws {
        let dir = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try #require(TestMedia.tools)
        let bogus = dir.appendingPathComponent("broken.mkv")
        try Data("not a video".utf8).write(to: bogus)
        let video = VideoStreamInfo(index: 0, codec: "h264", profile: nil, pixelFormat: "yuv420p", width: 320, height: 180, frameRate: 24)
        let plan = TranscodePlan(video: video, videoAction: .copy(tagAsHVC1: false), audio: nil, audioAction: nil)
        let packager = try HLSPackager(input: bogus, tools: tools, root: dir.appendingPathComponent("hls"))
        await #expect(throws: AirstarError.self) {
            try await packager.start(plan: plan)
        }
        await packager.cleanup()
    }

    private func waitForCompletion(_ packager: HLSPackager) async throws {
        for _ in 0..<200 {
            if await packager.progress().isComplete { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("packager did not finish in time")
    }
}
