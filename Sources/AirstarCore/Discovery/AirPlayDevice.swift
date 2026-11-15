import Foundation
import Network

public enum AirPlayProtocolVersion: String, Sendable, Codable {
    case v1 = "AirPlay 1"
    case v2 = "AirPlay 2"
}

/// How a receiver expects a sender to authenticate before `/play`.
public enum PairingMode: String, Sendable, Codable {
    /// Plain HTTP, no pairing (legacy AirPlay 1 receivers).
    case none
    /// HomeKit-style pair-setup with a PIN shown on the TV, then pair-verify on each connect.
    case pin
    /// One-shot pair-setup with the fixed PIN 3939 and no stored credentials.
    case transient
}

public struct AirPlayDevice: Sendable, Hashable {
    public static let serviceType = "_airplay._tcp"

    public let name: String
    public let txt: [String: String]
    /// Resolved address, for display. Connections go through Bonjour unless the address was given explicitly.
    public var host: String?
    public var port: UInt16?
    let usesBonjourEndpoint: Bool

    public init(name: String, txt: [String: String], host: String? = nil, port: UInt16? = nil) {
        self.name = name
        self.txt = txt
        self.host = host
        self.port = port
        self.usesBonjourEndpoint = host == nil
    }

    public var deviceID: String? { txt["deviceid"] }
    public var model: String? { txt["model"] }
    public var sourceVersion: String? { txt["srcvers"] }
    public var publicKey: String? { txt["pk"] }
    public var requiresPassword: Bool { txt["pw"] == "1" || txt["pw"] == "true" }

    /// Features from `features`, falling back to `ft` like pyatv does.
    public var features: FeatureFlags {
        if let raw = txt["features"] ?? txt["ft"], let flags = FeatureFlags(txtValue: raw) {
            return flags
        }
        return []
    }

    public var protocolVersion: AirPlayProtocolVersion {
        let f = features
        if f.contains(.supportsUnifiedMediaControl) || f.contains(.supportsCoreUtilsPairingAndEncryption) {
            return .v2
        }
        return .v1
    }

    /// Third-party AirPlay 2 TVs (TCL, Samsung, LG) advertise VideoHTTPLiveStreams without the legacy
    /// AirPlay 1 Video bit, so either bit counts as URL video support.
    public var supportsHLSVideo: Bool {
        features.contains(.videoHTTPLiveStreams) || features.contains(.video)
    }

    public var supportsHEVC: Bool {
        protocolVersion == .v2
    }

    /// Pairing mode to use when no stored credentials exist.
    public var defaultPairingMode: PairingMode {
        guard protocolVersion == .v2 else { return .none }
        return features.contains(.supportsTransientPairing) ? .transient : .pin
    }

    /// Key used to store pairing credentials for this device.
    public var pairingKey: String { deviceID ?? publicKey ?? name }

    public var endpoint: NWEndpoint {
        if !usesBonjourEndpoint, let host, let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        return .service(name: name, type: Self.serviceType, domain: "local.", interface: nil)
    }

    /// TCP parameters restricted to IPv4, so the receiver is reached (and reaches us back) on a routable address
    /// rather than a link-local IPv6 one that cannot be embedded in a media URL.
    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    public static func select(_ query: String, from devices: [AirPlayDevice]) throws -> AirPlayDevice {
        guard let match = try NameMatcher.select(query, from: devices, name: \.name, ids: { [$0.deviceID].compactMap { $0 } }) else {
            throw AirstarError.deviceNotFound(query)
        }
        return match
    }
}

/// JSON shape for `airstar-cli devices --json`.
public struct AirPlayDeviceSummary: Codable, Sendable {
    public let name: String
    public let deviceID: String?
    public let model: String?
    public let host: String?
    public let port: UInt16?
    public let protocolVersion: AirPlayProtocolVersion
    public let supportsHLSVideo: Bool
    public let pairing: PairingMode
    public let features: String
    public let featureNames: [String]

    public init(_ device: AirPlayDevice) {
        name = device.name
        deviceID = device.deviceID
        model = device.model
        host = device.host
        port = device.port
        protocolVersion = device.protocolVersion
        supportsHLSVideo = device.supportsHLSVideo
        pairing = device.defaultPairingMode
        features = String(format: "0x%016llX", device.features.rawValue)
        featureNames = device.features.describedFlags
    }
}
