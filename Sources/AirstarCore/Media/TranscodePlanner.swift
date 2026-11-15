import Foundation

/// What the playback destination can decode.
public struct ReceiverCapabilities: Sendable, Equatable {
    public var supportsHEVC: Bool
    /// Container for H.264 output; HEVC always uses fMP4.
    public var preferredSegmentFormat: SegmentFormat

    public init(supportsHEVC: Bool, preferredSegmentFormat: SegmentFormat = .fmp4) {
        self.supportsHEVC = supportsHEVC
        self.preferredSegmentFormat = preferredSegmentFormat
    }

    /// AVPlayer on macOS 14+ decodes HEVC (including 10-bit) in hardware.
    public static let local = ReceiverCapabilities(supportsHEVC: true)

    /// The Default Media Receiver plays H.264/AAC MPEG-TS HLS everywhere; HEVC depends on the device.
    public static func googleCast(forceH264: Bool = false, segmentFormat: SegmentFormat? = nil) -> ReceiverCapabilities {
        ReceiverCapabilities(supportsHEVC: !forceH264, preferredSegmentFormat: segmentFormat ?? .mpegts)
    }

    public static func airPlay(_ device: AirPlayDevice, forceH264: Bool = false, segmentFormat: SegmentFormat? = nil) -> ReceiverCapabilities {
        ReceiverCapabilities(
            supportsHEVC: device.supportsHEVC && !forceH264,
            // Receivers built on non-Apple players (e.g. Android-based TVs and projectors) stall on
            // fMP4 H.264 but play MPEG-TS reliably, and Apple receivers accept both.
            preferredSegmentFormat: segmentFormat ?? .mpegts
        )
    }
}

public enum VideoAction: Sendable, Equatable {
    case copy(tagAsHVC1: Bool)
    case transcodeH264(bitrateKbps: Int)
}

public enum AudioAction: Sendable, Equatable {
    case copy
    case transcodeAAC(channels: Int, bitrateKbps: Int)
}

/// HLS segment container.
public enum SegmentFormat: String, Sendable, Equatable, CaseIterable {
    /// Fragmented MP4: required for HEVC; what AVPlayer and AirPlay 2 receivers prefer.
    case fmp4
    /// MPEG-TS: the most compatible choice for legacy AirPlay 1 receivers (H.264 only).
    case mpegts
}

public struct TranscodePlan: Sendable, Equatable {
    public let video: VideoStreamInfo
    public let videoAction: VideoAction
    public let audio: AudioStreamInfo?
    public let audioAction: AudioAction?
    public let segmentFormat: SegmentFormat

    public init(video: VideoStreamInfo, videoAction: VideoAction, audio: AudioStreamInfo?, audioAction: AudioAction?, segmentFormat: SegmentFormat = .fmp4) {
        self.video = video
        self.videoAction = videoAction
        self.audio = audio
        self.audioAction = audioAction
        self.segmentFormat = segmentFormat
    }

    public static let segmentSeconds = 4

    /// ffmpeg arguments that write an fMP4 HLS event playlist (`index.m3u8`) into `outputDirectory`.
    public func ffmpegArguments(input: URL, outputDirectory: URL, startAt: Double = 0) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        if startAt > 0 {
            args += ["-ss", String(format: "%.3f", startAt)]
        }
        args += ["-i", input.path, "-map", "0:\(video.index)"]
        if let audio {
            args += ["-map", "0:\(audio.index)"]
        }

        switch videoAction {
        case .copy(let tagAsHVC1):
            args += ["-c:v", "copy"]
            if tagAsHVC1 { args += ["-tag:v", "hvc1"] }
        case .transcodeH264(let kbps):
            let gop = Int(((video.frameRate ?? 24) * Double(Self.segmentSeconds)).rounded())
            args += [
                "-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p",
                "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-g", "\(gop)",
            ]
        }

        switch audioAction {
        case .copy:
            args += ["-c:a", "copy"]
        case .transcodeAAC(let channels, let kbps):
            args += ["-c:a", "aac", "-ac", "\(channels)", "-b:a", "\(kbps)k"]
        case nil:
            break
        }

        args += [
            "-sn", "-dn",
            "-f", "hls",
            "-hls_time", "\(Self.segmentSeconds)",
            "-hls_list_size", "0",
            "-hls_playlist_type", "event",
            "-hls_flags", "independent_segments+temp_file",
        ]
        switch segmentFormat {
        case .fmp4:
            args += [
                "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "init.mp4",
                "-hls_segment_filename", outputDirectory.appendingPathComponent("seg_%05d.m4s").path,
            ]
        case .mpegts:
            args += [
                "-hls_segment_type", "mpegts",
                "-hls_segment_filename", outputDirectory.appendingPathComponent("seg_%05d.ts").path,
            ]
        }
        args.append(outputDirectory.appendingPathComponent(HLSPackager.playlistName).path)
        return args
    }

    /// One line per stream for `airstar-cli info` and the status line.
    public var summary: [String] {
        var lines: [String] = []
        let res = "\(video.width)x\(video.height)"
        switch videoAction {
        case .copy:
            lines.append("video: \(video.codec) \(res) -> copy")
        case .transcodeH264(let kbps):
            lines.append("video: \(video.codec) \(res) -> h264 (VideoToolbox, \(kbps) kbps)")
        }
        if let audio, let audioAction {
            switch audioAction {
            case .copy:
                lines.append("audio: \(audio.label) -> copy")
            case .transcodeAAC(let channels, let kbps):
                lines.append("audio: \(audio.label) -> aac \(channels)ch \(kbps) kbps")
            }
        } else {
            lines.append("audio: none")
        }
        return lines
    }
}

public enum TranscodePlanner {
    static let h264CopyPixelFormats: Set<String> = ["yuv420p", "yuvj420p"]
    static let hevcCopyPixelFormats: Set<String> = ["yuv420p", "yuvj420p", "yuv420p10le"]

    public static func plan(
        for media: MediaInfo,
        audio selection: AudioSelection = .automatic,
        capabilities: ReceiverCapabilities
    ) throws -> TranscodePlan {
        guard let video = media.primaryVideo else { throw AirstarError.noVideoStream }
        let audio = try selection.resolve(in: media)
        let videoAction = videoAction(for: video, capabilities: capabilities)
        let isHEVC: Bool
        if case .copy(true) = videoAction { isHEVC = true } else { isHEVC = false }
        return TranscodePlan(
            video: video,
            videoAction: videoAction,
            audio: audio,
            audioAction: audio.map(audioAction(for:)),
            segmentFormat: isHEVC ? .fmp4 : capabilities.preferredSegmentFormat
        )
    }

    static func videoAction(for video: VideoStreamInfo, capabilities: ReceiverCapabilities) -> VideoAction {
        let pixFmt = video.pixelFormat ?? "yuv420p"
        switch video.codec {
        case "h264" where h264CopyPixelFormats.contains(pixFmt):
            return .copy(tagAsHVC1: false)
        case "hevc" where capabilities.supportsHEVC && hevcCopyPixelFormats.contains(pixFmt):
            return .copy(tagAsHVC1: true)
        default:
            return .transcodeH264(bitrateKbps: bitrate(forHeight: video.height))
        }
    }

    static func audioAction(for audio: AudioStreamInfo) -> AudioAction {
        audio.codec == "aac" ? .copy : .transcodeAAC(channels: min(audio.channels, 2), bitrateKbps: 192)
    }

    static func bitrate(forHeight height: Int) -> Int {
        switch height {
        case ..<481: return 2_500
        case ..<721: return 5_000
        case ..<1081: return 8_000
        default: return 20_000
        }
    }
}
