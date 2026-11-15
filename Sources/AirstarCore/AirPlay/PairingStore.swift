import Foundation
import Security

public protocol PairingStore: Sendable {
    func load(_ key: String) throws -> PairingCredentials?
    func save(_ credentials: PairingCredentials, for key: String) throws
    func remove(_ key: String) throws
}

/// Stores credentials as generic passwords in the login Keychain, keyed by receiver device ID.
public struct KeychainPairingStore: PairingStore {
    public let service: String

    public init(service: String = "com.airstar.cli.pairing") {
        self.service = service
    }

    public func load(_ key: String) throws -> PairingCredentials? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AirstarError.pairingFailed("Keychain read failed (\(status))")
        }
        return try JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    public func save(_ credentials: PairingCredentials, for key: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "airstar-cli AirPlay pairing"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AirstarError.pairingFailed("Keychain write failed (\(addStatus))") }
        } else if status != errSecSuccess {
            throw AirstarError.pairingFailed("Keychain update failed (\(status))")
        }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AirstarError.pairingFailed("Keychain delete failed (\(status))")
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: PairingCredentials] = [:]

    public init() {}

    public func load(_ key: String) throws -> PairingCredentials? { lock.withLock { entries[key] } }
    public func save(_ credentials: PairingCredentials, for key: String) throws { lock.withLock { entries[key] = credentials } }
    public func remove(_ key: String) throws { _ = lock.withLock { entries.removeValue(forKey: key) } }
}
