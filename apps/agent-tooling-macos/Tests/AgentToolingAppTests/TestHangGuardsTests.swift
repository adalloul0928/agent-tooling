import AgentToolingTestSupport
import Foundation
import Testing

/// Every suite's time limit is the five-minute hang guard. A plain `swift
/// test`, the release workflow's command, starts nearly every test at once,
/// so a main-actor test can wait behind all the others for almost the whole
/// run: a shorter limit fails it for waiting its turn, not for hanging.
@Suite("Test hang guards")
struct TestHangGuardsTests {
    @Test func everyTimeLimitIsFiveMinutes() throws {
        let limit = try NSRegularExpression(pattern: #"\.timeLimit\(\.minutes\((\d+)\)\)"#)
        var short: [String] = []
        for file in try PackageSourceFile.all(under: "Tests") {
            for (index, line) in file.lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for match in limit.matches(in: line, range: range) {
                    guard let minutes = Range(match.range(at: 1), in: line).flatMap({ Int(line[$0]) }) else { continue }
                    if minutes < 5 { short.append("\(file.path):\(index + 1) \(minutes) min") }
                }
            }
        }
        #expect(short.isEmpty, "a limit under five minutes: \(short.joined(separator: ", "))")
    }
}
