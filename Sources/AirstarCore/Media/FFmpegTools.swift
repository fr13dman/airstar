import Foundation

/// Locations of the Homebrew-installed `ffmpeg` and `ffprobe` binaries.
public struct FFmpegTools: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Finds both tools on `PATH` or in the standard Homebrew prefixes.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> FFmpegTools {
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let searchDirs = pathDirs + fallbackDirectories
        func find(_ name: String) throws -> URL {
            for dir in searchDirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
            throw AirstarError.toolNotFound(name)
        }
        return FFmpegTools(ffmpeg: try find("ffmpeg"), ffprobe: try find("ffprobe"))
    }
}

public enum MediaProbe {
    public static func probe(_ file: URL, tools: FFmpegTools) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AirstarError.invalidMedia("\(file.path) does not exist")
        }
        let result = try await ProcessRunner.run(tools.ffprobe, arguments: [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path,
        ])
        guard result.status == 0 else {
            throw AirstarError.processFailed(tool: "ffprobe", status: result.status, stderrTail: ProcessRunner.tail(result.stderr))
        }
        let info = try MediaInfo.parse(ffprobeJSON: result.stdout)
        guard info.primaryVideo != nil else { throw AirstarError.noVideoStream }
        return info
    }
}
