import Foundation

/// HomeKit TLV8 encoding used by AirPlay pair-setup and pair-verify.
public enum TLVType: UInt8, Sendable {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
    case separator = 0xFF
}

public struct TLV8: Sendable, Equatable {
    public private(set) var items: [(type: UInt8, value: Data)]

    public init(_ items: [(TLVType, Data)] = []) {
        self.items = items.map { ($0.0.rawValue, $0.1) }
    }

    public subscript(type: TLVType) -> Data? {
        items.first(where: { $0.type == type.rawValue })?.value
    }

    public mutating func append(_ type: TLVType, _ value: Data) {
        items.append((type.rawValue, value))
    }

    public static func == (lhs: TLV8, rhs: TLV8) -> Bool {
        lhs.items.count == rhs.items.count && zip(lhs.items, rhs.items).allSatisfy { $0.type == $1.type && $0.value == $1.value }
    }

    /// Values longer than 255 bytes are split into consecutive fragments of the same type.
    public func encoded() -> Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty {
                out.append(contentsOf: [type, 0])
                continue
            }
            var offset = value.startIndex
            while offset < value.endIndex {
                let end = value.index(offset, offsetBy: 255, limitedBy: value.endIndex) ?? value.endIndex
                out.append(type)
                out.append(UInt8(value.distance(from: offset, to: end)))
                out.append(value[offset..<end])
                offset = end
            }
        }
        return out
    }

    /// Consecutive items of the same type are merged back into one value.
    public static func decode(_ data: Data) throws -> TLV8 {
        var result = TLV8()
        let bytes = [UInt8](data)
        var i = 0
        var previousType: UInt8?
        var previousWasFull = false
        while i < bytes.count {
            guard i + 1 < bytes.count else { throw AirstarError.protocolError("truncated TLV8 header") }
            let type = bytes[i]
            let length = Int(bytes[i + 1])
            i += 2
            guard i + length <= bytes.count else { throw AirstarError.protocolError("truncated TLV8 value") }
            let value = Data(bytes[i..<(i + length)])
            i += length
            if type == previousType, previousWasFull, !result.items.isEmpty {
                result.items[result.items.count - 1].value.append(value)
            } else {
                result.items.append((type, value))
            }
            previousType = type
            previousWasFull = length == 255
        }
        return result
    }
}

extension TLV8 {
    /// Throws when the accessory reported a pairing error (kTLVType_Error).
    func checkError(_ step: String) throws {
        guard let code = self[.error]?.first else { return }
        let reason: String
        switch code {
        case 0x02: reason = "authentication failed (wrong PIN?)"
        case 0x03: reason = "too many attempts, try again later"
        case 0x04: reason = "unknown peer"
        case 0x05: reason = "device cannot accept more pairings"
        case 0x06: reason = "too many failed attempts, device locked"
        case 0x07: reason = "device is busy pairing with another client"
        default: reason = "error code \(code)"
        }
        throw AirstarError.pairingFailed("\(step): \(reason)")
    }

    func require(_ type: TLVType, _ step: String) throws -> Data {
        guard let value = self[type] else {
            throw AirstarError.pairingFailed("\(step): missing \(type)")
        }
        return value
    }
}
