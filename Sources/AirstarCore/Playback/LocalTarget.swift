import AppKit
import AVFoundation
import AVKit

/// Plays the HLS stream in a native macOS window with `AVPlayerView`.
@MainActor
public final class LocalTarget: NSObject, PlaybackTarget, NSWindowDelegate {
    public nonisolated let displayName = "this Mac"
    let player = AVPlayer()
    let window: NSWindow
    /// Called when the user closes the window.
    public var onClose: (() -> Void)?

    public init(title: String, size: CGSize) {
        let fitted = Self.fittedSize(size)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fitted),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        window.contentView = view
        window.title = title
        window.delegate = self
        window.isReleasedWhenClosed = false
        if fitted.width > 0 && fitted.height > 0 {
            window.contentAspectRatio = fitted
        }
        window.center()
    }

    /// Scales the video size to at most 80% of the main screen.
    static func fittedSize(_ size: CGSize) -> CGSize {
        let source = size.width > 0 && size.height > 0 ? size : CGSize(width: 1280, height: 720)
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let scale = min(1, screen.width * 0.8 / source.width, screen.height * 0.8 / source.height)
        return CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    }

    public func show() {
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func load(url: URL, segmentFormat: SegmentFormat) async throws {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    public func play() async throws { player.play() }

    public func pause() async throws { player.pause() }

    public func seek(to seconds: Double) async throws {
        await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func setVolume(_ fraction: Double) async throws -> Bool {
        player.volume = Float(min(max(fraction, 0), 1))
        return true
    }

    public func status() async throws -> TargetStatus {
        let item = player.currentItem
        let seconds = player.currentTime().seconds
        return TargetStatus(
            position: seconds.isFinite ? seconds : 0,
            isPlaying: player.rate > 0,
            isReady: item?.status == .readyToPlay,
            isIdle: item == nil,
            error: item?.error?.localizedDescription
        )
    }

    public func stop() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        window.orderOut(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
