import Foundation
import Network

/// A TCP connection to a receiver carrying HTTP/RTSP messages, optionally HAP-encrypted.
/// Requests are strictly serialized: each waits for its response before the next is sent.
public actor AirPlayConnection {
    let connection: NWConnection
    private var session: HAPSession?
    private var parser = HTTPMessageParser()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: AirPlayDevice.tcpParameters())
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
                once.run { continuation.resume(throwing: AirstarError.timeout("connection to receiver")) }
            }
        }
    }

    /// Our IP address on the interface used to reach the receiver (what the receiver should fetch media from).
    public var localHost: String? {
        if case let .hostPort(host, _)? = connection.currentPath?.localEndpoint {
            return AirPlayBrowser.hostString(host)
        }
        return nil
    }

    public var remoteHost: String? {
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
            return AirPlayBrowser.hostString(host)
        }
        return nil
    }

    /// Encrypts everything after this point (called once pairing has produced a shared secret).
    public func enableEncryption(_ session: HAPSession) {
        self.session = session
    }

    public var isEncrypted: Bool { session != nil }

    public func send(_ request: AirPlayRequest, timeout: Double = 15) async throws -> AirPlayResponse {
        await acquire()
        defer { release() }
        var payload = request.serialized()
        if session != nil {
            payload = try session!.encrypt(payload)
        }
        // NWConnection reads ignore task cancellation, so a stalled receiver is handled by
        // cancelling the connection, which fails the pending read.
        let timedOut = TimeoutFlag()
        let timer = DispatchWorkItem { [connection] in
            timedOut.set()
            connection.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        do {
            try await write(payload)
            while true {
                if let response = try parser.nextResponse() {
                    Self.debugLog("\(request.method) \(request.path) -> \(response.status) (\(response.body.count) bytes\(session != nil ? ", encrypted" : ""))")
                    return response
                }
                var chunk = try await read()
                if session != nil {
                    chunk = try session!.decrypt(chunk)
                }
                parser.append(chunk)
            }
        } catch {
            if timedOut.isSet { throw AirstarError.timeout("\(request.method) \(request.path) response") }
            throw error
        }
    }

    public func close() {
        connection.cancel()
    }

    static let debugEnabled = ProcessInfo.processInfo.environment["AIRSTAR_DEBUG"] != nil

    /// Logs AirPlay traffic to stderr when AIRSTAR_DEBUG is set, for diagnosing receiver quirks.
    static func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("\n[airplay] \(message())\n".utf8))
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

    private func read() async throws -> Data {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: AirstarError.connectionFailed("receive failed: \(error)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: AirstarError.connectionFailed("receiver closed the connection"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Answers the requests an AirPlay 2 receiver sends on the event connection with 200 OK.
final class EventChannel: @unchecked Sendable {
    let connection: NWConnection
    private var session: HAPSession
    private var parser = HTTPMessageParser()
    private let queue = DispatchQueue(label: "airstar.events")

    init(endpoint: NWEndpoint, session: HAPSession) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.session = session
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive() }
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    parser.append(try session.decrypt(data))
                    while let request = try parser.nextRequest() {
                        let cseq = request.header("CSeq").map { ["CSeq": $0] } ?? [:]
                        let reply = AirPlayResponse(version: request.version, status: 200, headers: cseq)
                        connection.send(content: try session.encrypt(reply.serialized()), completion: .idempotent)
                    }
                } catch {
                    connection.cancel()
                    return
                }
            }
            if error == nil && !isComplete { receive() }
        }
    }
}
