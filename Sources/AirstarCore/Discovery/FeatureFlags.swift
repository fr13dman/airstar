import Foundation

/// AirPlay `features` bitmask advertised in the Bonjour TXT record (`features=0xLOW,0xHIGH`).
public struct FeatureFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let video = FeatureFlags(bit: 0)
    public static let photo = FeatureFlags(bit: 1)
    public static let videoFairPlay = FeatureFlags(bit: 2)
    public static let videoVolumeControl = FeatureFlags(bit: 3)
    public static let videoHTTPLiveStreams = FeatureFlags(bit: 4)
    public static let slideshow = FeatureFlags(bit: 5)
    public static let screen = FeatureFlags(bit: 7)
    public static let audio = FeatureFlags(bit: 9)
    public static let audioRedundant = FeatureFlags(bit: 11)
    public static let authentication4 = FeatureFlags(bit: 14)
    public static let metadataFeatures = FeatureFlags(bit: 15)
    public static let audioFormats = FeatureFlags(bit: 18)
    public static let legacyPairing = FeatureFlags(bit: 27)
    public static let unifiedServices = FeatureFlags(bit: 30)
    public static let supportsCoreUtilsPairingAndEncryption = FeatureFlags(bit: 38)
    public static let supportsUnifiedMediaControl = FeatureFlags(bit: 40)
    public static let supportsHKPairingAndAccessControl = FeatureFlags(bit: 46)
    public static let supportsTransientPairing = FeatureFlags(bit: 48)
    public static let supportsSystemPairing = FeatureFlags(bit: 43)

    init(bit: Int) { self.init(rawValue: 1 << UInt64(bit)) }

    /// Parses `0x527FFFF7,0x1E` (low,high) or a single `0x...` value. Returns nil when malformed.
    public init?(txtValue: String) {
        let parts = txtValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return nil }
        func parseHex(_ s: String) -> UInt64? {
            let digits = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
            return UInt64(digits, radix: 16)
        }
        guard let low = parseHex(parts[0]) else { return nil }
        var value = low & 0xFFFF_FFFF
        if parts.count == 2 {
            guard let high = parseHex(parts[1]) else { return nil }
            value |= (high & 0xFFFF_FFFF) << 32
        }
        self.init(rawValue: value)
    }

    /// Indices of every set bit, ascending.
    public var setBits: [Int] {
        (0..<64).filter { rawValue & (1 << UInt64($0)) != 0 }
    }

    /// Human readable names for the bits airstar-cli cares about.
    public var describedFlags: [String] {
        let named: [(FeatureFlags, String)] = [
            (.video, "Video"),
            (.photo, "Photo"),
            (.videoVolumeControl, "VideoVolumeControl"),
            (.videoHTTPLiveStreams, "VideoHTTPLiveStreams"),
            (.screen, "Screen"),
            (.audio, "Audio"),
            (.unifiedServices, "UnifiedServices"),
            (.supportsCoreUtilsPairingAndEncryption, "CoreUtilsPairingAndEncryption"),
            (.supportsUnifiedMediaControl, "UnifiedMediaControl"),
            (.supportsSystemPairing, "SystemPairing"),
            (.supportsHKPairingAndAccessControl, "HKPairingAndAccessControl"),
            (.supportsTransientPairing, "TransientPairing"),
        ]
        return named.filter { contains($0.0) }.map(\.1)
    }
}
