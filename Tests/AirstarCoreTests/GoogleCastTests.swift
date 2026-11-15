import Foundation
import Network
import Testing
@testable import AirstarCore

@Suite struct CastMessageTests {
    @Test func encodesKnownBytes() {
        let message = CastMessage(sourceID: "s", destinationID: "d", namespace: "n", payloadUTF8: "{}")
        let expected: [UInt8] = [0x08, 0x00, 0x12, 0x01, 0x73, 0x1A, 0x01, 0x64, 0x22, 0x01, 0x6E, 0x28, 0x00, 0x32, 0x02, 0x7B, 0x7D]
        #expect([UInt8](message.encoded()) == expected)
        #expect([UInt8](message.framed().prefix(4)) == [0, 0, 0, UInt8(expected.count)])
    }

    @Test func roundTripsStringAndBinaryPayloads() throws {
        let text = CastMessage(sourceID: "sender-0", destinationID: "receiver-0", namespace: CastNamespace.receiver, payloadUTF8: "{\"type\":\"LAUNCH\"}")
        #expect(try CastMessage.decode(text.encoded()) == text)
        let binary = CastMessage(sourceID: "a", destinationID: "b", namespace: "c", payloadBinary: Data([1, 2, 3]))
        #expect(try CastMessage.decode(binary.encoded()) == binary)
    }

    @Test func longStringsUseMultiByteVarints() throws {
        let payload = String(repeating: "x", count: 300)
        let message = CastMessage(sourceID: "s", destinationID: "d", namespace: "n", payloadUTF8: payload)
        #expect(try CastMessage.decode(message.encoded()).payloadUTF8 == payload)
    }

    @Test func skipsUnknownFields() throws {
        var data = CastMessage(sourceID: "s", destinationID: "d", namespace: "n", payloadUTF8: "{}").encoded()
        Protobuf.appendVarintField(15, 300, to: &data)
        Protobuf.appendBytesField(16, Data([9, 9]), to: &data)
        #expect(try CastMessage.decode(data).namespace == "n")
    }

    @Test func frameParserHandlesSplitAndBackToBackFrames() throws {
        let a = CastMessage(sourceID: "1", destinationID: "2", namespace: "x", payloadUTF8: "{\"type\":\"PING\"}")
        let b = CastMessage(sourceID: "3", destinationID: "4", namespace: "y", payloadUTF8: "{\"type\":\"PONG\"}")
        let stream = a.framed() + b.framed()
        var parser = CastFrameParser()
        parser.append(stream.prefix(3))
        #expect(try parser.next() == nil)
        parser.append(stream.dropFirst(3))
        #expect(try parser.next() == a)
        #expect(try parser.next() == b)
        #expect(try parser.next() == nil)
    }

    @Test func rejectsOversizedFrames() {
        var parser = CastFrameParser()
        parser.append(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        #expect(throws: AirstarError.self) { try parser.next() }
    }

    @Test func exposesJSONPayload() {
        let message = CastMessage(sourceID: "s", destinationID: "d", namespace: "n", payloadUTF8: "{\"type\":\"MEDIA_STATUS\",\"requestId\":4}")
        #expect(message.json?.type == "MEDIA_STATUS")
        #expect(message.json?.requestID == 4)
        #expect(CastMessage(sourceID: "s", destinationID: "d", namespace: "n", payloadUTF8: "not json").json == nil)
    }
}

@Suite struct CastModelTests {
    @Test func parsesMediaStatus() {
        let json = JSONObject(["type": "MEDIA_STATUS", "status": [[
            "mediaSessionId": 3, "playerState": "PAUSED", "currentTime": 42.5,
            "media": ["duration": 600.0], "volume": ["level": 0.4],
        ] as [String: Any]]])
        #expect(CastMediaStatus.parse(json) == CastMediaStatus(mediaSessionID: 3, playerState: "PAUSED", currentTime: 42.5, duration: 600, volume: 0.4))
        #expect(CastMediaStatus.parse(JSONObject(["status": [[String: Any]]()])) == CastMediaStatus())
        #expect(CastMediaStatus.parse(JSONObject(["type": "PONG"])) == nil)
    }

    @Test func mapsPlayerStatesToTargetStatus() {
        let playing = CastTarget.targetStatus(from: CastMediaStatus(playerState: "PLAYING", currentTime: 5))
        #expect(playing.isPlaying && playing.isReady && playing.position == 5)
        let buffering = CastTarget.targetStatus(from: CastMediaStatus(playerState: "BUFFERING"))
        #expect(!buffering.isPlaying && !buffering.isReady && !buffering.isIdle)
        let finished = CastTarget.targetStatus(from: CastMediaStatus(playerState: "IDLE", idleReason: "FINISHED"))
        #expect(finished.isIdle && finished.error == nil)
        let failed = CastTarget.targetStatus(from: CastMediaStatus(playerState: "IDLE", idleReason: "ERROR"))
        #expect(failed.error != nil)
    }

    @Test func loadPayloadDescribesHLSSegments() throws {
        let url = URL(string: "http://192.168.1.9:5555/gen-1/index.m3u8")!
        let ts = CastClient.loadPayload(url: url, segmentFormat: .mpegts, title: "Movie", startTime: 0)
        let media = try #require(ts["media"] as? [String: Any])
        #expect(media["contentId"] as? String == url.absoluteString)
        #expect(media["contentType"] as? String == "application/x-mpegURL")
        #expect(media["streamType"] as? String == "BUFFERED")
        #expect(media["hlsSegmentFormat"] as? String == "ts")
        #expect(media["hlsVideoSegmentFormat"] as? String == "mpeg2_ts")
        #expect((media["metadata"] as? [String: Any])?["title"] as? String == "Movie")
        let fmp4 = try #require(CastClient.loadPayload(url: url, segmentFormat: .fmp4, title: "M", startTime: 0)["media"] as? [String: Any])
        #expect(fmp4["hlsSegmentFormat"] as? String == "fmp4" && fmp4["hlsVideoSegmentFormat"] as? String == "fmp4")
    }

    @Test func errorRepliesBecomeErrors() {
        #expect(throws: AirstarError.playbackFailed("Cast receiver could not load the stream: LOAD_FAILED")) {
            try CastClient.check(JSONObject(["type": "LOAD_FAILED"]), expecting: "MEDIA_STATUS", action: "load the stream")
        }
        #expect(throws: Never.self) {
            try CastClient.check(JSONObject(["type": "MEDIA_STATUS"]), expecting: "MEDIA_STATUS", action: "x")
        }
    }

    @Test func castDeviceUsesFriendlyNameAndCapabilities() {
        let tv = CastDevice(instanceName: "Smart-TV-Pro-5b68", txt: ["fn": "Living Room TV", "md": "Smart TV Pro", "ca": "264709", "id": "5b68"])
        #expect(tv.name == "Living Room TV")
        #expect(tv.supportsVideo)
        let speaker = CastDevice(instanceName: "Nest-Mini", txt: ["fn": "Kitchen", "ca": "199172"])
        #expect(!speaker.supportsVideo)
        #expect(CastDevice(instanceName: "raw", txt: [:]).name == "raw")
    }
}

@Suite struct MediaReceiverSelectionTests {
    static let airPlayTV = AirPlayDevice(name: "Living Room TV", txt: ["features": "0x7F8AD0,0x38BCF46", "deviceid": "D6:9E:84:F6:38:FF"])
    static let nebula = AirPlayDevice(name: "Nebula-21708A", txt: ["features": "0x527FFFF7,0x1E"])
    static let castTV = CastDevice(instanceName: "Smart-TV-Pro-5b68", txt: ["fn": "Living Room TV", "ca": "264709", "id": "5b68"])
    static let speaker = CastDevice(instanceName: "Nest-Mini", txt: ["fn": "Living Room speaker", "ca": "199172"])

    @Test func autoPrefersGoogleCastForTheSameTV() throws {
        let receiver = try MediaReceiver.select("living room tv", airPlay: [Self.airPlayTV, Self.nebula], googleCast: [Self.castTV, Self.speaker], via: .auto)
        #expect(receiver.protocolName == "Google Cast")
        #expect(receiver.name == "Living Room TV")
    }

    @Test func autoFallsBackToAirPlay() throws {
        let receiver = try MediaReceiver.select("nebula", airPlay: [Self.airPlayTV, Self.nebula], googleCast: [Self.castTV], via: .auto)
        #expect(receiver.protocolName == "AirPlay")
    }

    @Test func explicitProtocolIsHonored() throws {
        let airPlay = try MediaReceiver.select("living room tv", airPlay: [Self.airPlayTV], googleCast: [Self.castTV], via: .airplay)
        #expect(airPlay.protocolName == "AirPlay")
        #expect(throws: AirstarError.deviceNotFound("nebula")) {
            try MediaReceiver.select("nebula", airPlay: [Self.nebula], googleCast: [Self.castTV], via: .googlecast)
        }
    }

    @Test func audioOnlyCastDevicesAreIgnored() throws {
        let receiver = try MediaReceiver.select("living room", airPlay: [], googleCast: [Self.castTV, Self.speaker], via: .auto)
        #expect(receiver.name == "Living Room TV")
    }

    @Test func matchesCastDeviceID() throws {
        let receiver = try MediaReceiver.select("5b68", airPlay: [], googleCast: [Self.castTV], via: .auto)
        #expect(receiver.protocolName == "Google Cast")
    }

    @Test func castPortProbe() async throws {
        let receiver = try MockCastReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        #expect(await CastBrowser.isCastPortOpen(host: "127.0.0.1", port: port))
        receiver.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!(await CastBrowser.isCastPortOpen(host: "127.0.0.1", port: port, timeout: 1)))
    }
}

/// End-to-end tests of `CastClient` and `CastTarget` against `MockCastReceiver` over TCP.
@Suite(.serialized) struct CastClientTests {
    func device(port: UInt16) -> CastDevice {
        CastDevice(instanceName: "mock", txt: ["fn": "Mock TV", "ca": "1"], host: "127.0.0.1", port: port)
    }

    let url = URL(string: "http://127.0.0.1:9999/gen-1/index.m3u8")!

    @Test func fullPlaybackSession() async throws {
        let receiver = try MockCastReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }

        let client = CastClient(device: device(port: port), useTLS: false)
        try await client.connect()
        #expect(await client.localHost() == "127.0.0.1")
        let target = CastTarget(client: client, displayName: "Mock TV", title: "Movie")

        try await target.load(url: url, segmentFormat: .mpegts)
        #expect(await client.transportID == "transport-1")
        #expect(await client.mediaSessionID == 7)
        var status = try await target.status()
        #expect(status.isPlaying)

        try await target.pause()
        status = try await target.status()
        #expect(!status.isPlaying && status.isReady)
        try await target.seek(to: 12)
        try await target.play()
        status = try await target.status()
        #expect(status.isPlaying && status.position == 12)
        #expect(try await target.setVolume(0.3))

        // A second load (e.g. after an audio switch) reuses the running receiver app.
        try await target.load(url: url, segmentFormat: .mpegts)
        await target.stop()

        #expect(receiver.types(in: CastNamespace.receiver) == ["LAUNCH", "SET_VOLUME", "STOP"])
        #expect(receiver.types(in: CastNamespace.media) == ["LOAD", "GET_STATUS", "PAUSE", "GET_STATUS", "SEEK", "PLAY", "GET_STATUS", "LOAD"])
        let connects = receiver.received.filter { $0.type == "CONNECT" }.map(\.destination)
        #expect(connects == ["receiver-0", "transport-1"])
        #expect(receiver.received.filter { $0.namespace == CastNamespace.media }.allSatisfy { $0.destination == "transport-1" })
        let seek = try #require(receiver.received.first { $0.type == "SEEK" })
        #expect((seek.payload["mediaSessionId"] as? NSNumber)?.intValue == 7)
        let load = try #require(receiver.received.first { $0.type == "LOAD" })
        #expect(((load.payload["media"] as? [String: Any])?["contentId"] as? String) == url.absoluteString)
    }

    @Test func answersReceiverHeartbeat() async throws {
        let receiver = try MockCastReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let client = CastClient(device: device(port: port), useTLS: false)
        try await client.connect()
        for _ in 0..<20 where !receiver.types(in: CastNamespace.heartbeat).contains("PONG") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(receiver.types(in: CastNamespace.heartbeat).contains("PONG"))
        await client.close()
    }

    @Test func loadFailureIsReported() async throws {
        let receiver = try MockCastReceiver()
        receiver.failLoad = true
        let port = try await receiver.start()
        defer { receiver.stop() }
        let client = CastClient(device: device(port: port), useTLS: false)
        try await client.connect()
        let target = CastTarget(client: client, displayName: "Mock TV", title: "Movie")
        await #expect(throws: AirstarError.playbackFailed("Cast receiver could not load the stream: LOAD_FAILED")) {
            try await target.load(url: url, segmentFormat: .mpegts)
        }
        await client.close()
    }

    @Test func commandsBeforeLoadFailCleanly() async throws {
        let receiver = try MockCastReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let client = CastClient(device: device(port: port), useTLS: false)
        try await client.connect()
        await #expect(throws: AirstarError.self) { try await client.pause() }
        await client.close()
    }

    @Test func connectingToClosedPortFails() async throws {
        let receiver = try MockCastReceiver()
        let port = try await receiver.start()
        receiver.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let client = CastClient(device: device(port: port), useTLS: false)
        await #expect(throws: AirstarError.self) { try await client.connect() }
        await client.close()
    }
}
