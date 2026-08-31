import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Bounded input reader")
struct BoundedInputReaderTests {
    @Test func acceptsTheExactByteBoundaryAcrossInternalChunks() throws {
        let data = Data(repeating: 0x61, count: 65_536)
        let handle = try temporaryHandle(containing: data)

        let value = try BoundedInputReader.readUTF8(from: handle, maximumBytes: 65_536)

        #expect(value.utf8.count == 65_536)
    }

    @Test func rejectsOneByteBeyondTheLimit() throws {
        let handle = try temporaryHandle(containing: Data(repeating: 0x61, count: 65_537))

        #expect(throws: BoundedInputReaderError.self) {
            _ = try BoundedInputReader.readUTF8(from: handle, maximumBytes: 65_536)
        }
    }

    @Test func decodesMultibyteTextOnlyAfterReadingToEOF() throws {
        let value = String(repeating: "🛠️", count: 2_000)
        let data = try #require(value.data(using: .utf8))
        let handle = try temporaryHandle(containing: data)

        let decoded = try BoundedInputReader.readUTF8(from: handle, maximumBytes: data.count)

        #expect(decoded == value)
    }

    private func temporaryHandle(containing data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BoundedInputReaderTests-\(UUID().uuidString)", directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forReadingFrom: url)
        try FileManager.default.removeItem(at: url)
        return handle
    }
}
