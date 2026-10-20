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

    @Test("A missing packaged bundle does not resolve")
    func missingPackagedBundle() throws {
        let folder = try TemporaryFolder("missing-packaged-resources")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let app = try #require(Bundle(url: folder.url))

        #expect(AppResources.packagedBundle(in: app) == nil)
    }

    @Test("Development resources follow a relocated executable or test bundle")
    func resolvesAdjacentDevelopmentBundle() throws {
        let folder = try TemporaryFolder("relocated-development-resources")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let products = folder.url.appending(path: "products", directoryHint: .isDirectory)
        let resourceURL = products.appending(path: "AgentTooling_AgentToolingApp.bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        try Data("Fixture dependency notice".utf8).write(to: resourceURL.appending(path: "ThirdPartyNotices.txt"))

        let executableBundle = try #require(
            AppResources.developmentBundle(
                executableURL: products.appending(path: "AgentTooling"),
                codeBundleURL: folder.url.appending(path: "unrelated")))
        #expect(executableBundle.bundleURL == resourceURL)
        try AppResources.verifyNotices(in: executableBundle)

        let testBundle = try #require(
            AppResources.developmentBundle(
                executableURL: nil, codeBundleURL: products.appending(path: "Tests.xctest")))
        #expect(testBundle.bundleURL == resourceURL)
        try AppResources.verifyNotices(in: testBundle)
    }

    @Test("Missing development resources do not fall back to the original build directory")
    func missingDevelopmentBundle() throws {
        let folder = try TemporaryFolder("missing-development-resources")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        #expect(
            AppResources.developmentBundle(
                executableURL: folder.url.appending(path: "AgentTooling"),
                codeBundleURL: folder.url.appending(path: "Tests.xctest")) == nil)
    }

    @Test("The app bundles the dependency license notice")
    func dependencyNoticeIsBundled() throws {
        try AppResources.verifyNotices(in: AppResources.bundle)
        let url = try #require(AppResources.bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let notices = try String(contentsOf: url, encoding: .utf8)
        #expect(notices.contains("Yams 6.2.2"))
        #expect(notices.contains("Copyright (c) 2016 JP Simard."))
        #expect(notices.contains("Permission is hereby granted"))
    }

    @Test("Verification rejects missing and empty notices")
    func rejectsMissingOrEmptyNotices() throws {
        for contents: String? in [nil, " \n"] {
            let folder = try TemporaryFolder("invalid-notices")
            defer { try? FileManager.default.removeItem(at: folder.url) }
            if let contents {
                try Data(contents.utf8).write(to: folder.url.appending(path: "ThirdPartyNotices.txt"))
            }
            let resources = try #require(Bundle(url: folder.url))
            #expect(throws: (any Error).self) {
                try AppResources.verifyNotices(in: resources)
            }
        }
    }
}
