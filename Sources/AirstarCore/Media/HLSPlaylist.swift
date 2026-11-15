import Foundation

/// The parts of an ffmpeg-written HLS media playlist airstar-cli needs to track progress.
public struct HLSPlaylist: Sendable, Equatable {
    public let segmentDurations: [Double]
    public let isComplete: Bool

    public var segmentCount: Int { segmentDurations.count }
    public var totalDuration: Double { segmentDurations.reduce(0, +) }

    public init(segmentDurations: [Double], isComplete: Bool) {
        self.segmentDurations = segmentDurations
        self.isComplete = isComplete
    }

    public static func parse(_ text: String) -> HLSPlaylist {
        var durations: [Double] = []
        var complete = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                if let seconds = Double(value) { durations.append(seconds) }
            } else if line == "#EXT-X-ENDLIST" {
                complete = true
            }
        }
        return HLSPlaylist(segmentDurations: durations, isComplete: complete)
    }
}
