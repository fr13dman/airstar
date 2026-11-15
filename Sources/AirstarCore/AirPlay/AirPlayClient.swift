import Foundation
import Network

/// Controls URL playback on one AirPlay receiver: authentication, `/play`, rate, scrub, status, volume, stop.
public actor AirPlayClient {
    public let device: AirPlayDevice
    public let version: AirPlayProtocolVersion
    let store: PairingStore
    let connection: AirPlayConnection
    let sessionID = UUID().uuidString.uppercased()
    let senderID: String
    private var cseq = 0
    private var sharedSecret: Data?
    private var eventChannel: EventChannel?
    private var feedbackTask: Task<Void, Never>?
    private var rtspURL = ""

    public init(device: AirPlayDevice, store: PairingStore, version: AirPlayProtocolVersion? = nil) {
        self.device = device
        self.store = store
        self.version = version ?? device.protocolVersion
        self.connection = AirPlayConnection(endpoint: device.endpoint)
        self.senderID = Self.randomSenderID()
    }

    /// Opens the control connection and authenticates the way the receiver requires.
    public func connect() async throws {
        if device.requiresPassword {
            throw AirstarError.protocolError("\(device.name) is protected by an AirPlay password, which airstar-cli does not support")
        }
        try await connection.connect()
        guard version == .v2 else { return }

        if let credentials = try store.load(device.pairingKey) {
            try await verify(credentials)
        } else if device.features.contains(.supportsTransientPairing) {
            try await transientPair()
        } else {
            throw AirstarError.pairingRequired(device.name)
        }
        try await setupRemoteControlSession()
    }

    /// Our address on the receiver's network, for building media URLs.
    public func localHost() async -> String? {
        await connection.localHost
    }

    // MARK: Pairing

    /// PIN pair-setup: the receiver shows a code, `pin` returns what the user typed.
    @discardableResult
    public func pair(pin: @Sendable () async throws -> String) async throws -> PairingCredentials {
        try await connection.connect()
        let start = try await connection.send(AirPlayRequests.pairPinStart())
        guard start.isSuccess else {
            throw AirstarError.pairingFailed("receiver rejected /pair-pin-start (HTTP \(start.status))")
        }
        var setup = PairSetup()
        let m2 = try await pairStep(AirPlayRequests.pairSetup(setup.m1(), transient: false))
        let code = try await pin()
        let m4 = try await pairStep(AirPlayRequests.pairSetup(try setup.m3(fromM2: m2, pin: code), transient: false))
        try setup.verifyM4(m4)
        let m6 = try await pairStep(AirPlayRequests.pairSetup(try setup.m5(), transient: false))
        let credentials = try setup.finish(m6: m6)
        try store.save(credentials, for: device.pairingKey)
        return credentials
    }

    private func transientPair() async throws {
        var setup = PairSetup(transient: true)
        let m2 = try await pairStep(AirPlayRequests.pairSetup(setup.m1(), transient: true))
        let m4 = try await pairStep(AirPlayRequests.pairSetup(try setup.m3(fromM2: m2, pin: PairSetup.transientPIN), transient: true))
        try setup.verifyM4(m4)
        guard let key = setup.sessionKey else { throw AirstarError.pairingFailed("no transient session key") }
        sharedSecret = key
        await connection.enableEncryption(.control(sharedSecret: key))
    }

    private func verify(_ credentials: PairingCredentials) async throws {
        var verifier = PairVerify(credentials: credentials)
        let m2 = try await pairStep(AirPlayRequests.pairVerify(verifier.m1()))
        let m4 = try await pairStep(AirPlayRequests.pairVerify(try verifier.m3(fromM2: m2)))
        let secret = try verifier.finish(m4: m4)
        sharedSecret = secret
        await connection.enableEncryption(.control(sharedSecret: secret))
    }

    private func pairStep(_ request: AirPlayRequest) async throws -> Data {
        let response = try await connection.send(request)
        if response.status == 470 || response.status == 403 {
            throw AirstarError.pairingRequired(device.name)
        }
        guard response.isSuccess else {
            throw AirstarError.pairingFailed("\(request.path) returned HTTP \(response.status)")
        }
        return response.body
    }

    // MARK: AirPlay 2 session

    private func setupRemoteControlSession() async throws {
        let host = await connection.localHost ?? "127.0.0.1"
        let hostPart = host.contains(":") ? "[\(host)]" : host
        rtspURL = "rtsp://\(hostPart)/\(UInt32.random(in: 1...UInt32.max))"
        let response = try await connection.send(AirPlayRequests.setupRemoteControl(
            rtspURL: rtspURL, cseq: nextCSeq(), sessionID: sessionID, senderID: senderID
        ))
        guard response.isSuccess else { return }

        if let plist = try? PropertyListSerialization.propertyList(from: response.body, format: nil) as? [String: Any],
           let eventPort = (plist["eventPort"] as? NSNumber)?.uint16Value, eventPort > 0,
           let secret = sharedSecret,
           let remote = await connection.remoteHost,
           let port = NWEndpoint.Port(rawValue: eventPort) {
            let channel = EventChannel(endpoint: .hostPort(host: NWEndpoint.Host(remote), port: port), session: .events(sharedSecret: secret))
            channel.start()
            eventChannel = channel
        }
        startFeedback()
    }

    private func startFeedback() {
        feedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.sendFeedback()
            }
        }
    }

    private func sendFeedback() async {
        _ = try? await connection.send(AirPlayRequests.feedback(rtspURL: rtspURL, cseq: nextCSeq()), timeout: 5)
    }

    private func nextCSeq() -> Int {
        cseq += 1
        return cseq
    }

    // MARK: Playback

    /// Asks the receiver to fetch and play `url` (an HLS playlist served by this Mac).
    public func play(url: URL, startPosition: Double = 0) async throws {
        var lastStatus = 0
        for attempt in 0..<3 {
            let request = version == .v2
                ? try AirPlayRequests.playV2(url: url, startSeconds: startPosition, sessionID: sessionID, senderID: senderID)
                : try AirPlayRequests.playV1(url: url, startFraction: 0, sessionID: sessionID)
            var response = try await connection.send(request)
            if version == .v1, response.status == 400 || response.status == 415 {
                response = try await connection.send(AirPlayRequests.playV1Text(url: url, startFraction: 0, sessionID: sessionID))
            }
            if response.isSuccess { return }
            lastStatus = response.status
            if response.status == 403 || response.status == 470 { throw AirstarError.pairingRequired(device.name) }
            if response.status == 404 { throw AirstarError.urlPlaybackUnsupported(device.name) }
            // Receivers sometimes answer 500 while tearing down a previous item.
            if response.status != 500 { break }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
        }
        throw AirstarError.playbackFailed("\(device.name) rejected /play (HTTP \(lastStatus))")
    }

    public func setRate(_ rate: Double) async throws {
        try await expectSuccess(AirPlayRequests.rate(rate, sessionID: sessionID))
    }

    public func scrub(to seconds: Double) async throws {
        try await expectSuccess(AirPlayRequests.scrub(to: seconds, sessionID: sessionID))
    }

    public func playbackInfo() async throws -> PlaybackInfo {
        let response = try await connection.send(AirPlayRequests.playbackInfo(sessionID: sessionID))
        guard response.isSuccess else {
            throw AirstarError.protocolError("/playback-info returned HTTP \(response.status)")
        }
        return try PlaybackInfo.parse(response.body)
    }

    /// Returns false when the receiver does not accept volume changes for video.
    @discardableResult
    public func setVolume(_ fraction: Double) async throws -> Bool {
        if version == .v2 {
            let response = try await connection.send(AirPlayRequests.volume(rtspURL: rtspURL, cseq: nextCSeq(), fraction: fraction))
            if response.isSuccess { return true }
        }
        let response = try await connection.send(AirPlayRequests.volumeV1(fraction: fraction, sessionID: sessionID))
        return response.isSuccess
    }

    public func stop() async {
        _ = try? await connection.send(AirPlayRequests.stop(sessionID: sessionID), timeout: 5)
    }

    public func close() async {
        feedbackTask?.cancel()
        feedbackTask = nil
        eventChannel?.stop()
        eventChannel = nil
        await connection.close()
    }

    private func expectSuccess(_ request: AirPlayRequest) async throws {
        let response = try await connection.send(request)
        guard response.isSuccess else {
            throw AirstarError.protocolError("\(request.method) \(request.path) returned HTTP \(response.status)")
        }
    }

    /// Locally administered MAC-style identifier for this sender session.
    static func randomSenderID() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
