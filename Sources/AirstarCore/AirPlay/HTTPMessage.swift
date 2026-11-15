import Foundation

/// HTTP/1.1 or RTSP/1.0 request as sent over the AirPlay control connection.
public struct AirPlayRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var version: String
    public var headers: [(String, String)]
    public var body: Data

    public init(method: String, path: String, version: String = "HTTP/1.1", headers: [(String, String)] = [], body: Data = Data()) {
        self.method = method
        self.path = path
        self.version = version
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame })?.1
    }

    public func serialized() -> Data {
        var text = "\(method) \(path) \(version)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if header("Content-Length") == nil {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    public static func == (lhs: AirPlayRequest, rhs: AirPlayRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.version == rhs.version && lhs.body == rhs.body
            && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
    }
}

public struct AirPlayResponse: Sendable, Equatable {
    public var version: String
    public var status: Int
    public var reason: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(version: String = "HTTP/1.1", status: Int, reason: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.version = version
        self.status = status
        self.reason = reason
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func serialized() -> Data {
        var text = "\(version) \(status) \(reason)\r\n"
        for (name, value) in headers where name != "content-length" { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\n\r\n"
        return Data(text.utf8) + body
    }
}

/// Incremental parser for HTTP/RTSP messages with Content-Length framed bodies.
public struct HTTPMessageParser: Sendable {
    private var buffer = Data()
    static let separator = Data("\r\n\r\n".utf8)

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextResponse() throws -> AirPlayResponse? {
        guard let (startLine, headers, body) = try nextMessage() else { return nil }
        let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw AirstarError.protocolError("malformed status line: \(startLine)")
        }
        return AirPlayResponse(version: parts[0], status: status, reason: parts.count > 2 ? parts[2] : "", headers: headers, body: body)
    }

    public mutating func nextRequest() throws -> AirPlayRequest? {
        guard let (startLine, headers, body) = try nextMessage() else { return nil }
        let parts = startLine.split(separator: " ").map(String.init)
        guard parts.count == 3 else { throw AirstarError.protocolError("malformed request line: \(startLine)") }
        return AirPlayRequest(method: parts[0], path: parts[1], version: parts[2], headers: headers.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }, body: body)
    }

    private mutating func nextMessage() throws -> (String, [String: String], Data)? {
        guard let headerEnd = buffer.range(of: Self.separator) else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let startLine = lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return (startLine, headers, body)
    }
}
