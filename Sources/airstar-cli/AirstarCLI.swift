import ArgumentParser
import Foundation

@main
struct AirstarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "airstar-cli",
        abstract: "Play MKV files locally or stream them to AirPlay TVs.",
        version: "0.1.0",
        subcommands: [DevicesCommand.self, InfoCommand.self, PlayCommand.self, CastCommand.self, PairCommand.self]
    )

    static func main() async {
        // Line-buffer stdout so progress shows up immediately when output is piped or logged.
        setvbuf(stdout, nil, _IOLBF, 0)
        await main(nil)
    }
}
