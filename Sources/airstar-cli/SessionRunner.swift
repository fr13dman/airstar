import AirstarCore
import Foundation

/// Runs an interactive playback session: keyboard input, a live status line, and cleanup on quit,
/// window close, Ctrl-C or SIGTERM. Ends the process when the session finishes.
@MainActor
final class SessionRunner {
    let controller: PlaybackController
    private let terminal = TerminalInput()
    private var decoder = KeyDecoder()
    private var signalSources: [DispatchSourceSignal] = []
    private var finishing = false
    private var lastPlainPrint = Date.distantPast

    init(controller: PlaybackController) {
        self.controller = controller
    }

    func start(header: [String]) {
        for line in header { print(line) }
        if TerminalInput.isInteractive {
            print(StatusFormatter.keyHelp)
        }
        installSignalHandlers()
        terminal.start { [weak self] bytes in
            Task { @MainActor in self?.received(bytes) }
        }
        Task { await self.pollStatus() }
    }

    func requestQuit() {
        Task { await finish() }
    }

    private func received(_ bytes: [UInt8]) {
        for command in decoder.decode(bytes) {
            Task {
                if await controller.handle(command) {
                    await finish()
                } else {
                    render(await controller.snapshot())
                }
            }
        }
    }

    private func pollStatus() async {
        while !finishing {
            let snapshot = await controller.tick()
            render(snapshot)
            if !TerminalInput.isInteractive {
                // Without a keyboard there is nobody to press q, so end with the media.
                if snapshot.state == .ended { await finish() }
                if case .failed = snapshot.state { await finish(status: 1) }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func render(_ snapshot: PlayerSnapshot) {
        guard !finishing else { return }
        let line = StatusFormatter.line(snapshot)
        if TerminalInput.isInteractive {
            let width = max(20, TerminalInput.columns - 1)
            let clipped = line.count > width ? String(line.prefix(width - 1)) + "…" : line
            FileHandle.standardOutput.write(Data("\r\u{1B}[2K\(clipped)".utf8))
        } else if Date().timeIntervalSince(lastPlainPrint) >= 5 {
            lastPlainPrint = Date()
            print(line)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in await self?.finish(status: sig == SIGINT ? 0 : 1) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func finish(status: Int32 = 0) async {
        guard !finishing else { return }
        finishing = true
        let final = await controller.snapshot()
        await controller.shutdown()
        terminal.restore()
        print("")
        var code = status
        if case .failed(let reason) = final.state {
            FileHandle.standardError.write(Data("Error: \(reason)\n".utf8))
            code = 1
        }
        exit(code)
    }
}
