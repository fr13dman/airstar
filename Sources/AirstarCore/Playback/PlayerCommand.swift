import Foundation

/// Keyboard-driven playback commands.
public enum PlayerCommand: Sendable, Equatable {
    case togglePause
    case seek(Double)
    case volume(Double)
    case cycleAudio
    case quit
}

/// Turns raw terminal bytes (raw mode) into commands, buffering split escape sequences.
public struct KeyDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ bytes: [UInt8]) -> [PlayerCommand] {
        pending += bytes
        var commands: [PlayerCommand] = []
        var i = 0
        while i < pending.count {
            let byte = pending[i]
            if byte == 0x1B {
                guard i + 2 < pending.count else { break }
                if pending[i + 1] == UInt8(ascii: "[") || pending[i + 1] == UInt8(ascii: "O") {
                    switch pending[i + 2] {
                    case UInt8(ascii: "C"): commands.append(.seek(10))
                    case UInt8(ascii: "D"): commands.append(.seek(-10))
                    case UInt8(ascii: "A"): commands.append(.seek(60))
                    case UInt8(ascii: "B"): commands.append(.seek(-60))
                    default: break
                    }
                    i += 3
                } else {
                    i += 1
                }
                continue
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "k"): commands.append(.togglePause)
            case UInt8(ascii: "l"): commands.append(.seek(10))
            case UInt8(ascii: "j"): commands.append(.seek(-10))
            case UInt8(ascii: "+"), UInt8(ascii: "="): commands.append(.volume(0.1))
            case UInt8(ascii: "-"), UInt8(ascii: "_"): commands.append(.volume(-0.1))
            case UInt8(ascii: "a"), UInt8(ascii: "A"): commands.append(.cycleAudio)
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03, 0x04: commands.append(.quit)
            default: break
            }
            i += 1
        }
        pending = Array(pending[i...])
        return commands
    }
}
