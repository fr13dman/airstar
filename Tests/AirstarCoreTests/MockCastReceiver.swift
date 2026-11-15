import Foundation
import Network
@testable import AirstarCore

/// In-process Google Cast receiver speaking CastV2 over plain TCP on 127.0.0.1.
final class MockCastReceiver: @unchecked Sendable {
    struct Received: Sendable {
        let namespace: String
        let destination: String
        let type: String
        let payload: JSONObject
    }

    let listener: NWListener
    private let lock = NSLock()
    private var _received: [Received] = []
    private var playerState = "IDLE"
    private var currentTime = 0.0
    var failLoad = false

    var received: [Received] { lock.withLock { _received } }
    func types(in namespace: String) -> [String] { received.filter { $0.namespace == namespace }.map(\.type) }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    private final class ConnectionState: @unchecked Sendable {
        var parser = CastFrameParser()
    }

    private func serve(_ connection: NWConnection) {
        let state = ConnectionState()
        connection.start(queue: .global())
        // Real receivers ping the sender too; the client must answer with PONG.
        send(connection, from: "receiver-0", to: "sender-0", CastNamespace.heartbeat, ["type": "PING"])
        receive(connection, state)
    }

    private func receive(_ connection: NWConnection, _ state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                state.parser.append(data)
                while let message = try? state.parser.next() {
                    handle(message, on: connection)
                }
            }
            if error == nil && !isComplete { receive(connection, state) }
        }
    }

    private func handle(_ message: CastMessage, on connection: NWConnection) {
        guard let json = message.json, let type = json.type else { return }
        lock.withLock {
            _received.append(Received(namespace: message.namespace, destination: message.destinationID, type: type, payload: json))
        }
        let requestID = json.requestID ?? 0
        let reply = { (namespace: String, payload: [String: Any]) in
            var body = payload
            body["requestId"] = requestID
            self.send(connection, from: message.destinationID, to: message.sourceID, namespace, body)
        }
        switch (message.namespace, type) {
        case (CastNamespace.receiver, "LAUNCH"), (CastNamespace.receiver, "SET_VOLUME"), (CastNamespace.receiver, "GET_STATUS"):
            reply(CastNamespace.receiver, ["type": "RECEIVER_STATUS", "status": [
                "applications": [["appId": CastClient.defaultMediaReceiverAppID, "sessionId": "session-1", "transportId": "transport-1"]],
                "volume": ["level": 0.5],
            ] as [String: Any]])
        case (CastNamespace.receiver, "STOP"):
            reply(CastNamespace.receiver, ["type": "RECEIVER_STATUS", "status": ["applications": [[String: Any]]()]])
        case (CastNamespace.media, "LOAD"):
            if failLoad {
                reply(CastNamespace.media, ["type": "LOAD_FAILED"])
            } else {
                playerState = "PLAYING"
                currentTime = (json["currentTime"] as? NSNumber)?.doubleValue ?? 0
                reply(CastNamespace.media, mediaStatus())
            }
        case (CastNamespace.media, "PAUSE"):
            playerState = "PAUSED"
            reply(CastNamespace.media, mediaStatus())
        case (CastNamespace.media, "PLAY"):
            playerState = "PLAYING"
            reply(CastNamespace.media, mediaStatus())
        case (CastNamespace.media, "SEEK"):
            currentTime = (json["currentTime"] as? NSNumber)?.doubleValue ?? 0
            reply(CastNamespace.media, mediaStatus())
        case (CastNamespace.media, "GET_STATUS"):
            reply(CastNamespace.media, mediaStatus())
        default:
            break
        }
    }

    private func mediaStatus() -> [String: Any] {
        ["type": "MEDIA_STATUS", "status": [[
            "mediaSessionId": 7, "playerState": playerState, "currentTime": currentTime,
            "media": ["duration": 30.0],
        ] as [String: Any]]]
    }

    private func send(_ connection: NWConnection, from: String, to: String, _ namespace: String, _ payload: [String: Any]) {
        guard let text = try? JSONObject(payload).encodedString() else { return }
        let message = CastMessage(sourceID: from, destinationID: to, namespace: namespace, payloadUTF8: text)
        connection.send(content: message.framed(), completion: .idempotent)
    }
}
