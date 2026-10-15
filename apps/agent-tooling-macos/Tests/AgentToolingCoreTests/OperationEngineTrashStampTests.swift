import Foundation
import Testing

@testable import AgentToolingCore

/// Dated trash folders are named by `trashStamp()`. The stamp is used only to
/// sort removals by time and is never parsed, but a stamp in the Mac's local
/// time zone sorts out of order across a DST change and is not comparable
/// across Macs in a synced workspace. The stamp must be in UTC and say so.
///
/// `trashStamp()` is private; its output is observed through the public edit
/// path, which keeps the original file under a dated trash folder, so the test
/// does not widen access to reach it.
@Suite("Operation engine · trash folder stamps are UTC")
struct OperationEngineTrashStampTests {
    @Test func aTrashFolderIsNamedInUTCWithAMarker() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "OperationEngineTrashStampTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: ".kiro/settings"), withIntermediateDirectories: true)
        let file = home.appending(path: ".kiro/settings/mcp.json")
        try #"{"mcpServers":{"memory":{"command":"x"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let store = try WorkspaceRevisionStore(
            containerRoot: root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let engine = OperationEngine(store: store, homeURL: home)
        let edit = ClientConfigurationEdit(file: .kiroMCP, keyPath: ["mcpServers", "memory", "disabled"], value: .bool(true))
        let plan = OperationPlan(kind: .configureMCP, title: "t", summary: "s", steps: [
            .init(kind: .editClientConfiguration, title: "e", detail: edit.summary,
                  destinationPath: file.path(percentEncoded: false), contents: try edit.encoded()),
        ])
        let before = Date()

        let receipt = await engine.execute(plan)
        #expect(receipt.results.first?.status == .succeeded, Comment(rawValue: receipt.results.first?.output ?? ""))

        let trash = store.rootURL.appending(path: "trash", directoryHint: .isDirectory)
        let stamps = try FileManager.default.contentsOfDirectory(atPath: trash.path(percentEncoded: false))
        let stamp = try #require(stamps.first)

        // yyyy-MM-dd-HHmmss, a UTC marker, then the dash and the id suffix.
        let marked = stamp.firstIndex(of: "Z")
        #expect(marked != nil, "the stamp carries a UTC marker: \(stamp)")
        let dateText = String(stamp.prefix { $0 != "Z" })

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let parsed = try #require(formatter.date(from: dateText), "the date reads as UTC: \(dateText)")
        // The stamp is this instant, read in UTC: a wide window so the test is
        // not flaky, but tight enough that a local-time stamp off by hours fails
        // in any zone that is hours from UTC.
        #expect(abs(parsed.timeIntervalSince(before)) < 90 * 60, "the UTC instant matches now, not a local-time reading")
    }
}
