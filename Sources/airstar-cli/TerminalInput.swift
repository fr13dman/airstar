import Darwin
import Foundation

/// Puts the terminal in non-canonical, no-echo mode and delivers keystrokes as raw bytes.
/// ISIG stays on so Ctrl-C still raises SIGINT, which the session handles for cleanup.
final class TerminalInput: @unchecked Sendable {
    private var original = termios()
    private var active = false
    private let lock = NSLock()

    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    func start(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        guard Self.isInteractive else { return }
        lock.withLock {
            guard !active, tcgetattr(STDIN_FILENO, &original) == 0 else { return }
            var raw = original
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            active = true
        }
        FileHandle.standardOutput.write(Data("\u{1B}[?25l".utf8))
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                handler([UInt8](data))
            }
        }
    }

    /// Restores the original terminal mode and cursor. Safe to call more than once.
    func restore() {
        let wasActive = lock.withLock { () -> Bool in
            guard active else { return false }
            FileHandle.standardInput.readabilityHandler = nil
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            active = false
            return true
        }
        if wasActive {
            FileHandle.standardOutput.write(Data("\u{1B}[?25h".utf8))
        }
    }

    static var columns: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return 100
    }
}
