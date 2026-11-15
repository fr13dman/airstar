import Foundation

/// Which streaming protocol `cast` should use.
public enum StreamingProtocol: String, CaseIterable, Sendable {
    /// Google Cast when the TV offers it, otherwise AirPlay.
    case auto
    case airplay
    case googlecast
}

/// A TV or receiver reachable over one of the supported protocols.
public enum MediaReceiver: Sendable {
    case airPlay(AirPlayDevice)
    case googleCast(CastDevice)

    public var name: String {
        switch self {
        case .airPlay(let device): return device.name
        case .googleCast(let device): return device.name
        }
    }

    public var protocolName: String {
        switch self {
        case .airPlay: return "AirPlay"
        case .googleCast: return "Google Cast"
        }
    }

    /// Picks the receiver for `query`. In `.auto` mode a matching Google Cast device wins: many smart TVs
    /// (TCL, Sony, Philips) advertise both, and their AirPlay side only accepts Apple's private video protocol.
    public static func select(
        _ query: String,
        airPlay: [AirPlayDevice],
        googleCast: [CastDevice],
        via choice: StreamingProtocol
    ) throws -> MediaReceiver {
        let castMatch = try NameMatcher.select(query, from: googleCast.filter(\.supportsVideo), name: \.name, ids: {
            [$0.id, $0.instanceName].compactMap { $0 }
        })
        let airPlayMatch = try NameMatcher.select(query, from: airPlay, name: \.name, ids: { [$0.deviceID].compactMap { $0 } })
        switch choice {
        case .googlecast:
            if let castMatch { return .googleCast(castMatch) }
        case .airplay:
            if let airPlayMatch { return .airPlay(airPlayMatch) }
        case .auto:
            if let castMatch { return .googleCast(castMatch) }
            if let airPlayMatch { return .airPlay(airPlayMatch) }
        }
        throw AirstarError.deviceNotFound(query)
    }
}

extension MediaReceiver {
    /// Some TVs stop answering `_googlecast._tcp` browses while their Cast service keeps running.
    /// If an AirPlay match has an address with the Cast port open, use Google Cast on that address instead.
    public func preferringGoogleCast(probeTimeout: Double = 2) async -> MediaReceiver {
        guard case .airPlay(let tv) = self, let host = tv.host else { return self }
        guard await CastBrowser.isCastPortOpen(host: host, timeout: probeTimeout) else { return self }
        return .googleCast(CastDevice(instanceName: tv.name, txt: ["fn": tv.name, "ca": "1"], host: host, port: CastDevice.defaultPort))
    }
}

enum NameMatcher {
    /// Case-insensitive match on exact name or ID first, then on a unique name substring.
    /// Returns nil when nothing matches and throws when the query is ambiguous.
    static func select<T>(_ query: String, from items: [T], name: (T) -> String, ids: (T) -> [String]) throws -> T? {
        let q = query.lowercased()
        let exact = items.filter { name($0).lowercased() == q || ids($0).contains { $0.lowercased() == q } }
        if exact.count == 1 { return exact[0] }
        let partial = items.filter { name($0).lowercased().contains(q) }
        if exact.count > 1 || (exact.isEmpty && partial.count > 1) {
            throw AirstarError.ambiguousDevice(query, matches: (exact.isEmpty ? partial : exact).map(name))
        }
        return partial.first
    }
}
