import Foundation

/// The playback state of the media session on a Cast receiver (`MEDIA_STATUS`).
public struct CastMediaStatus: Sendable, Equatable {
    public var mediaSessionID: Int?
    /// IDLE, BUFFERING, PLAYING or PAUSED.
    public var playerState: String
    /// FINISHED, CANCELLED, INTERRUPTED or ERROR when IDLE.
    public var idleReason: String?
    public var currentTime: Double
    public var duration: Double?
    public var volume: Double?

    public init(mediaSessionID: Int? = nil, playerState: String = "IDLE", idleReason: String? = nil, currentTime: Double = 0, duration: Double? = nil, volume: Double? = nil) {
        self.mediaSessionID = mediaSessionID
        self.playerState = playerState
        self.idleReason = idleReason
        self.currentTime = currentTime
        self.duration = duration
        self.volume = volume
    }

    /// Parses the first entry of a MEDIA_STATUS `status` array; an empty array means no media is loaded.
    public static func parse(_ json: JSONObject) -> CastMediaStatus? {
        guard let entries = json["status"] as? [[String: Any]] else { return nil }
        guard let entry = entries.first else { return CastMediaStatus() }
        let media = entry["media"] as? [String: Any]
        let volume = entry["volume"] as? [String: Any]
        return CastMediaStatus(
            mediaSessionID: (entry["mediaSessionId"] as? NSNumber)?.intValue,
            playerState: entry["playerState"] as? String ?? "IDLE",
            idleReason: entry["idleReason"] as? String,
            currentTime: (entry["currentTime"] as? NSNumber)?.doubleValue ?? 0,
            duration: (media?["duration"] as? NSNumber)?.doubleValue,
            volume: (volume?["level"] as? NSNumber)?.doubleValue
        )
    }
}

/// Controls the Default Media Receiver app on a Google Cast device.
public actor CastClient {
    /// Google's Default Media Receiver, which plays HLS, DASH and progressive URLs.
    public static let defaultMediaReceiverAppID = "CC1AD845"

    public let device: CastDevice
    let channel: CastChannel
    private(set) var transportID: String?
    private(set) var sessionID: String?
    private(set) var mediaSessionID: Int?
    private var lastStatus: CastMediaStatus?

    public init(device: CastDevice, useTLS: Bool = true) {
        self.device = device
        self.channel = CastChannel(endpoint: device.endpoint, useTLS: useTLS)
    }

    public func connect() async throws {
        try await channel.connect()
        await channel.setUnsolicitedHandler { [weak self] namespace, json in
            guard let self else { return }
            Task { await self.unsolicited(namespace, json) }
        }
    }

    public func localHost() async -> String? {
        await channel.localHost
    }

    /// Launches (or reuses) the Default Media Receiver and opens a virtual connection to it.
    public func launch() async throws {
        let status = try await channel.request(CastNamespace.receiver, to: CastChannel.platformReceiverID, [
            "type": "LAUNCH", "appId": Self.defaultMediaReceiverAppID,
        ], timeout: 30)
        try Self.check(status, expecting: "RECEIVER_STATUS", action: "launch the media receiver")
        guard let app = Self.application(in: status, appID: Self.defaultMediaReceiverAppID),
              let transport = app["transportId"] as? String else {
            throw AirstarError.playbackFailed("\(device.name) did not start the Default Media Receiver")
        }
        transportID = transport
        sessionID = app["sessionId"] as? String
        try await channel.send(CastNamespace.connection, to: transport, ["type": "CONNECT"])
    }

    /// Asks the receiver to load and play an HLS playlist.
    public func load(url: URL, segmentFormat: SegmentFormat, title: String, startTime: Double = 0) async throws {
        let transport = try requireTransport()
        let reply = try await channel.request(CastNamespace.media, to: transport, Self.loadPayload(
            url: url, segmentFormat: segmentFormat, title: title, startTime: startTime
        ), timeout: 30)
        try Self.check(reply, expecting: "MEDIA_STATUS", action: "load the stream")
        let status = CastMediaStatus.parse(reply)
        mediaSessionID = status?.mediaSessionID
        lastStatus = status
    }

    public func play() async throws { try await mediaCommand(["type": "PLAY"]) }
    public func pause() async throws { try await mediaCommand(["type": "PAUSE"]) }

    public func seek(to seconds: Double) async throws {
        try await mediaCommand(["type": "SEEK", "currentTime": seconds, "resumeState": "PLAYBACK_START"])
    }

    public func status() async throws -> CastMediaStatus {
        let transport = try requireTransport()
        let reply = try await channel.request(CastNamespace.media, to: transport, ["type": "GET_STATUS"], timeout: 5)
        let status = CastMediaStatus.parse(reply) ?? CastMediaStatus()
        if let id = status.mediaSessionID { mediaSessionID = id }
        lastStatus = status
        return status
    }

    public func setVolume(_ level: Double) async throws {
        let reply = try await channel.request(CastNamespace.receiver, to: CastChannel.platformReceiverID, [
            "type": "SET_VOLUME", "volume": ["level": min(max(level, 0), 1)],
        ], timeout: 5)
        try Self.check(reply, expecting: "RECEIVER_STATUS", action: "change the volume")
    }

    /// Stops the media receiver app on the TV and closes the connection.
    public func stop() async {
        if let sessionID {
            _ = try? await channel.request(CastNamespace.receiver, to: CastChannel.platformReceiverID, [
                "type": "STOP", "sessionId": sessionID,
            ], timeout: 5)
        }
        await channel.close()
    }

    public func close() async {
        await channel.close()
    }

    private func mediaCommand(_ payload: [String: Any]) async throws {
        let transport = try requireTransport()
        guard let mediaSessionID else { throw AirstarError.playbackFailed("no media is loaded on \(device.name)") }
        var body = payload
        body["mediaSessionId"] = mediaSessionID
        let reply = try await channel.request(CastNamespace.media, to: transport, body, timeout: 10)
        try Self.check(reply, expecting: "MEDIA_STATUS", action: (payload["type"] as? String ?? "command").lowercased())
        if let status = CastMediaStatus.parse(reply) { lastStatus = status }
    }

    private func unsolicited(_ namespace: String, _ json: JSONObject) {
        if namespace == CastNamespace.media, json.type == "MEDIA_STATUS", let status = CastMediaStatus.parse(json) {
            if let id = status.mediaSessionID { mediaSessionID = id }
            lastStatus = status
        }
    }

    private func requireTransport() throws -> String {
        guard let transportID else { throw AirstarError.playbackFailed("media receiver is not running on \(device.name)") }
        return transportID
    }

    static func loadPayload(url: URL, segmentFormat: SegmentFormat, title: String, startTime: Double) -> [String: Any] {
        [
            "type": "LOAD",
            "autoplay": true,
            "currentTime": startTime,
            "media": [
                "contentId": url.absoluteString,
                "contentUrl": url.absoluteString,
                "contentType": "application/x-mpegURL",
                "streamType": "BUFFERED",
                "hlsSegmentFormat": segmentFormat == .fmp4 ? "fmp4" : "ts",
                "hlsVideoSegmentFormat": segmentFormat == .fmp4 ? "fmp4" : "mpeg2_ts",
                "metadata": ["type": 0, "metadataType": 0, "title": title],
            ] as [String: Any],
        ]
    }

    static func application(in status: JSONObject, appID: String) -> [String: Any]? {
        let receiverStatus = status["status"] as? [String: Any]
        let apps = receiverStatus?["applications"] as? [[String: Any]] ?? []
        return apps.first { ($0["appId"] as? String) == appID }
    }

    /// Turns LOAD_FAILED, LAUNCH_ERROR, INVALID_REQUEST and similar replies into errors.
    static func check(_ reply: JSONObject, expecting type: String, action: String) throws {
        guard let actual = reply.type, actual != type else { return }
        let reason = reply["reason"] as? String ?? (reply["detailedErrorCode"] as? NSNumber).map { "code \($0)" }
        throw AirstarError.playbackFailed("Cast receiver could not \(action): \(actual)\(reason.map { " (\($0))" } ?? "")")
    }
}
