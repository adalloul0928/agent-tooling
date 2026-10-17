import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Packaged app resources")
struct AppResourcesTests {
    @Test("A relocated app resolves its own Contents/Resources bundle")
    func resolvesPackagedBundle() throws {
        let folder = try TemporaryFolder("packaged-resources")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let appURL = folder.url.appending(path: "Relocated App.app", directoryHint: .isDirectory)
        let resources = appURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let resourceURL = resources.appending(path: "AgentTooling_AgentToolingApp.bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.example.resource-test"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: appURL.appending(path: "Contents/Info.plist"))
        let marker = resourceURL.appending(path: "marker.txt")
        try Data("packaged".utf8).write(to: marker)

        let app = try #require(Bundle(url: appURL))
        let resolved = try #require(AppResources.packagedBundle(in: app))

        #expect(resolved.bundleURL.resolvingSymlinksInPath() == resourceURL.resolvingSymlinksInPath())
        let foundMarker = try #require(resolved.url(forResource: "marker", withExtension: "txt"))
        #expect(try String(contentsOf: foundMarker, encoding: .utf8) == "packaged")
    }

    @Test("A missing packaged bundle is left to SwiftPM's development fallback")
    func missingPackagedBundle() throws {
        let folder = try TemporaryFolder("missing-packaged-resources")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let app = try #require(Bundle(url: folder.url))

        #expect(AppResources.packagedBundle(in: app) == nil)
    }
}
