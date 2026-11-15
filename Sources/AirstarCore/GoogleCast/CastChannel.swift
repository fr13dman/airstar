import Foundation
import Network

public enum CastNamespace {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
    public static let media = "urn:x-cast:com.google.cast.media"
}

/// A CastV2 connection: TLS to port 8009, length-prefixed protobuf frames carrying JSON.
/// Answers heartbeat PINGs, sends its own PINGs, and matches responses to requests by `requestId`.
public actor CastChannel {
    public static let senderID = "sender-0"
    public static let platformReceiverID = "receiver-0"

    let connection: NWConnection
    private var parser = CastFrameParser()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private var closed = false
    /// Messages that are not responses to a request (e.g. MEDIA_STATUS broadcasts).
    private var unsolicitedHandler: (@Sendable (String, JSONObject) -> Void)?

    /// `useTLS` is false only for tests against a plain-TCP mock receiver.
    public init(endpoint: NWEndpoint, useTLS: Bool = true) {
        connection = NWConnection(to: endpoint, using: Self.parameters(useTLS: useTLS))
    }

    static func parameters(useTLS: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        var tls: NWProtocolTLS.Options?
        if useTLS {
            let options = NWProtocolTLS.Options()
            // Cast devices present self-signed certificates; device authentication is out of scope.
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, .global())
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    public func setUnsolicitedHandler(_ handler: @escaping @Sendable (String, JSONObject) -> Void) {
        unsolicitedHandler = handler
    }

    public func connect(timeout: Double = 10) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: AirstarError.connectionFailed("\(error)")) }
                case .cancelled:
                    once.run { continuation.resume(throwing: AirstarError.connectionFailed("cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(throwing: AirstarError.timeout("connection to Cast device")) }
            }
        }
        receiveLoop()
        try await send(CastNamespace.connection, to: Self.platformReceiverID, ["type": "CONNECT"])
        startHeartbeat()
    }

    public var localHost: String? {
        if case let .hostPort(host, _)? = connection.currentPath?.localEndpoint {
            return AirPlayBrowser.hostString(host)
        }
        return nil
    }

    /// Sends a message that expects no reply.
    public func send(_ namespace: String, to destination: String, _ payload: [String: Any]) async throws {
        let message = CastMessage(
            sourceID: Self.senderID, destinationID: destination, namespace: namespace,
            payloadUTF8: try JSONObject(payload).encodedString()
        )
        Self.debugLog("-> \(destination) \(namespace.split(separator: ".").last ?? "") \(message.payloadUTF8 ?? "")")
        try await write(message.framed())
    }

    /// Sends a message with a fresh `requestId` and waits for the reply carrying the same id.
    public func request(_ namespace: String, to destination: String, _ payload: [String: Any], timeout: Double = 15) async throws -> JSONObject {
        let id = nextRequestID
        nextRequestID += 1
        var body = payload
        body["requestId"] = id
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.fail(id, AirstarError.timeout("\(payload["type"] ?? "Cast") response"))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.send(namespace, to: destination, body)
                } catch {
                    self.fail(id, error)
                }
            }
        }
    }

    public func close() {
        closed = true
        heartbeatTask?.cancel()
        for (_, continuation) in pending {
            continuation.resume(throwing: AirstarError.connectionFailed("Cast connection closed"))
        }
        pending.removeAll()
        connection.cancel()
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                try? await self.send(CastNamespace.heartbeat, to: Self.platformReceiverID, ["type": "PING"])
            }
        }
    }

    private func write(_ data: Data) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AirstarError.connectionFailed("send failed: \(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private nonisolated func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.handle(data)
                }
                if error != nil || isComplete {
                    await self.close()
                } else {
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ data: Data) async {
        parser.append(data)
        do {
            while let message = try parser.next() {
                await dispatch(message)
            }
        } catch {
            close()
        }
    }

    private func dispatch(_ message: CastMessage) async {
        guard let json = message.json else { return }
        Self.debugLog("<- \(message.sourceID) \(message.namespace.split(separator: ".").last ?? "") \(message.payloadUTF8 ?? "")")
        if message.namespace == CastNamespace.heartbeat, json.type == "PING" {
            try? await send(CastNamespace.heartbeat, to: message.sourceID, ["type": "PONG"])
            return
        }
        if message.namespace == CastNamespace.connection, json.type == "CLOSE" {
            unsolicitedHandler?(message.namespace, json)
            return
        }
        if let id = json.requestID, id != 0, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: json)
            return
        }
        unsolicitedHandler?(message.namespace, json)
    }

    static func debugLog(_ message: @autoclosure () -> String) {
        guard AirPlayConnection.debugEnabled else { return }
        FileHandle.standardError.write(Data("\n[cast] \(message())\n".utf8))
    }
}
