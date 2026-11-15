import Foundation
import Network

/// A Google Cast receiver found through Bonjour (`_googlecast._tcp`).
public struct CastDevice: Sendable, Hashable {
    public static let serviceType = "_googlecast._tcp"
    public static let defaultPort: UInt16 = 8009

    /// Bonjour instance name, e.g. "Smart-TV-Pro-5b68…".
    public let instanceName: String
    public let txt: [String: String]
    public var host: String?
    public var port: UInt16?
    let usesBonjourEndpoint: Bool

    public init(instanceName: String, txt: [String: String], host: String? = nil, port: UInt16? = nil) {
        self.instanceName = instanceName
        self.txt = txt
        self.host = host
        self.port = port
        self.usesBonjourEndpoint = host == nil
    }

    /// Friendly name shown in the Google Home app (`fn`), falling back to the instance name.
    public var name: String { txt["fn"].flatMap { $0.isEmpty ? nil : $0 } ?? instanceName }
    public var id: String? { txt["id"] }
    public var model: String? { txt["md"] }

    /// `ca` capability bitmask; bit 0 is video output.
    public var capabilities: Int { Int(txt["ca"] ?? "") ?? 0 }
    public var supportsVideo: Bool { capabilities & 1 == 1 }

    public var endpoint: NWEndpoint {
        if !usesBonjourEndpoint, let host, let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        return .service(name: instanceName, type: Self.serviceType, domain: "local.", interface: nil)
    }
}

public enum CastBrowser {
    /// True when `host` accepts TCP connections on the Cast port.
    public static func isCastPortOpen(host: String, port: UInt16 = CastDevice.defaultPort, timeout: Double = 2) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await BonjourBrowser.resolve(.hostPort(host: NWEndpoint.Host(host), port: nwPort), timeout: timeout) != nil
    }

    public static func scan(timeout: Double = 5) async throws -> [CastDevice] {
        let found = try await BonjourBrowser.browse(type: CastDevice.serviceType, timeout: timeout)
        return await withTaskGroup(of: CastDevice.self) { group in
            for (name, txt) in found {
                group.addTask {
                    var device = CastDevice(instanceName: name, txt: txt)
                    if let (host, port) = await BonjourBrowser.resolve(device.endpoint) {
                        device.host = host
                        device.port = port
                    }
                    return device
                }
            }
            var devices: [CastDevice] = []
            for await device in group { devices.append(device) }
            return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

public struct CastDeviceSummary: Codable, Sendable {
    public let name: String
    public let id: String?
    public let model: String?
    public let host: String?
    public let port: UInt16?
    public let supportsVideo: Bool

    public init(_ device: CastDevice) {
        name = device.name
        id = device.id
        model = device.model
        host = device.host
        port = device.port
        supportsVideo = device.supportsVideo
    }
}
