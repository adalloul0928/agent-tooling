import Foundation
import Testing

@testable import AgentToolingCore

/// `readApps` paginates `app/list` up to ten pages. The parser used to keep up
/// to 1000 rows per page while the loop asked for 100, so a server answering
/// with large pages could pile up to 10,000 apps in memory before the
/// accessible set was filtered. The parse cap must match the requested page
/// size, and the total kept across pages must be bounded.
@Suite("Accounts · the Codex app list is bounded across pages")
struct CodexAccountReaderPaginationTests {
    /// Answers the read-only handshake and a scripted `app/list` that returns a
    /// full page of distinct accessible apps for many pages, so the kept set
    /// would grow unbounded without a cap. The ids are unique across pages, so
    /// de-duplication cannot hide a missing cap.
    actor PaginatingAppServer: CodexAppServerTransport {
        private var queue: [Data] = []
        private var isClosed = false
        let appsPerPage: Int
        let pageCount: Int

        init(appsPerPage: Int, pageCount: Int) {
            self.appsPerPage = appsPerPage
            self.pageCount = pageCount
        }

        func send(_ line: Data) async throws {
            guard !isClosed else { throw CodexAppServerError.stopped("closed") }
            let message = try AgentToolingCoding.decoder().decode(JSONValue.self, from: line)
            guard case .number(let id)? = message["id"], let method = message["method"]?.stringValue else { return }
            let result: JSONValue
            switch method {
            case "initialize":
                result = .object(["userAgent": .string("agent_tooling/0.162.1 (Mac OS 26.7.1; arm64)")])
            case "account/read":
                result = .object([
                    "account": .object(["type": .string("chatgpt"), "email": .string("me@example.com"), "planType": .string("plus")]),
                    "requiresOpenaiAuth": .bool(true),
                ])
            case "config/read":
                result = .object([
                    "config": .object([:]),
                    "layers": .array([.object([
                        "name": .object(["type": .string("user"), "file": .string("/Users/example/.codex/config.toml")]),
                        "config": .object([:]),
                    ])]),
                ])
            case "app/list":
                let cursorString = message["params"]?["cursor"]?.stringValue
                let page = cursorString.flatMap { Int($0) } ?? 0
                let rows = (0..<appsPerPage).map { index -> JSONValue in
                    .object([
                        "id": .string("app-\(page)-\(index)"),
                        "name": .string("App \(page)-\(index)"),
                        "isAccessible": .bool(true),
                        "isEnabled": .bool(true),
                    ])
                }
                let next = page + 1
                result = .object([
                    "data": .array(rows),
                    "nextCursor": next < pageCount ? .string(String(next)) : .null,
                ])
            case "app/installed":
                result = .object(["apps": .array([])])
            default:
                result = .object([:])
            }
            queue.append(try AgentToolingCoding.encoder().encode(JSONValue.object([
                "id": .number(id), "result": result,
            ])))
        }

        func receive() async throws -> Data? {
            while queue.isEmpty {
                if isClosed { return nil }
                try await Task.sleep(for: .milliseconds(2))
            }
            return queue.removeFirst()
        }

        func diagnostics() async -> String { "paginating" }
        func close() async { isClosed = true }
    }

    @Test func aServerWithLargePagesYieldsABoundedAccessibleSet() async throws {
        let server = PaginatingAppServer(appsPerPage: 1_000, pageCount: 15)
        let reader = CodexAccountReader(
            homeURL: URL(filePath: "/Users/example", directoryHint: .isDirectory),
            locate: { _, _ in URL(filePath: "/opt/homebrew/bin/codex") },
            makeSession: { _, _ in CodexAppServerSession(transport: server) })
        let observation = await reader.read(contents: true, now: Date(timeIntervalSince1970: 1_000))
        #expect(observation.unavailableReason == nil)
        let apps = observation.items(.app)
        #expect(apps.count <= 1_000, "the kept accessible set is bounded, not 10 pages of 1000")
        #expect(Set(apps.map(\.key)).count == apps.count, "no app is listed twice")
    }
}
