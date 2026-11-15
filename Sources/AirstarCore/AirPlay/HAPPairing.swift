import CryptoKit
import Foundation

/// Long-term keys from a completed PIN pair-setup, needed for pair-verify on every connection.
public struct PairingCredentials: Codable, Sendable, Equatable {
    /// Identifier this client announced during pairing.
    public let clientID: String
    /// Raw 32-byte Ed25519 private key of this client.
    public let clientPrivateKey: Data
    /// Identifier the receiver announced.
    public let accessoryID: Data
    /// Raw 32-byte Ed25519 public key of the receiver.
    public let accessoryPublicKey: Data

    public init(clientID: String, clientPrivateKey: Data, accessoryID: Data, accessoryPublicKey: Data) {
        self.clientID = clientID
        self.clientPrivateKey = clientPrivateKey
        self.accessoryID = accessoryID
        self.accessoryPublicKey = accessoryPublicKey
    }
}

/// Client side of HomeKit pair-setup (M1-M6) as used by AirPlay 2 receivers.
/// Transient pairing stops after M4 and uses the SRP session key directly.
public struct PairSetup {
    public static let transientPIN = "3939"

    public let clientID: String
    public let transient: Bool
    let signingKey: Curve25519.Signing.PrivateKey
    let srp: SRPClient
    private(set) var session: SRPClient.Session?

    public init(clientID: String = UUID().uuidString, transient: Bool = false, srp: SRPClient = SRPClient()) {
        self.clientID = clientID
        self.transient = transient
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.srp = srp
    }

    public func m1() -> Data {
        var tlv = TLV8([(.method, Data([0x00])), (.state, Data([0x01]))])
        if transient { tlv.append(.flags, Data([0x10])) }
        return tlv.encoded()
    }

    /// Consumes M2 (salt and server public key) and returns M3 (client public key and proof).
    public mutating func m3(fromM2 body: Data, pin: String) throws -> Data {
        let m2 = try TLV8.decode(body)
        try m2.checkError("pair-setup M2")
        let salt = try m2.require(.salt, "pair-setup M2")
        let serverKey = try m2.require(.publicKey, "pair-setup M2")
        let session = try srp.session(salt: salt, serverPublicKey: serverKey, password: pin)
        self.session = session
        return TLV8([(.state, Data([0x03])), (.publicKey, srp.publicKey), (.proof, session.proof)]).encoded()
    }

    /// Checks the receiver's proof in M4.
    public func verifyM4(_ body: Data) throws {
        let m4 = try TLV8.decode(body)
        try m4.checkError("pair-setup M4")
        let proof = try m4.require(.proof, "pair-setup M4")
        guard let session, proof == session.expectedServerProof else {
            throw AirstarError.pairingFailed("receiver proof did not match (wrong PIN?)")
        }
    }

    /// Shared secret for a transient session, available after M4.
    public var sessionKey: Data? { session?.key }

    /// M5: this client's long-term public key, signed and encrypted with the SRP session key.
    public func m5() throws -> Data {
        guard let session else { throw AirstarError.pairingFailed("M5 before M4") }
        let deviceX = HAPCrypto.hkdfBytes(session.key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let publicKey = signingKey.publicKey.rawRepresentation
        let info = deviceX + Data(clientID.utf8) + publicKey
        let signature = try signingKey.signature(for: info)
        let inner = TLV8([(.identifier, Data(clientID.utf8)), (.publicKey, publicKey), (.signature, signature)]).encoded()
        let encrypted = try HAPCrypto.seal(inner, key: encryptionKey(session), nonce: HAPCrypto.labelNonce("PS-Msg05"))
        return TLV8([(.state, Data([0x05])), (.encryptedData, encrypted)]).encoded()
    }

    /// M6: decrypts and verifies the receiver's long-term key, returning credentials to store.
    public func finish(m6 body: Data) throws -> PairingCredentials {
        guard let session else { throw AirstarError.pairingFailed("M6 before M4") }
        let m6 = try TLV8.decode(body)
        try m6.checkError("pair-setup M6")
        let encrypted = try m6.require(.encryptedData, "pair-setup M6")
        let inner = try TLV8.decode(HAPCrypto.open(encrypted, key: encryptionKey(session), nonce: HAPCrypto.labelNonce("PS-Msg06")))
        let accessoryID = try inner.require(.identifier, "pair-setup M6")
        let accessoryKey = try inner.require(.publicKey, "pair-setup M6")
        let signature = try inner.require(.signature, "pair-setup M6")
        let accessoryX = HAPCrypto.hkdfBytes(session.key, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: accessoryKey)
        guard publicKey.isValidSignature(signature, for: accessoryX + accessoryID + accessoryKey) else {
            throw AirstarError.pairingFailed("receiver signature in M6 is invalid")
        }
        return PairingCredentials(
            clientID: clientID,
            clientPrivateKey: signingKey.rawRepresentation,
            accessoryID: accessoryID,
            accessoryPublicKey: accessoryKey
        )
    }

    private func encryptionKey(_ session: SRPClient.Session) -> SymmetricKey {
        HAPCrypto.hkdf(session.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
    }
}

/// Client side of HomeKit pair-verify (M1-M4), which yields a fresh shared secret per connection.
public struct PairVerify {
    let credentials: PairingCredentials
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private(set) var sharedSecret: Data?

    public init(credentials: PairingCredentials) {
        self.credentials = credentials
    }

    public func m1() -> Data {
        TLV8([(.state, Data([0x01])), (.publicKey, ephemeral.publicKey.rawRepresentation)]).encoded()
    }

    /// Verifies the receiver's identity from M2 and returns M3 proving ours.
    public mutating func m3(fromM2 body: Data) throws -> Data {
        let m2 = try TLV8.decode(body)
        try m2.checkError("pair-verify M2")
        let accessoryEphemeral = try m2.require(.publicKey, "pair-verify M2")
        let encrypted = try m2.require(.encryptedData, "pair-verify M2")

        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: accessoryEphemeral)
        ).withUnsafeBytes { Data($0) }
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")

        let inner = try TLV8.decode(HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.labelNonce("PV-Msg02")))
        let accessoryID = try inner.require(.identifier, "pair-verify M2")
        let signature = try inner.require(.signature, "pair-verify M2")
        let ourPublic = ephemeral.publicKey.rawRepresentation
        let accessoryKey = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.accessoryPublicKey)
        guard accessoryKey.isValidSignature(signature, for: accessoryEphemeral + accessoryID + ourPublic) else {
            throw AirstarError.pairingFailed("receiver identity check failed; pair again with `airstar-cli pair`")
        }

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.clientPrivateKey)
        let ourSignature = try signingKey.signature(for: ourPublic + Data(credentials.clientID.utf8) + accessoryEphemeral)
        let reply = TLV8([(.identifier, Data(credentials.clientID.utf8)), (.signature, ourSignature)]).encoded()
        let sealed = try HAPCrypto.seal(reply, key: key, nonce: HAPCrypto.labelNonce("PV-Msg03"))
        sharedSecret = shared
        return TLV8([(.state, Data([0x03])), (.encryptedData, sealed)]).encoded()
    }

    /// Checks M4 and returns the shared secret for session encryption.
    public func finish(m4 body: Data) throws -> Data {
        let m4 = try TLV8.decode(body)
        try m4.checkError("pair-verify M4")
        guard let sharedSecret else { throw AirstarError.pairingFailed("M4 before M2") }
        return sharedSecret
    }
}
