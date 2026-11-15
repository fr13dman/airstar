import Foundation
import Testing
@testable import AirstarCore

/// End-to-end tests of `AirPlayClient` against `MockAirPlayReceiver` over real TCP on 127.0.0.1.
@Suite(.serialized) struct AirPlayClientTests {
    static let v1Features = "0x527FFFF7,0x1E"
    /// AirPlay 2 with HomeKit pairing and transient pairing.
    static let v2TransientFeatures = "0x4A7FCFD5,0x38174FDE"
    /// AirPlay 2 with HomeKit (PIN) pairing only.
    static let v2PINFeatures = "0x5A7FFFF7,0x38ACF46"

    func device(port: UInt16, features: String) -> AirPlayDevice {
        AirPlayDevice(name: "Mock TV", txt: ["features": features, "deviceid": "AA:00:00:00:00:01"], host: "127.0.0.1", port: port)
    }

    let mediaURL = URL(string: "http://127.0.0.1:9999/gen-1/index.m3u8")!

    @Test func airPlay1PlaybackIsPlainHTTP() async throws {
        let receiver = try MockAirPlayReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }

        let client = AirPlayClient(device: device(port: port, features: Self.v1Features), store: InMemoryPairingStore())
        try await client.connect()
        #expect(await client.localHost() == "127.0.0.1")
        try await client.play(url: mediaURL)
        try await client.setRate(0)
        try await client.scrub(to: 42)
        let info = try await client.playbackInfo()
        #expect(info.position == 5.5 && info.duration == 30 && info.readyToPlay)
        await client.stop()
        await client.close()

        let paths = receiver.received.map(\.path)
        #expect(paths == ["/play", "/rate?value=0.000000", "/scrub?position=42.000000", "/playback-info", "/stop"])
        #expect(receiver.received.allSatisfy { !$0.encrypted })
    }

    @Test func airPlay2TransientPairingEncryptsEverything() async throws {
        let receiver = try MockAirPlayReceiver()
        receiver.requireAuthentication = true
        let port = try await receiver.start()
        defer { receiver.stop() }

        let client = AirPlayClient(device: device(port: port, features: Self.v2TransientFeatures), store: InMemoryPairingStore())
        try await client.connect()
        try await client.play(url: mediaURL, startPosition: 3)
        #expect(try await client.setVolume(0.5))
        let info = try await client.playbackInfo()
        #expect(info.rate == 1)
        await client.close()

        let received = receiver.received
        #expect(received.prefix(2).map(\.path) == ["/pair-setup", "/pair-setup"])
        #expect(received.prefix(2).allSatisfy { !$0.encrypted })
        let afterPairing = received.dropFirst(2)
        #expect(afterPairing.first?.method == "SETUP")
        #expect(afterPairing.allSatisfy { $0.encrypted })
        let play = try #require(afterPairing.first { $0.path == "/play" })
        let body = try #require(try PropertyListSerialization.propertyList(from: play.body, format: nil) as? [String: Any])
        #expect(body["Content-Location"] as? String == mediaURL.absoluteString)
        #expect(body["Start-Position-Seconds"] as? Double == 3)
        #expect(afterPairing.contains { $0.method == "SET_PARAMETER" })
    }

    @Test func airPlay2PINPairingThenVerify() async throws {
        let receiver = try MockAirPlayReceiver(pin: "2468")
        receiver.requireAuthentication = true
        let port = try await receiver.start()
        defer { receiver.stop() }
        let store = InMemoryPairingStore()
        let tv = device(port: port, features: Self.v2PINFeatures)
        #expect(tv.defaultPairingMode == .pin)

        let unpaired = AirPlayClient(device: tv, store: store)
        await #expect(throws: AirstarError.pairingRequired("Mock TV")) { try await unpaired.connect() }
        await unpaired.close()

        let pairing = AirPlayClient(device: tv, store: store)
        let credentials = try await pairing.pair { "2468" }
        await pairing.close()
        #expect(try store.load(tv.pairingKey) == credentials)
        #expect(receiver.received.map(\.path).prefix(4) == ["/pair-pin-start", "/pair-setup", "/pair-setup", "/pair-setup"])

        let client = AirPlayClient(device: tv, store: store)
        try await client.connect()
        try await client.play(url: mediaURL)
        await client.close()
        let tail = receiver.received.suffix(4)
        #expect(tail.map(\.path).first == "/pair-verify")
        #expect(tail.last?.path == "/play" && tail.last?.encrypted == true)
    }

    @Test func wrongPINFailsPairing() async throws {
        let receiver = try MockAirPlayReceiver(pin: "2468")
        let port = try await receiver.start()
        defer { receiver.stop() }
        let client = AirPlayClient(device: device(port: port, features: Self.v2PINFeatures), store: InMemoryPairingStore())
        await #expect(throws: AirstarError.self) { try await client.pair { "0000" } }
        await client.close()
    }

    @Test func missingPlayEndpointIsExplained() async throws {
        let receiver = try MockAirPlayReceiver()
        receiver.playStatus = 404
        let port = try await receiver.start()
        defer { receiver.stop() }
        let client = AirPlayClient(device: device(port: port, features: Self.v2TransientFeatures), store: InMemoryPairingStore())
        try await client.connect()
        await #expect(throws: AirstarError.urlPlaybackUnsupported("Mock TV")) {
            try await client.play(url: mediaURL)
        }
        await client.close()
    }

    @Test func rejectedPlayIsReported() async throws {
        let receiver = try MockAirPlayReceiver()
        receiver.playStatus = 415
        let port = try await receiver.start()
        defer { receiver.stop() }
        let client = AirPlayClient(device: device(port: port, features: Self.v1Features), store: InMemoryPairingStore())
        try await client.connect()
        await #expect(throws: AirstarError.playbackFailed("Mock TV rejected /play (HTTP 415)")) {
            try await client.play(url: mediaURL)
        }
        // AirPlay 1 retries with a text/parameters body before giving up.
        #expect(receiver.received.filter { $0.path == "/play" }.count == 2)
        await client.close()
    }
}
