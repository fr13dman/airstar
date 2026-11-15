import Foundation

public struct VideoStreamInfo: Sendable, Equatable {
    public let index: Int
    public let codec: String
    public let profile: String?
    public let pixelFormat: String?
    public let width: Int
    public let height: Int
    public let frameRate: Double?
}

public struct AudioStreamInfo: Sendable, Equatable {
    public let index: Int
    /// 1-based position among audio tracks, as shown to users.
    public let trackNumber: Int
    public let codec: String
    public let channels: Int
    public let language: String?
    public let title: String?
    public let isDefault: Bool

    public var label: String {
        var parts = ["#\(trackNumber)", language ?? "und", codec]
        parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels)ch")
        if let title { parts.append("\"\(title)\"") }
        return parts.joined(separator: " ")
    }
}

public struct MediaInfo: Sendable, Equatable {
    public let container: String
    public let duration: Double
    public let videoStreams: [VideoStreamInfo]
    public let audioStreams: [AudioStreamInfo]

    public var primaryVideo: VideoStreamInfo? { videoStreams.first }
}

/// Which audio track to play.
public enum AudioSelection: Sendable, Equatable {
    case automatic
    case track(Int)
    case language(String)

    public func resolve(in media: MediaInfo) throws -> AudioStreamInfo? {
        let tracks = media.audioStreams
        switch self {
        case .automatic:
            return tracks.first(where: \.isDefault) ?? tracks.first
        case .track(let number):
            guard let track = tracks.first(where: { $0.trackNumber == number }) else {
                throw AirstarError.noAudioTrackMatching("track \(number)")
            }
            return track
        case .language(let code):
            let wanted = code.lowercased()
            guard let track = tracks.first(where: { ($0.language?.lowercased()).map { $0 == wanted || $0.hasPrefix(wanted) } ?? false }) else {
                throw AirstarError.noAudioTrackMatching(code)
            }
            return track
        }
    }
}

// MARK: - ffprobe JSON decoding

extension MediaInfo {
    /// Builds `MediaInfo` from `ffprobe -print_format json -show_format -show_streams` output.
    public static func parse(ffprobeJSON data: Data) throws -> MediaInfo {
        let probe: FFProbeOutput
        do {
            probe = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        } catch {
            throw AirstarError.invalidMedia("unreadable ffprobe output (\(error.localizedDescription))")
        }
        var videos: [VideoStreamInfo] = []
        var audios: [AudioStreamInfo] = []
        for stream in probe.streams {
            switch stream.codec_type {
            case "video":
                // Cover art in MKV shows up as a video stream with the attached_pic disposition.
                if stream.disposition?["attached_pic"] == 1 { continue }
                videos.append(VideoStreamInfo(
                    index: stream.index,
                    codec: stream.codec_name ?? "unknown",
                    profile: stream.profile,
                    pixelFormat: stream.pix_fmt,
                    width: stream.width ?? 0,
                    height: stream.height ?? 0,
                    frameRate: stream.avg_frame_rate.flatMap(parseRate)
                ))
            case "audio":
                audios.append(AudioStreamInfo(
                    index: stream.index,
                    trackNumber: audios.count + 1,
                    codec: stream.codec_name ?? "unknown",
                    channels: stream.channels ?? 2,
                    language: stream.tags?["language"] ?? stream.tags?["LANGUAGE"],
                    title: stream.tags?["title"] ?? stream.tags?["TITLE"],
                    isDefault: stream.disposition?["default"] == 1
                ))
            default:
                continue
            }
        }
        let duration = probe.format.duration.flatMap(Double.init) ?? 0
        return MediaInfo(
            container: probe.format.format_name ?? "unknown",
            duration: duration,
            videoStreams: videos,
            audioStreams: audios
        )
    }

    static func parseRate(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]) {
            return d == 0 ? nil : n / d
        }
        return Double(text)
    }
}

struct FFProbeOutput: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_name: String?
        let codec_type: String?
        let profile: String?
        let pix_fmt: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let avg_frame_rate: String?
        let tags: [String: String]?
        let disposition: [String: Int]?
    }
    struct Format: Decodable {
        let format_name: String?
        let duration: String?
    }
    let streams: [Stream]
    let format: Format
}
