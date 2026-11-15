import AirstarCore
import ArgumentParser
import Foundation

struct PairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair with an AirPlay 2 TV using the PIN it shows on screen."
    )

    @Argument(help: "Receiver name, name fragment or device ID (see `devices`).")
    var device: String

    @Option(help: "PIN shown on the TV (prompted for when omitted).")
    var pin: String?

    @Flag(help: "Delete stored pairing credentials for this receiver instead of pairing.")
    var forget = false

    @Option(help: "Seconds to search for the receiver.")
    var timeout: Double = 5

    func run() async throws {
        let receiver = try AirPlayDevice.select(device, from: try await AirPlayBrowser.scan(timeout: timeout))
        let store = KeychainPairingStore()
        if forget {
            try store.remove(receiver.pairingKey)
            print("Removed pairing for \(receiver.name).")
            return
        }
        guard receiver.protocolVersion == .v2 else {
            print("\(receiver.name) is an AirPlay 1 receiver and does not need pairing.")
            return
        }

        let client = AirPlayClient(device: receiver, store: store)
        defer { Task { await client.close() } }
        let suppliedPIN = pin
        let name = receiver.name
        print("Requesting a PIN from \(name)…")
        try await client.pair {
            if let suppliedPIN { return suppliedPIN }
            print("Enter the PIN shown on \(name): ", terminator: "")
            guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
                throw AirstarError.pairingFailed("no PIN entered")
            }
            return line
        }
        print("Paired with \(name). Credentials are stored in your login Keychain.")
    }
}
