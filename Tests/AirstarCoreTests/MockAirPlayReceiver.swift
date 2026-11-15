import BigInt
import CryptoKit
import Foundation
import Network
@testable import AirstarCore

/// Accessory side of HomeKit pair-setup / pair-verify, mirroring what an AirPlay 2 TV does.
final class MockHAPAccessory: @unchecked Sendable {
    let pin: String
    let accessoryID = Data("11:22:33:44:55:66".utf8)
    let signingKey = Curve25519.Signing.PrivateKey()
    let group = SRPGroup.hap3072
    private(set) var pairedClients: [String: Data] = [:]
    /// Shared secret to encrypt the connection with, set once pairing or verification completes.
    private(set) var establishedSecret: Data?

    private var salt = Data()
    private var verifier = BigUInt(0)
    private var b = BigUInt(0)
    private var B = BigUInt(0)
    private var sessionKey: Data?
    private var transient = false
    private var verifyEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var verifyShared: Data?
    private var clientEphemeral: Data?

    init(pin: String) {
        self.pin = pin
    }

    func handlePairSetup(_ body: Data) throws -> Data {
        let tlv = try TLV8.decode(body)
        switch tlv[.state]?.first {
        case 1:
            transient = tlv[.flags] == Data([0x10])
            salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let client = SRPClient(group: group)
            verifier = group.g.power(client.x(salt: salt, password: transient ? PairSetup.transientPIN : pin), modulus: group.N)
            b = BigUInt(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            B = (client.k() * verifier + group.g.power(b, modulus: group.N)) % group.N
            return TLV8([(.state, Data([2])), (.salt, salt), (.publicKey, B.serialize())]).encoded()
        case 3:
            let A = BigUInt(try tlv.require(.publicKey, "M3"))
            let proof = try tlv.require(.proof, "M3")
            let hash = group.hash
            let u = BigUInt(hash(A.padded(to: group.length) + B.padded(to: group.length)))
            let S = (A * verifier.power(u, modulus: group.N)).power(b, modulus: group.N)
            let K = hash(S.serialize())
            let username = Data("Pair-Setup".utf8)
            let xorNg = Data(zip(hash(group.N.serialize()), hash(group.g.serialize())).map { $0 ^ $1 })
            let expected = hash(xorNg + hash(username) + salt + A.serialize() + B.serialize() + K)
            guard proof == expected else {
                return TLV8([(.state, Data([4])), (.error, Data([0x02]))]).encoded()
            }
            sessionKey = K
            if transient { establishedSecret = K }
            return TLV8([(.state, Data([4])), (.proof, hash(A.serialize() + proof + K))]).encoded()
        case 5:
            guard let K = sessionKey else { throw AirstarError.pairingFailed("M5 before M3") }
            let key = HAPCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            let inner = try TLV8.decode(HAPCrypto.open(try tlv.require(.encryptedData, "M5"), key: key, nonce: HAPCrypto.labelNonce("PS-Msg05")))
            let clientID = try inner.require(.identifier, "M5")
            let clientKey = try inner.require(.publicKey, "M5")
            let signature = try inner.require(.signature, "M5")
            let deviceX = HAPCrypto.hkdfBytes(K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
            guard try Curve25519.Signing.PublicKey(rawRepresentation: clientKey).isValidSignature(signature, for: deviceX + clientID + clientKey) else {
                return TLV8([(.state, Data([6])), (.error, Data([0x02]))]).encoded()
            }
            pairedClients[String(decoding: clientID, as: UTF8.self)] = clientKey

            let accessoryX = HAPCrypto.hkdfBytes(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            let publicKey = signingKey.publicKey.rawRepresentation
            let accessorySignature = try signingKey.signature(for: accessoryX + accessoryID + publicKey)
            let reply = TLV8([(.identifier, accessoryID), (.publicKey, publicKey), (.signature, accessorySignature)]).encoded()
            let sealed = try HAPCrypto.seal(reply, key: key, nonce: HAPCrypto.labelNonce("PS-Msg06"))
            return TLV8([(.state, Data([6])), (.encryptedData, sealed)]).encoded()
        default:
            throw AirstarError.pairingFailed("unexpected pair-setup state")
        }
    }

    func handlePairVerify(_ body: Data) throws -> Data {
        let tlv = try TLV8.decode(body)
        switch tlv[.state]?.first {
        case 1:
            let clientPublic = try tlv.require(.publicKey, "PV M1")
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientPublic)).withUnsafeBytes { Data($0) }
            verifyEphemeral = ephemeral
            verifyShared = shared
            clientEphemeral = clientPublic
            let ourPublic = ephemeral.publicKey.rawRepresentation
            let signature = try signingKey.signature(for: ourPublic + accessoryID + clientPublic)
            let inner = TLV8([(.identifier, accessoryID), (.signature, signature)]).encoded()
            let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let sealed = try HAPCrypto.seal(inner, key: key, nonce: HAPCrypto.labelNonce("PV-Msg02"))
            return TLV8([(.state, Data([2])), (.publicKey, ourPublic), (.encryptedData, sealed)]).encoded()
        case 3:
            guard let shared = verifyShared, let ephemeral = verifyEphemeral, let clientPublic = clientEphemeral else {
                throw AirstarError.pairingFailed("PV M3 before M1")
            }
            let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let inner = try TLV8.decode(HAPCrypto.open(try tlv.require(.encryptedData, "PV M3"), key: key, nonce: HAPCrypto.labelNonce("PV-Msg03")))
            let clientID = String(decoding: try inner.require(.identifier, "PV M3"), as: UTF8.self)
            let signature = try inner.require(.signature, "PV M3")
            guard let clientKey = pairedClients[clientID],
                  try Curve25519.Signing.PublicKey(rawRepresentation: clientKey)
                    .isValidSignature(signature, for: clientPublic + Data(clientID.utf8) + ephemeral.publicKey.rawRepresentation) else {
                return TLV8([(.state, Data([4])), (.error, Data([0x02]))]).encoded()
            }
            establishedSecret = shared
            return TLV8([(.state, Data([4]))]).encoded()
        default:
            throw AirstarError.pairingFailed("unexpected pair-verify state")
        }
    }

    func resetSession() {
        establishedSecret = nil
    }
}

/// In-process AirPlay receiver on 127.0.0.1 that records every request it gets.
final class MockAirPlayReceiver: @unchecked Sendable {
    struct Received: Sendable {
        let method: String
        let path: String
        let encrypted: Bool
        let body: Data
        let headers: [(String, String)]
    }

    let accessory: MockHAPAccessory
    let listener: NWListener
    private let lock = NSLock()
    private var _received: [Received] = []
    var playbackInfoBody: Data
    var playStatus = 200
    var requireAuthentication = false

    var received: [Received] { lock.withLock { _received } }

    init(pin: String = "1234") throws {
        accessory = MockHAPAccessory(pin: pin)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        playbackInfoBody = try PropertyListSerialization.data(
            fromPropertyList: ["duration": 30.0, "position": 5.5, "rate": 1.0, "readyToPlay": true],
            format: .binary, options: 0
        )
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        let state = ConnectionState()
        connection.start(queue: .global())
        receive(connection, state)
    }

    private final class ConnectionState: @unchecked Sendable {
        var parser = HTTPMessageParser()
        var session: HAPSession?
    }

    private func receive(_ connection: NWConnection, _ state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let plain = state.session != nil ? try state.session!.decrypt(data) : data
                    state.parser.append(plain)
                    while let request = try state.parser.nextRequest() {
                        let encrypted = state.session != nil
                        lock.withLock {
                            self._received.append(Received(method: request.method, path: request.path, encrypted: encrypted, body: request.body, headers: request.headers))
                        }
                        let response = try respond(to: request, encrypted: encrypted)
                        var bytes = response.serialized()
                        if state.session != nil { bytes = try state.session!.encrypt(bytes) }
                        connection.send(content: bytes, completion: .idempotent)
                        if state.session == nil, let secret = accessory.establishedSecret {
                            state.session = HAPSession.control(sharedSecret: secret).peer
                            accessory.resetSession()
                        }
                    }
                } catch {
                    connection.cancel()
                    return
                }
            }
            if error == nil && !isComplete { receive(connection, state) }
        }
    }

    private func respond(to request: AirPlayRequest, encrypted: Bool) throws -> AirPlayResponse {
        let version = request.version
        let cseq = request.header("cseq").map { ["CSeq": $0] } ?? [:]
        func ok(_ body: Data = Data(), type: String? = nil) -> AirPlayResponse {
            var headers = cseq
            if let type { headers["Content-Type"] = type }
            return AirPlayResponse(version: version, status: 200, headers: headers, body: body)
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        if requireAuthentication && !encrypted && !path.hasPrefix("/pair") {
            return AirPlayResponse(version: version, status: 470, reason: "Connection Authorization Required")
        }
        switch (request.method, path) {
        case ("POST", "/pair-pin-start"):
            return ok()
        case ("POST", "/pair-setup"):
            return ok(try accessory.handlePairSetup(request.body), type: "application/octet-stream")
        case ("POST", "/pair-verify"):
            return ok(try accessory.handlePairVerify(request.body), type: "application/octet-stream")
        case ("SETUP", _):
            let body = try PropertyListSerialization.data(fromPropertyList: ["eventPort": 0], format: .binary, options: 0)
            return ok(body, type: "application/x-apple-binary-plist")
        case ("POST", "/play"):
            return AirPlayResponse(version: version, status: playStatus, headers: cseq)
        case ("GET", "/playback-info"):
            return ok(playbackInfoBody, type: "application/x-apple-binary-plist")
        case ("POST", "/rate"), ("POST", "/scrub"), ("POST", "/stop"), ("POST", "/feedback"), ("POST", "/volume"), ("SET_PARAMETER", _):
            return ok()
        default:
            return AirPlayResponse(version: version, status: 404, reason: "Not Found", headers: cseq)
        }
    }
}
