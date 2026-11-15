import Foundation
import Network
import Testing
@testable import AirstarCore

@Suite struct FeatureFlagsTests {
    @Test func parsesLowAndHighWords() throws {
        let flags = try #require(FeatureFlags(txtValue: "0x527FFFF7,0x1E"))
        #expect(flags.rawValue == 0x0000_001E_527F_FFF7)
        #expect(flags.contains(.video))
        #expect(flags.contains(.videoHTTPLiveStreams))
        #expect(!flags.contains(.supportsHKPairingAndAccessControl))
    }

    @Test func parsesSingleWord() throws {
        let flags = try #require(FeatureFlags(txtValue: "0x5A7FFFF7"))
        #expect(flags.rawValue == 0x5A7F_FFF7)
    }

    @Test func rejectsGarbage() {
        #expect(FeatureFlags(txtValue: "nope") == nil)
        #expect(FeatureFlags(txtValue: "0x1,0x2,0x3") == nil)
    }

    @Test func macReceiverIsAirPlay2WithHomeKitPairing() throws {
        let flags = try #require(FeatureFlags(txtValue: "0x4A7FCFD5,0x38174FDE"))
        #expect(flags.contains(.supportsHKPairingAndAccessControl))
        #expect(flags.contains(.supportsCoreUtilsPairingAndEncryption))
        #expect(flags.describedFlags.contains("VideoHTTPLiveStreams"))
    }
}

@Suite struct AirPlayDeviceTests {
    // TXT records captured from real receivers on the development network.
    static let nebula = AirPlayDevice(name: "Nebula-21708A", txt: [
        "deviceid": "8C:85:80:21:70:8A", "features": "0x527FFFF7,0x1E", "model": "AppleTV3,2",
        "pw": "0", "srcvers": "220.68", "flag": "0x44", "vv": "2",
    ])
    static let mac = AirPlayDevice(name: "Shaheen’s MacBook Pro", txt: [
        "deviceid": "9A:42:B2:40:04:52", "features": "0x4A7FCFD5,0x38174FDE", "model": "Mac16,6",
        "srcvers": "1005.13.1", "flags": "0x204",
    ])
    static let tclLike = AirPlayDevice(name: "TCL 65C755", txt: [
        "deviceid": "AA:BB:CC:DD:EE:FF", "features": "0x5A7FFFF7,0x38ACF46", "model": "TCL Google TV",
    ])

    /// TXT record of a real TCL 55T7 (Google TV, AirPlay 2 SDK 377.40).
    static let tcl55T7 = AirPlayDevice(name: "Living Room TV", txt: [
        "deviceid": "D6:9E:84:F6:38:FF", "features": "0x7F8AD0,0x38BCF46", "model": "55T7",
        "manufacturer": "TCL", "srcvers": "377.40.00", "flags": "0x244", "protovers": "1.1",
    ])

    @Test func tclTVSupportsHLSVideoWithoutLegacyVideoBit() {
        let tv = Self.tcl55T7
        #expect(!tv.features.contains(.video))
        #expect(tv.features.contains(.videoHTTPLiveStreams))
        #expect(tv.supportsHLSVideo)
        #expect(tv.protocolVersion == .v2)
        #expect(tv.defaultPairingMode == .transient)
    }

    @Test func receiverWithoutAnyVideoBitIsRejected() {
        let speaker = AirPlayDevice(name: "Speaker", txt: ["features": "0x445F8A00,0x1C340"])
        #expect(!speaker.supportsHLSVideo)
    }

    @Test func legacyReceiverNeedsNoPairing() {
        #expect(Self.nebula.protocolVersion == .v1)
        #expect(Self.nebula.defaultPairingMode == .none)
        #expect(Self.nebula.supportsHLSVideo)
        #expect(!Self.nebula.requiresPassword)
    }

    @Test func airPlay2ReceiverPrefersTransientWhenAdvertised() {
        #expect(Self.mac.protocolVersion == .v2)
        #expect(Self.mac.defaultPairingMode == .transient)
    }

    @Test func airPlay2WithoutTransientRequiresPIN() {
        #expect(Self.tclLike.protocolVersion == .v2)
        #expect(Self.tclLike.defaultPairingMode == .pin)
    }

    @Test func selectByExactNamePartialAndID() throws {
        let all = [Self.nebula, Self.mac, Self.tclLike]
        #expect(try AirPlayDevice.select("nebula-21708a", from: all).name == "Nebula-21708A")
        #expect(try AirPlayDevice.select("tcl", from: all).name == "TCL 65C755")
        #expect(try AirPlayDevice.select("9a:42:b2:40:04:52", from: all).name == "Shaheen’s MacBook Pro")
    }

    @Test func selectReportsMissingAndAmbiguous() {
        let all = [Self.nebula, Self.mac, Self.tclLike]
        #expect(throws: AirstarError.deviceNotFound("sony")) { try AirPlayDevice.select("sony", from: all) }
        #expect(throws: AirstarError.self) { try AirPlayDevice.select("a", from: all) }
    }

    @Test func discoveredDevicesConnectThroughBonjourEvenAfterResolution() {
        var device = Self.nebula
        if case .service = device.endpoint {} else { Issue.record("expected Bonjour service endpoint") }
        device.host = "fe80::1"
        device.port = 7000
        if case .service = device.endpoint {} else { Issue.record("expected Bonjour service endpoint") }
    }

    @Test func explicitAddressIsUsedDirectly() {
        let device = AirPlayDevice(name: "manual", txt: [:], host: "127.0.0.1", port: 7000)
        if case .hostPort = device.endpoint {} else { Issue.record("expected host/port endpoint") }
    }

    @Test func hostStringStripsInterfaceScope() {
        #expect(AirPlayBrowser.hostString(.ipv4(IPv4Address("192.168.1.7%en0")!)) == "192.168.1.7")
        #expect(AirPlayBrowser.hostString(.ipv6(IPv6Address("fe80::1%lo0")!)) == "fe80::1")
        #expect(AirPlayBrowser.hostString(.name("tv.local", nil)) == "tv.local")
    }

    @Test func summaryEncodesFeatureNames() throws {
        let data = try JSONEncoder().encode(AirPlayDeviceSummary(Self.nebula))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("VideoHTTPLiveStreams"))
        #expect(json.contains("\"pairing\":\"none\""))
    }
}
