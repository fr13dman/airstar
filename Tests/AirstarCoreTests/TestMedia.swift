import Foundation
@testable import AirstarCore

/// Generates small MKV files with ffmpeg for integration tests.
enum TestMedia {
    static let tools: FFmpegTools? = try? FFmpegTools.locate()
    static var available: Bool { tools != nil }

    static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airstar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 10 s H.264 video with an AC3 5.1 English track (default) and an AAC Japanese track.
    static func h264TwoAudioTracks(in dir: URL, seconds: Int = 10) async throws -> URL {
        let out = dir.appendingPathComponent("h264_two_audio.mkv")
        try await ffmpeg([
            "-f", "lavfi", "-i", "testsrc=size=320x180:rate=24:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=\(seconds)",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24",
            "-c:a:0", "ac3", "-ac:a:0", "6", "-c:a:1", "aac",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=jpn",
            "-disposition:a:0", "default", "-disposition:a:1", "0",
            out.path,
        ])
        return out
    }

    /// 3 s VP9 + Opus file that must be fully transcoded.
    static func vp9Opus(in dir: URL) async throws -> URL {
        let out = dir.appendingPathComponent("vp9_opus.mkv")
        try await ffmpeg([
            "-f", "lavfi", "-i", "testsrc=size=320x180:rate=24:duration=3",
            "-f", "lavfi", "-i", "sine=duration=3",
            "-c:v", "libvpx-vp9", "-b:v", "200k", "-c:a", "libopus", out.path,
        ])
        return out
    }

    static func ffmpeg(_ args: [String]) async throws {
        guard let tools else { throw AirstarError.toolNotFound("ffmpeg") }
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: ["-v", "error", "-y"] + args)
        guard result.status == 0 else {
            throw AirstarError.processFailed(tool: "ffmpeg", status: result.status, stderrTail: ProcessRunner.tail(result.stderr))
        }
    }
}
