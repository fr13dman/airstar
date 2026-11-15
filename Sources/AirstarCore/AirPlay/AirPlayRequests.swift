import Foundation

/// Builds the HTTP/RTSP requests airstar-cli sends to receivers.
public enum AirPlayRequests {
    public static let userAgent = "AirPlay/550.10"
    static let binaryPlist = "application/x-apple-binary-plist"

    static func baseHeaders(sessionID: String) -> [(String, String)] {
        [("User-Agent", userAgent), ("X-Apple-Session-ID", sessionID)]
    }

    static func pairingHeaders(transient: Bool) -> [(String, String)] {
        [
            ("User-Agent", userAgent),
            ("Connection", "keep-alive"),
            ("X-Apple-HKP", transient ? "4" : "3"),
            ("Content-Type", "application/octet-stream"),
        ]
    }

    public static func pairPinStart() -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/pair-pin-start", headers: pairingHeaders(transient: false))
    }

    public static func pairSetup(_ body: Data, transient: Bool) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/pair-setup", headers: pairingHeaders(transient: transient), body: body)
    }

    public static func pairVerify(_ body: Data) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/pair-verify", headers: pairingHeaders(transient: false), body: body)
    }

    /// AirPlay 1 `/play`: binary plist with a fractional start position.
    public static func playV1(url: URL, startFraction: Double, sessionID: String) throws -> AirPlayRequest {
        let body: [String: Any] = [
            "Content-Location": url.absoluteString,
            "Start-Position": startFraction,
        ]
        return AirPlayRequest(
            method: "POST", path: "/play",
            headers: baseHeaders(sessionID: sessionID) + [("Content-Type", binaryPlist)],
            body: try plist(body)
        )
    }

    /// AirPlay 1 `/play` fallback for receivers that only accept text parameters.
    public static func playV1Text(url: URL, startFraction: Double, sessionID: String) -> AirPlayRequest {
        let text = "Content-Location: \(url.absoluteString)\nStart-Position: \(String(format: "%.6f", startFraction))\n"
        return AirPlayRequest(
            method: "POST", path: "/play",
            headers: baseHeaders(sessionID: sessionID) + [("Content-Type", "text/parameters")],
            body: Data(text.utf8)
        )
    }

    /// AirPlay 2 `/play`, modelled on what iOS sends for URL playback.
    public static func playV2(url: URL, startSeconds: Double, sessionID: String, senderID: String) throws -> AirPlayRequest {
        let body: [String: Any] = [
            "Content-Location": url.absoluteString,
            "Start-Position-Seconds": startSeconds,
            "uuid": sessionID,
            "streamType": 1,
            "mediaType": "file",
            "volume": 1.0,
            "rate": 1.0,
            "mightSupportStorePastisKeyRequests": true,
            "playbackRestrictions": 0,
            "secureConnectionMs": 22,
            "infoPlistData": Data(),
            "clientProcName": "airstar-cli",
            "clientBundleID": "com.airstar.cli",
            "SenderMACAddress": senderID,
            "model": "Mac",
            "postAuthMs": 0,
            "authMs": 0,
            "bonjourMs": 0,
            "connectMs": 0,
        ]
        return AirPlayRequest(
            method: "POST", path: "/play",
            headers: baseHeaders(sessionID: sessionID) + [("Content-Type", binaryPlist)],
            body: try plist(body)
        )
    }

    /// AirPlay 2 RTSP SETUP for a remote-control-only session (no audio stream); returns an event port.
    public static func setupRemoteControl(rtspURL: String, cseq: Int, sessionID: String, senderID: String) throws -> AirPlayRequest {
        let body: [String: Any] = [
            "deviceID": senderID,
            "macAddress": senderID,
            "sessionUUID": sessionID,
            "timingProtocol": "None",
            "isRemoteControlOnly": true,
            "osName": "macOS",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": "Mac",
            "name": "airstar-cli",
            "sourceVersion": "550.10",
        ]
        return AirPlayRequest(
            method: "SETUP", path: rtspURL, version: "RTSP/1.0",
            headers: [("CSeq", "\(cseq)"), ("User-Agent", userAgent), ("Content-Type", binaryPlist)],
            body: try plist(body)
        )
    }

    public static func feedback(rtspURL: String, cseq: Int) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/feedback", version: "RTSP/1.0", headers: [("CSeq", "\(cseq)"), ("User-Agent", userAgent)])
    }

    public static func volume(rtspURL: String, cseq: Int, fraction: Double) -> AirPlayRequest {
        let body = "volume: \(String(format: "%.6f", volumeDecibels(fraction)))\r\n"
        return AirPlayRequest(
            method: "SET_PARAMETER", path: rtspURL, version: "RTSP/1.0",
            headers: [("CSeq", "\(cseq)"), ("User-Agent", userAgent), ("Content-Type", "text/parameters")],
            body: Data(body.utf8)
        )
    }

    public static func volumeV1(fraction: Double, sessionID: String) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/volume?volume=\(String(format: "%.6f", fraction))", headers: baseHeaders(sessionID: sessionID))
    }

    /// AirPlay volume is -30 dB (quietest) to 0 dB, with -144 meaning mute.
    public static func volumeDecibels(_ fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return clamped == 0 ? -144 : -30 + 30 * clamped
    }

    public static func rate(_ value: Double, sessionID: String) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/rate?value=\(String(format: "%.6f", value))", headers: baseHeaders(sessionID: sessionID))
    }

    public static func scrub(to seconds: Double, sessionID: String) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/scrub?position=\(String(format: "%.6f", seconds))", headers: baseHeaders(sessionID: sessionID))
    }

    public static func playbackInfo(sessionID: String) -> AirPlayRequest {
        AirPlayRequest(method: "GET", path: "/playback-info", headers: baseHeaders(sessionID: sessionID))
    }

    public static func stop(sessionID: String) -> AirPlayRequest {
        AirPlayRequest(method: "POST", path: "/stop", headers: baseHeaders(sessionID: sessionID))
    }

    static func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
