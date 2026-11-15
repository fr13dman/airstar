import Foundation

/// State reported by `GET /playback-info`.
public struct PlaybackInfo: Sendable, Equatable {
    public var duration: Double?
    public var position: Double?
    public var rate: Double?
    public var readyToPlay: Bool
    public var errorDescription: String?

    public init(duration: Double? = nil, position: Double? = nil, rate: Double? = nil, readyToPlay: Bool = false, errorDescription: String? = nil) {
        self.duration = duration
        self.position = position
        self.rate = rate
        self.readyToPlay = readyToPlay
        self.errorDescription = errorDescription
    }

    /// Parses a binary or XML property list body; an empty body means nothing is loaded.
    public static func parse(_ body: Data) throws -> PlaybackInfo {
        guard !body.isEmpty else { return PlaybackInfo() }
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw AirstarError.protocolError("playback-info is not a dictionary")
        }
        func number(_ key: String) -> Double? { (plist[key] as? NSNumber)?.doubleValue }
        var error: String?
        if let dict = plist["error"] as? [String: Any] {
            let code = (dict["code"] as? NSNumber)?.intValue ?? 0
            let domain = dict["domain"] as? String ?? "unknown domain"
            error = "error \(code) (\(domain))"
        }
        return PlaybackInfo(
            duration: number("duration"),
            position: number("position"),
            rate: number("rate"),
            readyToPlay: (plist["readyToPlay"] as? NSNumber)?.boolValue ?? false,
            errorDescription: error
        )
    }
}
