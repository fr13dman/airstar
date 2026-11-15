import AirstarCore
import AppKit
import ArgumentParser
import Foundation

struct PlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play",
        abstract: "Play a media file in a window on this Mac."
    )

    @Argument(help: "Path to an MKV (or any ffmpeg-readable) file.", completion: .file())
    var file: String

    @OptionGroup var audio: AudioOptions

    func run() async throws {
        try await runOnMain()
    }

    @MainActor
    private func runOnMain() async throws {
        let tools = try FFmpegTools.locate()
        let input = URL(fileURLWithPath: file).standardizedFileURL
        let media = try await MediaProbe.probe(input, tools: tools)
        guard let video = media.primaryVideo else { throw AirstarError.noVideoStream }

        let packager = try HLSPackager(input: input, tools: tools)
        let server = MediaHTTPServer(root: packager.root)
        let target = LocalTarget(title: input.lastPathComponent, size: CGSize(width: video.width, height: video.height))
        let controller: PlaybackController
        do {
            try await server.start(host: "127.0.0.1")
            controller = try PlaybackController(
                input: input, media: media, audio: audio.selection, capabilities: .local,
                packager: packager, server: server, urlHost: "127.0.0.1", target: target
            )
            print("Preparing \(input.lastPathComponent)…")
            try await controller.start()
        } catch {
            server.stop()
            await packager.cleanup()
            throw error
        }

        let runner = SessionRunner(controller: controller)
        target.onClose = { runner.requestQuit() }
        target.show()
        runner.start(header: await controller.plan.summary)
        // Calling NSApplication.run() from this task would block the main queue and starve the main
        // actor; start it from a run loop block instead and keep this task suspended.
        RunLoop.main.perform { NSApplication.shared.run() }
        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}
