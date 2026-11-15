import Foundation
import Testing
@testable import AirstarCore

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test func tailKeepsLastLines() {
        let data = Data("a\nb\nc\nd\n".utf8)
        #expect(ProcessRunner.tail(data, lines: 2) == "c\nd")
    }

    @Test func timeoutThrows() async {
        await #expect(throws: AirstarError.timeout("sleep")) {
            try await withTimeout(0.05, "sleep") {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
