import AirstarCore
import ArgumentParser
import Foundation

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show streams in a media file and how they would be streamed."
    )

    @Argument(help: "Path to an MKV (or any ffmpeg-readable) file.", completion: .file())
    var file: String

    @OptionGroup var audio: AudioOptions

    @Flag(help: "Plan for a receiver without HEVC support (forces H.264).")
    var forceH264 = false

    func run() async throws {
        let tools = try FFmpegTools.locate()
        let url = URL(fileURLWithPath: file)
        let info = try await MediaProbe.probe(url, tools: tools)
        print("\(url.lastPathComponent)  (\(info.container), \(StatusFormatter.time(info.duration)))")
        for video in info.videoStreams {
            let fps = video.frameRate.map { String(format: " %.3g fps", $0) } ?? ""
            print("  video #\(video.index): \(video.codec) \(video.profile ?? "") \(video.width)x\(video.height) \(video.pixelFormat ?? "")\(fps)")
        }
        for track in info.audioStreams {
            print("  audio \(track.label)\(track.isDefault ? " (default)" : "")")
        }
        let plan = try TranscodePlanner.plan(
            for: info,
            audio: audio.selection,
            capabilities: forceH264 ? ReceiverCapabilities(supportsHEVC: false) : .local
        )
        print("Plan:")
        for line in plan.summary { print("  \(line)") }
    }
}

struct AudioOptions: ParsableArguments {
    @Option(name: .customLong("audio-track"), help: "Audio track number (1-based, see `info`).")
    var track: Int?

    @Option(name: .customLong("audio-lang"), help: "Audio language code, e.g. eng.")
    var language: String?

    func validate() throws {
        if track != nil && language != nil {
            throw ValidationError("Use either --audio-track or --audio-lang, not both.")
        }
    }

    var selection: AudioSelection {
        if let track { return .track(track) }
        if let language { return .language(language) }
        return .automatic
    }
}