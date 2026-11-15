import AirstarCore
import ArgumentParser
import Foundation

struct CastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cast",
        abstract: "Stream a media file to a TV over Google Cast or AirPlay."
    )

    @Argument(help: "Path to an MKV (or any ffmpeg-readable) file.", completion: .file())
    var file: String

    @Option(name: [.short, .long], help: "Receiver name, name fragment or device ID (see `devices`).")
    var device: String

    @Option(help: "Protocol: auto (Google Cast when the TV offers it, else AirPlay), airplay or googlecast.")
    var via: StreamingProtocol = .auto

    @OptionGroup var audio: AudioOptions

    @Flag(help: "Transcode HEVC to H.264 for receivers that cannot play HEVC.")
    var forceH264 = false

    @Option(help: "HLS segment container for H.264 (mpegts or fmp4). HEVC always uses fmp4.")
    var segmentFormat: SegmentFormat?

    @Option(help: "Seconds to search for the receiver.")
    var timeout: Double = 5

    @Option(help: "Port for the media HTTP server (0 picks a free port).")
    var port: Int = 0

    func run() async throws {
        try await runOnMain()
    }

    /// A connected receiver, ready for `PlaybackController`.
    private struct Connection {
        let target: PlaybackTarget
        let capabilities: ReceiverCapabilities
        let host: String
        let close: () async -> Void
    }

    @MainActor
    private func runOnMain() async throws {
        let tools = try FFmpegTools.locate()
        let input = URL(fileURLWithPath: file).standardizedFileURL
        let media = try await MediaProbe.probe(input, tools: tools)

        print("Looking for \(device)…")
        async let airPlayScan = via == .googlecast ? [] : AirPlayBrowser.scan(timeout: timeout)
        async let castScan = via == .airplay ? [] : CastBrowser.scan(timeout: timeout)
        var receiver = try MediaReceiver.select(device, airPlay: try await airPlayScan, googleCast: try await castScan, via: via)
        if via == .auto {
            receiver = await receiver.preferringGoogleCast()
        }
        print("Connecting to \(receiver.name) over \(receiver.protocolName)…")

        let connection = try await connect(receiver, title: input.deletingPathExtension().lastPathComponent)
        let packager = try HLSPackager(input: input, tools: tools)
        let server = MediaHTTPServer(root: packager.root)
        let controller: PlaybackController
        do {
            try await server.start(host: "0.0.0.0", port: port)
            controller = try PlaybackController(
                input: input, media: media, audio: audio.selection, capabilities: connection.capabilities,
                packager: packager, server: server, urlHost: connection.host, target: connection.target
            )
            print("Preparing \(input.lastPathComponent) for \(receiver.name)…")
            try await controller.start()
        } catch {
            await connection.close()
            server.stop()
            await packager.cleanup()
            throw error
        }

        var header = await controller.plan.summary
        if case .copy(tagAsHVC1: true) = await controller.plan.videoAction {
            header.append("tip: if the TV shows a black screen, retry with --force-h264")
        }
        let runner = SessionRunner(controller: controller)
        runner.start(header: header)
        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    private func connect(_ receiver: MediaReceiver, title: String) async throws -> Connection {
        switch receiver {
        case .airPlay(let tv):
            guard tv.supportsHLSVideo else { throw AirstarError.deviceLacksVideoSupport(tv.name) }
            let client = AirPlayClient(device: tv, store: KeychainPairingStore())
            try await client.connect()
            guard let host = await client.localHost() else {
                await client.close()
                throw AirstarError.connectionFailed("could not determine this Mac's address on \(tv.name)'s network")
            }
            return Connection(
                target: AirPlayTarget(client: client, displayName: tv.name),
                capabilities: .airPlay(tv, forceH264: forceH264, segmentFormat: segmentFormat),
                host: host,
                close: { await client.close() }
            )
        case .googleCast(let tv):
            let client = CastClient(device: tv)
            try await client.connect()
            guard let host = await client.localHost() else {
                await client.close()
                throw AirstarError.connectionFailed("could not determine this Mac's address on \(tv.name)'s network")
            }
            return Connection(
                target: CastTarget(client: client, displayName: tv.name, title: title),
                capabilities: .googleCast(forceH264: forceH264, segmentFormat: segmentFormat),
                host: host,
                close: { await client.close() }
            )
        }
    }
}

extension SegmentFormat: ExpressibleByArgument {}
extension StreamingProtocol: ExpressibleByArgument {}
