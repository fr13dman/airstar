import Foundation
import Network

/// Bonjour browsing and address resolution shared by AirPlay and Google Cast discovery.
public enum BonjourBrowser {
    /// Browses `type` for `timeout` seconds and returns each service instance name with its TXT record.
    public static func browse(type: String, timeout: Double) async throws -> [(name: String, txt: [String: String])] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let state = BrowseState()
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata {
                    txt = record.dictionary
                }
                state.record(name: name, txt: txt)
            }
        }
        browser.stateUpdateHandler = { newState in
            if case let .failed(error) = newState { state.fail(error) }
        }
        browser.start(queue: .global(qos: .userInitiated))
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        browser.cancel()
        if let error = state.error {
            throw AirstarError.connectionFailed("Bonjour browse failed: \(error)")
        }
        return state.services
    }

    /// Opens a short IPv4 TCP connection to the service to learn its address and port.
    public static func resolve(_ endpoint: NWEndpoint, timeout: Double = 5) async -> (host: String, port: UInt16)? {
        let connection = NWConnection(to: endpoint, using: AirPlayDevice.tcpParameters())
        let remote: NWEndpoint? = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: connection.currentPath?.remoteEndpoint) }
                case .failed, .cancelled:
                    once.run { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(returning: nil) }
            }
        }
        connection.cancel()
        if case let .hostPort(host, port) = remote {
            return (AirPlayBrowser.hostString(host), port.rawValue)
        }
        return nil
    }
}

/// Finds AirPlay receivers on the local network with Bonjour (`_airplay._tcp`).
public enum AirPlayBrowser {
    /// Browses for `timeout` seconds, then resolves each receiver's address.
    public static func scan(timeout: Double = 5) async throws -> [AirPlayDevice] {
        let found = try await BonjourBrowser.browse(type: AirPlayDevice.serviceType, timeout: timeout)
        return await withTaskGroup(of: AirPlayDevice.self) { group in
            for (name, txt) in found {
                group.addTask { await resolve(AirPlayDevice(name: name, txt: txt)) }
            }
            var resolved: [AirPlayDevice] = []
            for await device in group { resolved.append(device) }
            return resolved.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public static func resolve(_ device: AirPlayDevice, timeout: Double = 5) async -> AirPlayDevice {
        var resolved = device
        if let (host, port) = await BonjourBrowser.resolve(device.endpoint, timeout: timeout) {
            resolved.host = host
            resolved.port = port
        }
        return resolved
    }

    /// Address without the interface scope (e.g. "%en0") so it can be used in URLs.
    public static func hostString(_ host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .ipv4(let address): raw = "\(address)"
        case .ipv6(let address): raw = "\(address)"
        case .name(let name, _): raw = name
        @unknown default: raw = "\(host)"
        }
        return raw.split(separator: "%").first.map(String.init) ?? raw
    }
}

final class BrowseState: @unchecked Sendable {
    private let lock = NSLock()
    private var byName: [String: [String: String]] = [:]
    private(set) var error: NWError?

    func record(name: String, txt: [String: String]) {
        lock.withLock {
            // The same service is reported once per interface; keep the entry with the richest TXT record.
            if let existing = byName[name], existing.count >= txt.count { return }
            byName[name] = txt
        }
    }

    func fail(_ error: NWError) { lock.withLock { self.error = error } }

    var services: [(name: String, txt: [String: String])] {
        lock.withLock { byName.map { (name: $0.key, txt: $0.value) } }
    }
}

/// Guards a continuation that several callbacks race to resume.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            if done { return false }
            done = true
            return true
        }
        if shouldRun { body() }
    }
}
