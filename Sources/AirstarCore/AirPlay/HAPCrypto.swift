import CryptoKit
import Foundation

enum HAPCrypto {
    static func hkdf(_ secret: Data, salt: String, info: String, count: Int = 32) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: count
        )
    }

    static func hkdfBytes(_ secret: Data, salt: String, info: String, count: Int = 32) -> Data {
        hkdf(secret, salt: salt, info: info, count: count).withUnsafeBytes { Data($0) }
    }

    /// 12-byte nonce made of 4 zero bytes followed by an 8-byte label such as "PS-Msg05".
    static func labelNonce(_ label: String) throws -> ChaChaPoly.Nonce {
        let bytes = Data(label.utf8)
        precondition(bytes.count <= 8)
        return try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12 - bytes.count) + bytes)
    }

    /// 12-byte nonce of 4 zero bytes followed by a little-endian 64-bit counter.
    static func counterNonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var value = counter.littleEndian
        let counterBytes = withUnsafeBytes(of: &value) { Data($0) }
        return try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + counterBytes)
    }

    /// Encrypts and returns ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// Decrypts ciphertext followed by the 16-byte tag.
    static func open(_ sealed: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        guard sealed.count >= 16 else { throw AirstarError.protocolError("encrypted payload too short") }
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        do {
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw AirstarError.protocolError("failed to decrypt payload (\(error))")
        }
    }
}

/// HAP session encryption for an established connection: frames of
/// [2-byte little-endian length][ciphertext][16-byte tag], with the length as AAD
/// and a per-direction counter nonce.
public struct HAPSession: Sendable {
    public static let maxFrameLength = 1024

    let writeKey: SymmetricKey
    let readKey: SymmetricKey
    private var writeCounter: UInt64 = 0
    private var readCounter: UInt64 = 0
    private var readBuffer = Data()

    public init(writeKey: Data, readKey: Data) {
        self.writeKey = SymmetricKey(data: writeKey)
        self.readKey = SymmetricKey(data: readKey)
    }

    /// Keys for the AirPlay control connection after pair-verify (or transient pair-setup).
    public static func control(sharedSecret: Data) -> HAPSession {
        HAPSession(
            writeKey: HAPCrypto.hkdfBytes(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
            readKey: HAPCrypto.hkdfBytes(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        )
    }

    /// Keys for the event connection the receiver uses to send requests back to the sender.
    public static func events(sharedSecret: Data) -> HAPSession {
        HAPSession(
            writeKey: HAPCrypto.hkdfBytes(sharedSecret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
            readKey: HAPCrypto.hkdfBytes(sharedSecret, salt: "Events-Salt", info: "Events-Write-Encryption-Key")
        )
    }

    /// The same session seen from the other end (keys swapped), used by test receivers.
    public var peer: HAPSession {
        HAPSession(writeKeyRaw: readKey, readKeyRaw: writeKey)
    }

    private init(writeKeyRaw: SymmetricKey, readKeyRaw: SymmetricKey) {
        writeKey = writeKeyRaw
        readKey = readKeyRaw
    }

    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        var out = Data()
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: Self.maxFrameLength, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let chunk = plaintext[offset..<end]
            var length = UInt16(chunk.count).littleEndian
            let lengthBytes = withUnsafeBytes(of: &length) { Data($0) }
            let sealed = try HAPCrypto.seal(Data(chunk), key: writeKey, nonce: HAPCrypto.counterNonce(writeCounter), aad: lengthBytes)
            writeCounter += 1
            out.append(lengthBytes)
            out.append(sealed)
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    /// Feeds received bytes and returns any plaintext from complete frames.
    public mutating func decrypt(_ ciphertext: Data) throws -> Data {
        readBuffer.append(ciphertext)
        var out = Data()
        while readBuffer.count >= 2 {
            let start = readBuffer.startIndex
            let length = Int(readBuffer[start]) | Int(readBuffer[start + 1]) << 8
            let frameLength = 2 + length + 16
            guard readBuffer.count >= frameLength else { break }
            let lengthBytes = readBuffer[start..<(start + 2)]
            let sealed = readBuffer[(start + 2)..<(start + frameLength)]
            out.append(try HAPCrypto.open(Data(sealed), key: readKey, nonce: HAPCrypto.counterNonce(readCounter), aad: Data(lengthBytes)))
            readCounter += 1
            readBuffer = Data(readBuffer[(start + frameLength)...])
        }
        return out
    }
}
