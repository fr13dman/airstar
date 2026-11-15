import BigInt
import CryptoKit
import Foundation

/// SRP-6a group and hash parameters.
public struct SRPGroup: Sendable {
    public let N: BigUInt
    public let g: BigUInt
    public let hash: @Sendable (Data) -> Data

    /// Byte length of N, used to left-pad values.
    public var length: Int { (N.bitWidth + 7) / 8 }

    /// RFC 5054 3072-bit group with g = 5 and SHA-512, as used by HomeKit/AirPlay pairing.
    public static let hap3072 = SRPGroup(
        N: BigUInt("""
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """, radix: 16)!,
        g: 5,
        hash: { Data(SHA512.hash(data: $0)) }
    )
}

extension BigUInt {
    /// Big-endian bytes left-padded with zeros to `length`.
    func padded(to length: Int) -> Data {
        let raw = serialize()
        return raw.count >= length ? raw : Data(repeating: 0, count: length - raw.count) + raw
    }
}

/// Client side of SRP-6a with the conventions HomeKit/AirPlay accessories expect:
/// k = H(N | PAD(g)), u = H(PAD(A) | PAD(B)), x = H(s | H(I ":" P)), K = H(S),
/// M1 = H(H(N) xor H(g) | H(I) | s | A | B | K), M2 = H(A | M1 | K).
public struct SRPClient: Sendable {
    public let group: SRPGroup
    public let username: Data
    let a: BigUInt
    public let A: BigUInt

    public init(group: SRPGroup = .hap3072, username: String = "Pair-Setup", privateKey: BigUInt? = nil) {
        self.group = group
        self.username = Data(username.utf8)
        var random = SystemRandomNumberGenerator()
        let a = privateKey ?? BigUInt(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
        self.a = a
        self.A = group.g.power(a, modulus: group.N)
    }

    public var publicKey: Data { A.serialize() }

    public struct Session: Sendable {
        /// Shared session key K = H(S).
        public let key: Data
        /// Client proof M1.
        public let proof: Data
        /// Expected server proof M2.
        public let expectedServerProof: Data
        /// Premaster secret S, exposed for test vectors.
        public let premasterSecret: BigUInt
    }

    public func k() -> BigUInt {
        BigUInt(group.hash(group.N.serialize() + group.g.padded(to: group.length)))
    }

    public func x(salt: Data, password: String) -> BigUInt {
        let inner = group.hash(username + Data(":".utf8) + Data(password.utf8))
        return BigUInt(group.hash(salt + inner))
    }

    public func u(B: BigUInt) -> BigUInt {
        BigUInt(group.hash(A.padded(to: group.length) + B.padded(to: group.length)))
    }

    public func session(salt: Data, serverPublicKey: Data, password: String) throws -> Session {
        let N = group.N
        let B = BigUInt(serverPublicKey)
        guard B % N != 0 else { throw AirstarError.pairingFailed("invalid SRP server public key") }
        let u = u(B: B)
        guard u != 0 else { throw AirstarError.pairingFailed("invalid SRP scrambling parameter") }
        let x = x(salt: salt, password: password)
        let kgx = (k() * group.g.power(x, modulus: N)) % N
        // (B - k*g^x) mod N, kept non-negative for unsigned arithmetic.
        let base = (B % N + N - kgx) % N
        let S = base.power(a + u * x, modulus: N)
        let K = group.hash(S.serialize())

        let hN = group.hash(N.serialize())
        let hg = group.hash(group.g.serialize())
        let xorNg = Data(zip(hN, hg).map { $0 ^ $1 })
        let M1 = group.hash(xorNg + group.hash(username) + salt + A.serialize() + B.serialize() + K)
        let M2 = group.hash(A.serialize() + M1 + K)
        return Session(key: K, proof: M1, expectedServerProof: M2, premasterSecret: S)
    }
}
