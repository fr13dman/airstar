import Foundation

/// The CastV2 envelope (`cast_channel.proto` CastMessage), hand-encoded to avoid a protobuf dependency.
///
///     message CastMessage {
///       required ProtocolVersion protocol_version = 1;  // CASTV2_1_0 = 0
///       required string source_id = 2;
///       required string destination_id = 3;
///       required string namespace = 4;
///       required PayloadType payload_type = 5;          // STRING = 0, BINARY = 1
///       optional string payload_utf8 = 6;
///       optional bytes payload_binary = 7;
///     }
public struct CastMessage: Sendable, Equatable {
    public var sourceID: String
    public var destinationID: String
    public var namespace: String
    public var payloadUTF8: String?
    public var payloadBinary: Data?

    public init(sourceID: String, destinationID: String, namespace: String, payloadUTF8: String? = nil, payloadBinary: Data? = nil) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payloadUTF8 = payloadUTF8
        self.payloadBinary = payloadBinary
    }

    public func encoded() -> Data {
        var out = Data()
        Protobuf.appendVarintField(1, 0, to: &out)
        Protobuf.appendBytesField(2, Data(sourceID.utf8), to: &out)
        Protobuf.appendBytesField(3, Data(destinationID.utf8), to: &out)
        Protobuf.appendBytesField(4, Data(namespace.utf8), to: &out)
        if let payloadBinary {
            Protobuf.appendVarintField(5, 1, to: &out)
            Protobuf.appendBytesField(7, payloadBinary, to: &out)
        } else {
            Protobuf.appendVarintField(5, 0, to: &out)
            Protobuf.appendBytesField(6, Data((payloadUTF8 ?? "").utf8), to: &out)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> CastMessage {
        var reader = Protobuf.Reader(data: data)
        var message = CastMessage(sourceID: "", destinationID: "", namespace: "")
        while let (field, wireType) = try reader.nextKey() {
            switch (field, wireType) {
            case (2, 2): message.sourceID = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (3, 2): message.destinationID = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (4, 2): message.namespace = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (6, 2): message.payloadUTF8 = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (7, 2): message.payloadBinary = try reader.lengthDelimited()
            default: try reader.skip(wireType)
            }
        }
        return message
    }

    /// Wire frame: 4-byte big-endian length followed by the encoded message.
    public func framed() -> Data {
        let body = encoded()
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    /// The JSON payload as a dictionary, if it is one.
    public var json: JSONObject? {
        guard let text = payloadUTF8,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return JSONObject(object)
    }
}

/// A decoded JSON dictionary that can cross actor boundaries (it is only ever read after creation).
public struct JSONObject: @unchecked Sendable {
    public let value: [String: Any]
    public init(_ value: [String: Any]) { self.value = value }

    public subscript(key: String) -> Any? { value[key] }
    public var type: String? { value["type"] as? String }
    public var requestID: Int? { (value["requestId"] as? NSNumber)?.intValue }

    public func encodedString() throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Splits a byte stream into CastV2 frames.
public struct CastFrameParser: Sendable {
    private var buffer = Data()
    static let maxFrame = 64 * 1024

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    public mutating func next() throws -> CastMessage? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= Self.maxFrame else { throw AirstarError.protocolError("Cast frame of \(length) bytes is too large") }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer[(start + 4)..<(start + 4 + length)]
        buffer = Data(buffer[(start + 4 + length)...])
        return try CastMessage.decode(Data(body))
    }
}

enum Protobuf {
    static func appendVarint(_ value: UInt64, to out: inout Data) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
    }

    static func appendVarintField(_ field: Int, _ value: UInt64, to out: inout Data) {
        appendVarint(UInt64(field << 3 | 0), to: &out)
        appendVarint(value, to: &out)
    }

    static func appendBytesField(_ field: Int, _ bytes: Data, to out: inout Data) {
        appendVarint(UInt64(field << 3 | 2), to: &out)
        appendVarint(UInt64(bytes.count), to: &out)
        out.append(bytes)
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(data: Data) { bytes = [UInt8](data) }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count else { throw AirstarError.protocolError("truncated protobuf varint") }
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                guard shift < 64 else { throw AirstarError.protocolError("protobuf varint too long") }
            }
        }

        mutating func nextKey() throws -> (Int, Int)? {
            guard index < bytes.count else { return nil }
            let key = try varint()
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func lengthDelimited() throws -> Data {
            let length = Int(try varint())
            guard length >= 0, index + length <= bytes.count else { throw AirstarError.protocolError("truncated protobuf field") }
            defer { index += length }
            return Data(bytes[index..<(index + length)])
        }

        mutating func skip(_ wireType: Int) throws {
            switch wireType {
            case 0: _ = try varint()
            case 1: index += 8
            case 2: _ = try lengthDelimited()
            case 5: index += 4
            default: throw AirstarError.protocolError("unsupported protobuf wire type \(wireType)")
            }
            guard index <= bytes.count else { throw AirstarError.protocolError("truncated protobuf field") }
        }
    }
}
