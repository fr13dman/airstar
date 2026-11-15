import Foundation
import Testing
@testable import AirstarCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct MediaInfoTests {
    @Test func parsesH264WithTwoAudioTracks() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("h264_ac3_aac"))
        #expect(info.container == "matroska,webm")
        #expect(abs(info.duration - 5.023) < 0.001)
        let video = try #require(info.primaryVideo)
        #expect(video.codec == "h264")
        #expect(video.pixelFormat == "yuv420p")
        #expect(video.width == 640 && video.height == 360)
        #expect(video.frameRate == 24)
        #expect(info.audioStreams.count == 2)
        let english = info.audioStreams[0]
        #expect(english.trackNumber == 1 && english.index == 1)
        #expect(english.codec == "ac3" && english.channels == 6)
        #expect(english.language == "eng" && english.title == "English 5.1" && english.isDefault)
        #expect(info.audioStreams[1].language == "jpn")
        #expect(english.label == "#1 eng ac3 6ch \"English 5.1\"")
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: AirstarError.self) { try MediaInfo.parse(ffprobeJSON: Data("{}".utf8)) }
    }

    @Test func skipsAttachedPictures() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},
          {"index":1,"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"pix_fmt":"yuv420p"}
        ],"format":{"format_name":"matroska,webm","duration":"10.0"}}
        """
        let info = try MediaInfo.parse(ffprobeJSON: Data(json.utf8))
        #expect(info.videoStreams.map(\.index) == [1])
    }
}

@Suite struct AudioSelectionTests {
    let info: MediaInfo

    init() throws {
        info = try MediaInfo.parse(ffprobeJSON: fixture("h264_ac3_aac"))
    }

    @Test func automaticPrefersDefaultTrack() throws {
        #expect(try AudioSelection.automatic.resolve(in: info)?.language == "eng")
    }

    @Test func selectsByTrackNumberAndLanguage() throws {
        #expect(try AudioSelection.track(2).resolve(in: info)?.language == "jpn")
        #expect(try AudioSelection.language("JPN").resolve(in: info)?.trackNumber == 2)
        #expect(try AudioSelection.language("en").resolve(in: info)?.trackNumber == 1)
    }

    @Test func unknownSelectionsThrow() {
        #expect(throws: AirstarError.noAudioTrackMatching("track 3")) { try AudioSelection.track(3).resolve(in: info) }
        #expect(throws: AirstarError.noAudioTrackMatching("fre")) { try AudioSelection.language("fre").resolve(in: info) }
    }
}

@Suite struct TranscodePlannerTests {
    @Test func h264WithAC3CopiesVideoAndTranscodesAudio() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("h264_ac3_aac"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        #expect(plan.videoAction == .copy(tagAsHVC1: false))
        #expect(plan.audioAction == .transcodeAAC(channels: 2, bitrateKbps: 192))
    }

    @Test func aacTrackIsCopied() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("h264_ac3_aac"))
        let plan = try TranscodePlanner.plan(for: info, audio: .track(2), capabilities: .local)
        #expect(plan.audioAction == .copy)
        #expect(plan.audio?.index == 2)
    }

    @Test func hevcTenBitIsCopiedWithHVC1TagWhenSupported() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("hevc10_dts"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        #expect(plan.videoAction == .copy(tagAsHVC1: true))
        #expect(plan.audioAction == .transcodeAAC(channels: 1, bitrateKbps: 192))
    }

    @Test func hevcIsTranscodedWhenReceiverLacksHEVC() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("hevc10_dts"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: ReceiverCapabilities(supportsHEVC: false))
        #expect(plan.videoAction == .transcodeH264(bitrateKbps: 2_500))
    }

    @Test func vp9AndOpusAreTranscoded() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("vp9_opus"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        #expect(plan.videoAction == .transcodeH264(bitrateKbps: 2_500))
        #expect(plan.audioAction == .transcodeAAC(channels: 1, bitrateKbps: 192))
    }

    @Test func tenBitH264IsTranscoded() {
        let video = VideoStreamInfo(index: 0, codec: "h264", profile: "High 10", pixelFormat: "yuv420p10le", width: 1920, height: 1080, frameRate: 24)
        #expect(TranscodePlanner.videoAction(for: video, capabilities: .local) == .transcodeH264(bitrateKbps: 8_000))
    }

    @Test func bitrateLadder() {
        #expect(TranscodePlanner.bitrate(forHeight: 480) == 2_500)
        #expect(TranscodePlanner.bitrate(forHeight: 720) == 5_000)
        #expect(TranscodePlanner.bitrate(forHeight: 1080) == 8_000)
        #expect(TranscodePlanner.bitrate(forHeight: 2160) == 20_000)
    }

    @Test func ffmpegArgumentsForCopyPlan() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("hevc10_dts"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        let out = URL(fileURLWithPath: "/tmp/out")
        let args = plan.ffmpegArguments(input: URL(fileURLWithPath: "/m/movie.mkv"), outputDirectory: out, startAt: 90.5)
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-ss 90.500 -i /m/movie.mkv"))
        #expect(joined.contains("-map 0:0 -map 0:1"))
        #expect(joined.contains("-c:v copy -tag:v hvc1"))
        #expect(joined.contains("-c:a aac -ac 1 -b:a 192k"))
        #expect(joined.contains("-hls_segment_type fmp4"))
        #expect(joined.contains("-hls_playlist_type event"))
        #expect(args.last == "/tmp/out/index.m3u8")
    }

    @Test func ffmpegArgumentsForTranscodePlanOmitSeekAtZero() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("vp9_opus"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        let args = plan.ffmpegArguments(input: URL(fileURLWithPath: "/m/a.mkv"), outputDirectory: URL(fileURLWithPath: "/tmp/o"))
        #expect(!args.contains("-ss"))
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-c:v h264_videotoolbox"))
        #expect(joined.contains("-g 96"))
    }

    @Test func summaryDescribesEachStream() throws {
        let info = try MediaInfo.parse(ffprobeJSON: fixture("h264_ac3_aac"))
        let plan = try TranscodePlanner.plan(for: info, capabilities: .local)
        #expect(plan.summary == [
            "video: h264 640x360 -> copy",
            "audio: #1 eng ac3 6ch \"English 5.1\" -> aac 2ch 192 kbps",
        ])
    }
}
