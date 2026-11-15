import BigInt
import CryptoKit
import Foundation
import Testing
@testable import AirstarCore

@Suite struct TLV8Tests {
    @Test func roundTripsShortValues() throws {
        let tlv = TLV8([(.state, Data([1])), (.method, Data([0])), (.identifier, Data("abc".utf8))])
        let encoded = tlv.encoded()
        #expect(encoded == Data([0x06, 0x01, 0x01, 0x00, 0x01, 0x00, 0x01, 0x03, 0x61, 0x62, 0x63]))
        #expect(try TLV8.decode(encoded) == tlv)
    }

    @Test func fragmentsAndReassemblesLongValues() throws {
        let key = Data((0..<384).map { UInt8($0 & 0xFF) })
        let tlv = TLV8([(.publicKey, key), (.state, Data([3]))])
        let encoded = tlv.encoded()
        #expect(encoded.count == 2 + 255 + 2 + 129 + 3)
        #expect(encoded[0] == 0x03 && encoded[1] == 0xFF && encoded[257] == 0x03 && encoded[258] == 129)
        let decoded = try TLV8.decode(encoded)
        #expect(decoded[.publicKey] == key)
        #expect(decoded[.state] == Data([3]))
    }

    @Test func separatesRepeatedTypesWithShortValues() throws {
        let decoded = try TLV8.decode(Data([0x01, 0x01, 0xAA, 0x01, 0x01, 0xBB]))
        #expect(decoded.items.count == 2)
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: AirstarError.self) { try TLV8.decode(Data([0x06, 0x05, 0x01])) }
    }

    @Test func reportsAccessoryErrors() throws {
        let tlv = try TLV8.decode(TLV8([(.state, Data([4])), (.error, Data([0x02]))]).encoded())
        #expect(throws: AirstarError.pairingFailed("pair-setup M4: authentication failed (wrong PIN?)")) {
            try tlv.checkError("pair-setup M4")
        }
    }
}

@Suite struct SRPTests {
    /// RFC 5054 Appendix B test vectors (1024-bit group, SHA-1).
    static let rfcGroup = SRPGroup(
        N: BigUInt("EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3", radix: 16)!,
        g: 2,
        hash: { Data(Insecure.SHA1.hash(data: $0)) }
    )

    @Test func matchesRFC5054Vectors() throws {
        let a = BigUInt("60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393", radix: 16)!
        let client = SRPClient(group: Self.rfcGroup, username: "alice", privateKey: a)
        let salt = Data(hex: "BEB25379D1A8581EB5A727673A2441EE")
        #expect(client.k() == BigUInt("7556AA045AEF2CDD07ABAF0F665C3E818913186F", radix: 16)!)
        #expect(client.x(salt: salt, password: "password123") == BigUInt("94B7555AABE9127CC58CCF4993DB6CF84D16C124", radix: 16)!)
        #expect(client.A == BigUInt("61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E8903211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B", radix: 16)!)

        let B = BigUInt("BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58", radix: 16)!
        #expect(client.u(B: B) == BigUInt("CE38B9593487DA98554ED47D70A7AE5F462EF019", radix: 16)!)
        let session = try client.session(salt: salt, serverPublicKey: B.serialize(), password: "password123")
        #expect(session.premasterSecret == BigUInt("B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E359B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB33943CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A", radix: 16)!)
    }

    @Test func rejectsZeroServerKey() {
        let client = SRPClient()
        #expect(throws: AirstarError.self) {
            try client.session(salt: Data([1]), serverPublicKey: SRPGroup.hap3072.N.serialize(), password: "1234")
        }
    }

    @Test func hapGroupIs3072Bits() {
        #expect(SRPGroup.hap3072.N.bitWidth == 3072)
        #expect(SRPGroup.hap3072.length == 384)
    }
}

@Suite struct HAPSessionTests {
    @Test func encryptsAndDecryptsAcrossFrames() throws {
        var client = HAPSession.control(sharedSecret: Data(repeating: 7, count: 32))
        var server = client.peer
        let message = Data((0..<3000).map { UInt8($0 % 251) })
        let wire = try client.encrypt(message)
        #expect(wire.count == message.count + 3 * (2 + 16))
        var received = Data()
        // Feed in odd-sized chunks to exercise buffering of partial frames.
        var offset = 0
        while offset < wire.count {
            let end = min(offset + 700, wire.count)
            received.append(try server.decrypt(wire.subdata(in: offset..<end)))
            offset = end
        }
        #expect(received == message)

        let reply = try server.encrypt(Data("RTSP/1.0 200 OK\r\n\r\n".utf8))
        #expect(try client.decrypt(reply) == Data("RTSP/1.0 200 OK\r\n\r\n".utf8))
    }

    @Test func tamperedFrameFailsToDecrypt() throws {
        var client = HAPSession.control(sharedSecret: Data(repeating: 1, count: 32))
        var server = client.peer
        var wire = try client.encrypt(Data("hello".utf8))
        wire[3] ^= 0xFF
        #expect(throws: AirstarError.self) { try server.decrypt(wire) }
    }

    @Test func controlAndEventKeysDiffer() throws {
        var control = HAPSession.control(sharedSecret: Data(repeating: 9, count: 32))
        var events = HAPSession.events(sharedSecret: Data(repeating: 9, count: 32))
        #expect(try control.encrypt(Data([1])) != events.encrypt(Data([1])))
    }
}

@Suite struct PairingFlowTests {
    @Test func pinPairSetupThenPairVerifyAgreeOnSecret() throws {
        let accessory = MockHAPAccessory(pin: "4321")
        var setup = PairSetup(clientID: "airstar-test")
        let m2 = try accessory.handlePairSetup(setup.m1())
        let m4 = try accessory.handlePairSetup(try setup.m3(fromM2: m2, pin: "4321"))
        try setup.verifyM4(m4)
        let m6 = try accessory.handlePairSetup(try setup.m5())
        let credentials = try setup.finish(m6: m6)
        #expect(credentials.accessoryID == accessory.accessoryID)
        #expect(credentials.accessoryPublicKey == accessory.signingKey.publicKey.rawRepresentation)
        #expect(accessory.pairedClients["airstar-test"] != nil)

        var verify = PairVerify(credentials: credentials)
        let vm2 = try accessory.handlePairVerify(verify.m1())
        let vm4 = try accessory.handlePairVerify(try verify.m3(fromM2: vm2))
        let secret = try verify.finish(m4: vm4)
        #expect(secret == accessory.establishedSecret)
    }

    @Test func wrongPINIsRejected() throws {
        let accessory = MockHAPAccessory(pin: "4321")
        var setup = PairSetup()
        let m2 = try accessory.handlePairSetup(setup.m1())
        let m4 = try accessory.handlePairSetup(try setup.m3(fromM2: m2, pin: "0000"))
        #expect(throws: AirstarError.pairingFailed("pair-setup M4: authentication failed (wrong PIN?)")) {
            try setup.verifyM4(m4)
        }
    }

    @Test func transientPairingUsesSessionKey() throws {
        let accessory = MockHAPAccessory(pin: "unused")
        var setup = PairSetup(transient: true)
        #expect(try TLV8.decode(setup.m1())[.flags] == Data([0x10]))
        let m2 = try accessory.handlePairSetup(setup.m1())
        let m4 = try accessory.handlePairSetup(try setup.m3(fromM2: m2, pin: PairSetup.transientPIN))
        try setup.verifyM4(m4)
        #expect(setup.sessionKey != nil)
        #expect(setup.sessionKey == accessory.establishedSecret)
    }

    @Test func verifyRejectsImpostorAccessory() throws {
        let real = MockHAPAccessory(pin: "1111")
        var setup = PairSetup(clientID: "c1")
        let m2 = try real.handlePairSetup(setup.m1())
        let m4 = try real.handlePairSetup(try setup.m3(fromM2: m2, pin: "1111"))
        try setup.verifyM4(m4)
        let credentials = try setup.finish(m6: try real.handlePairSetup(try setup.m5()))

        let impostor = MockHAPAccessory(pin: "1111")
        var verify = PairVerify(credentials: credentials)
        let vm2 = try impostor.handlePairVerify(verify.m1())
        #expect(throws: AirstarError.self) { try verify.m3(fromM2: vm2) }
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryPairingStore()
        let credentials = PairingCredentials(clientID: "c", clientPrivateKey: Data([1]), accessoryID: Data([2]), accessoryPublicKey: Data([3]))
        #expect(try store.load("tv") == nil)
        try store.save(credentials, for: "tv")
        #expect(try store.load("tv") == credentials)
        try store.remove("tv")
        #expect(try store.load("tv") == nil)
    }
}

@Suite struct HTTPMessageTests {
    @Test func serializesRequestWithContentLength() {
        let request = AirPlayRequest(method: "POST", path: "/rate?value=1.000000", headers: [("User-Agent", "x")], body: Data("ab".utf8))
        #expect(String(decoding: request.serialized(), as: UTF8.self) == "POST /rate?value=1.000000 HTTP/1.1\r\nUser-Agent: x\r\nContent-Length: 2\r\n\r\nab")
    }

    @Test func parsesResponsesIncrementally() throws {
        var parser = HTTPMessageParser()
        parser.append(Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Le".utf8))
        #expect(try parser.nextResponse() == nil)
        parser.append(Data("ngth: 4\r\n\r\nbodyHTTP/1.1 470 Connection Authorization Required\r\n\r\n".utf8))
        let first = try #require(try parser.nextResponse())
        #expect(first.version == "RTSP/1.0" && first.status == 200 && first.headers["cseq"] == "3" && first.body == Data("body".utf8))
        let second = try #require(try parser.nextResponse())
        #expect(second.status == 470 && second.reason == "Connection Authorization Required")
        #expect(try parser.nextResponse() == nil)
    }

    @Test func parsesRequests() throws {
        var parser = HTTPMessageParser()
        parser.append(Data("POST /event RTSP/1.0\r\nCSeq: 9\r\nContent-Length: 0\r\n\r\n".utf8))
        let request = try #require(try parser.nextRequest())
        #expect(request.method == "POST" && request.path == "/event" && request.header("CSeq") == "9")
    }

    @Test func rejectsMalformedStatusLine() {
        var parser = HTTPMessageParser()
        parser.append(Data("garbage\r\n\r\n".utf8))
        #expect(throws: AirstarError.self) { try parser.nextResponse() }
    }
}

@Suite struct AirPlayRequestTests {
    let url = URL(string: "http://192.168.1.9:5555/gen-1/index.m3u8")!

    func plist(_ request: AirPlayRequest) throws -> [String: Any] {
        try #require(try PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any])
    }

    @Test func playV1Body() throws {
        let request = try AirPlayRequests.playV1(url: url, startFraction: 0, sessionID: "S1")
        #expect(request.method == "POST" && request.path == "/play")
        #expect(request.header("Content-Type") == "application/x-apple-binary-plist")
        #expect(request.header("X-Apple-Session-ID") == "S1")
        let body = try plist(request)
        #expect(body["Content-Location"] as? String == url.absoluteString)
        #expect(body["Start-Position"] as? Double == 0)
    }

    @Test func playV1TextFallback() {
        let request = AirPlayRequests.playV1Text(url: url, startFraction: 0, sessionID: "S1")
        #expect(String(decoding: request.body, as: UTF8.self) == "Content-Location: \(url.absoluteString)\nStart-Position: 0.000000\n")
    }

    @Test func playV2Body() throws {
        let request = try AirPlayRequests.playV2(url: url, startSeconds: 12.5, sessionID: "S2", senderID: "02:00:00:00:00:01")
        let body = try plist(request)
        #expect(body["Content-Location"] as? String == url.absoluteString)
        #expect(body["Start-Position-Seconds"] as? Double == 12.5)
        #expect(body["uuid"] as? String == "S2")
        #expect(body["streamType"] as? Int == 1)
        #expect(body["mediaType"] as? String == "file")
    }

    @Test func controlRequests() {
        #expect(AirPlayRequests.rate(0, sessionID: "s").path == "/rate?value=0.000000")
        #expect(AirPlayRequests.scrub(to: 61.25, sessionID: "s").path == "/scrub?position=61.250000")
        #expect(AirPlayRequests.playbackInfo(sessionID: "s").method == "GET")
        #expect(AirPlayRequests.stop(sessionID: "s").path == "/stop")
    }

    @Test func pairingHeaders() {
        #expect(AirPlayRequests.pairSetup(Data(), transient: true).header("X-Apple-HKP") == "4")
        #expect(AirPlayRequests.pairSetup(Data(), transient: false).header("X-Apple-HKP") == "3")
        #expect(AirPlayRequests.pairVerify(Data()).header("Content-Type") == "application/octet-stream")
    }

    @Test func setupIsRemoteControlOnly() throws {
        let request = try AirPlayRequests.setupRemoteControl(rtspURL: "rtsp://192.168.1.9/1", cseq: 1, sessionID: "S", senderID: "02:00:00:00:00:01")
        #expect(request.method == "SETUP" && request.version == "RTSP/1.0" && request.header("CSeq") == "1")
        let body = try plist(request)
        #expect(body["isRemoteControlOnly"] as? Bool == true)
        #expect(body["timingProtocol"] as? String == "None")
    }

    @Test func volumeMapsToDecibels() {
        #expect(AirPlayRequests.volumeDecibels(1) == 0)
        #expect(AirPlayRequests.volumeDecibels(0.5) == -15)
        #expect(AirPlayRequests.volumeDecibels(0) == -144)
        #expect(AirPlayRequests.volumeDecibels(2) == 0)
        let request = AirPlayRequests.volume(rtspURL: "rtsp://h/1", cseq: 4, fraction: 0.5)
        #expect(String(decoding: request.body, as: UTF8.self) == "volume: -15.000000\r\n")
    }

    @Test func senderIDIsLocallyAdministeredUnicast() {
        let id = AirPlayClient.randomSenderID()
        let first = UInt8(id.prefix(2), radix: 16)!
        #expect(first & 0x02 == 0x02 && first & 0x01 == 0)
        #expect(id.split(separator: ":").count == 6)
    }
}

@Suite struct PlaybackInfoTests {
    @Test func parsesPlayingState() throws {
        let body = try PropertyListSerialization.data(fromPropertyList: ["duration": 120.0, "position": 30.5, "rate": 1.0, "readyToPlay": true], format: .binary, options: 0)
        let info = try PlaybackInfo.parse(body)
        #expect(info == PlaybackInfo(duration: 120, position: 30.5, rate: 1, readyToPlay: true))
    }

    @Test func emptyBodyMeansIdle() throws {
        #expect(try PlaybackInfo.parse(Data()) == PlaybackInfo())
    }

    @Test func surfacesReceiverErrors() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>error</key><dict><key>code</key><integer>-12938</integer><key>domain</key><string>CoreMediaErrorDomain</string></dict></dict></plist>
        """
        let info = try PlaybackInfo.parse(Data(xml.utf8))
        #expect(info.errorDescription == "error -12938 (CoreMediaErrorDomain)")
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
