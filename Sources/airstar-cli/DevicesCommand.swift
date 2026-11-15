import AirstarCore
import ArgumentParser
import Foundation

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List AirPlay and Google Cast receivers on the local network."
    )

    @Option(help: "Seconds to browse for receivers.")
    var timeout: Double = 5

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    @Flag(help: "Show decoded AirPlay feature flags and TXT records.")
    var verbose = false

    struct Listing: Encodable {
        let airplay: [AirPlayDeviceSummary]
        let googleCast: [CastDeviceSummary]
    }

    func run() async throws {
        async let airPlayScan = AirPlayBrowser.scan(timeout: timeout)
        async let castScan = CastBrowser.scan(timeout: timeout)
        let (airPlay, cast) = try await (airPlayScan, castScan)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let listing = Listing(airplay: airPlay.map(AirPlayDeviceSummary.init), googleCast: cast.map(CastDeviceSummary.init))
            print(String(decoding: try encoder.encode(listing), as: UTF8.self))
            return
        }
        if airPlay.isEmpty && cast.isEmpty {
            print("No AirPlay or Google Cast receivers found.")
            return
        }
        if !airPlay.isEmpty { print("AirPlay:") }
        for device in airPlay {
            let address = device.host.map { "\($0):\(device.port ?? 0)" } ?? "unresolved"
            let video = device.supportsHLSVideo ? "HLS video" : "no HLS video"
            print("  \(device.name)  [\(device.model ?? "unknown model")]  \(address)")
            print("      \(device.protocolVersion.rawValue), \(video), pairing: \(device.defaultPairingMode.rawValue), id: \(device.deviceID ?? "-")")
            if verbose {
                print("      features: \(String(format: "0x%016llX", device.features.rawValue)) bits \(device.features.setBits)")
                print("      flags: \(device.features.describedFlags.joined(separator: ", "))")
                for key in device.txt.keys.sorted() {
                    print("      txt \(key)=\(device.txt[key] ?? "")")
                }
            }
        }
        if !cast.isEmpty { print("Google Cast:") }
        for device in cast {
            let address = device.host.map { "\($0):\(device.port ?? 0)" } ?? "unresolved"
            print("  \(device.name)  [\(device.model ?? "unknown model")]  \(address)")
            print("      \(device.supportsVideo ? "video" : "audio only"), id: \(device.id ?? "-")")
            if verbose {
                for key in device.txt.keys.sorted() {
                    print("      txt \(key)=\(device.txt[key] ?? "")")
                }
            }
        }
    }
}
