import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Where a copy of Agent Tooling runs from, read off real bundles in a
/// scratch folder: Applications and ~/Applications, a disk image, the
/// temporary place macOS translocates a download to, Downloads, a build
/// folder, and the helpers that make a copy registrable or not.
@Suite("Agent Tooling installation")
struct AgentToolingInstallationTests {
    // MARK: - The location matrix

    @Test func aCopyInApplicationsMayRegisterItsHelperAndIsNotMoved() throws {
        let place = try Place()
        defer { place.remove() }
        for folder in [place.home.appending(path: "Applications"), place.rehearsalApplications] {
            let bundle = try place.bundle(in: folder)
            let copy = place.inspect(bundle, rehearsal: .init(applicationsFolder: place.rehearsalApplications))

            #expect(copy.location == .applications(bundle.deletingLastPathComponent()), "\(folder.path)")
            #expect(copy.registrableHelperPath == bundle.appending(path: "Contents/Helpers/agent-tooling-mcp").path(percentEncoded: false))
            #expect(copy.cliHelperURL == bundle.appending(path: "Contents/Helpers/agent-tooling"))
            #expect(!copy.offersMove)
        }
    }

    /// Setup offers only a helper path the command records: each path a copy
    /// in Applications offers is one the command takes, and one in an
    /// Applications folder on a mounted volume, which can go away, is none.
    @Test func theRegistrablePathIsOneTheCommandTakes() throws {
        let place = try Place()
        defer { place.remove() }
        let bundle = try place.bundle(in: place.home.appending(path: "Applications"))
        let offered = try #require(place.inspect(bundle).registrableHelperPath)
        #expect(throws: Never.self) {
            _ = try ConnectAgentToolingCommand(expectedRevisionID: WorkspaceObjectID(), helperPath: offered, apps: [.codex])
        }

        let mounted = URL(filePath: "/Volumes/External/Users/example/Applications", directoryHint: .isDirectory)
        let helper = mounted.appending(path: "Agent Tooling.app/Contents/Helpers/agent-tooling-mcp")
        let copy = AgentToolingInstallation(
            bundleURL: mounted.appending(path: "Agent Tooling.app", directoryHint: .isDirectory), location: .applications(mounted),
            mcpHelperURL: helper, cliHelperURL: nil, isAdHocSigned: false)
        #expect(copy.registrableHelperPath == nil)
        #expect(!ConnectAgentToolingCommand.accepts(helperPath: helper.path(percentEncoded: false)))
        #expect(throws: ConnectAgentToolingError.self) {
            _ = try ConnectAgentToolingCommand(
                expectedRevisionID: WorkspaceObjectID(), helperPath: helper.path(percentEncoded: false), apps: [.codex])
        }
    }

    @Test func aReadOnlyVolumeIsADiskImageAndIsOfferedTheMove() throws {
        let place = try Place()
        defer { place.remove() }
        let volume = place.root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
        let bundle = try place.bundle(in: volume)

        let copy = place.inspect(bundle) { _ in .init(isReadOnly: true, name: "Agent Tooling", url: volume) }

        #expect(copy.location == .diskImage(volumeName: "Agent Tooling", volumeURL: volume))
        #expect(copy.offersMove)
        #expect(copy.registrableHelperPath == nil)
    }

    @Test func aTranslocatedCopyIsOfferedTheMove() throws {
        let place = try Place()
        defer { place.remove() }
        let folder = place.root.appending(path: "private/var/folders/xy/T/AppTranslocation/0B1C/d", directoryHint: .isDirectory)
        let bundle = try place.bundle(in: folder)

        let copy = place.inspect(bundle)

        #expect(copy.location == .translocated(folder))
        #expect(copy.offersMove)
        #expect(copy.registrableHelperPath == nil)
    }

    @Test func aCopyInDownloadsIsElsewhereAndOfferedTheMoveUnlessItIsAdHoc() throws {
        let place = try Place()
        defer { place.remove() }
        let downloads = place.home.appending(path: "Downloads", directoryHint: .isDirectory)
        let bundle = try place.bundle(in: downloads)

        #expect(place.inspect(bundle).location == .elsewhere(downloads))
        #expect(place.inspect(bundle).offersMove)
        #expect(!place.inspect(bundle, adHoc: true).offersMove)
    }

    /// The disk image a local build was packaged into still moves; the same
    /// build left in its `.build` folder stays where it is.
    @Test func anAdHocDiskImageOffersTheMoveAndAnAdHocBuildFolderCopyDoesNot() throws {
        let place = try Place()
        defer { place.remove() }
        let volume = place.root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
        let image = try place.bundle(in: volume)
        let build = try place.bundle(in: place.root.appending(path: "agent-tooling/apps/agent-tooling-macos/.build"))

        let fromImage = place.inspect(image, adHoc: true) { _ in .init(isReadOnly: true, name: "Agent Tooling", url: volume) }
        let fromBuild = place.inspect(build, adHoc: true)

        #expect(fromImage.offersMove)
        #expect(fromImage.isAdHocSigned)
        #expect(fromBuild.location == .elsewhere(build.deletingLastPathComponent()))
        #expect(!fromBuild.offersMove)
        #expect(fromBuild.registrableHelperPath == nil)
    }

    @Test func aBundleWithoutItsHelperOrNotAnAppIsADevelopmentBuild() throws {
        let place = try Place()
        defer { place.remove() }
        let applications = place.home.appending(path: "Applications", directoryHint: .isDirectory)
        let bare = try place.bundle(in: applications, helpers: false)
        let products = place.root.appending(path: ".build/arm64-apple-macosx/debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)

        for copy in [place.inspect(bare), place.inspect(products)] {
            #expect(copy.location == .developmentBuild, "\(copy.bundleURL.path)")
            #expect(copy.mcpHelperURL == nil)
            #expect(!copy.offersMove)
            #expect(copy.registrableHelperPath == nil)
        }
    }

    /// A helper counts only as a regular executable whose real path stays
    /// inside the bundle: a link out of it, or a file that cannot run, is
    /// no helper.
    @Test func aHelperThatLeavesTheBundleOrCannotRunIsNoHelper() throws {
        let place = try Place()
        defer { place.remove() }
        let applications = place.home.appending(path: "Applications", directoryHint: .isDirectory)
        let linked = try place.bundle(in: applications, named: "Linked.app", helpers: false)
        let outside = place.root.appending(path: "elsewhere/agent-tooling-mcp")
        try write(outside, "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path(percentEncoded: false))
        let helpers = linked.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: helpers.appending(path: "agent-tooling-mcp"), withDestinationURL: outside)
        let inert = try place.bundle(in: applications, named: "Inert.app", helpers: false)
        try write(inert.appending(path: "Contents/Helpers/agent-tooling-mcp"), "#!/bin/sh\n")

        #expect(place.inspect(linked).mcpHelperURL == nil)
        #expect(place.inspect(linked).location == .developmentBuild)
        #expect(place.inspect(inert).mcpHelperURL == nil)
    }

    // MARK: - Rehearsals (D41)

    @Test func aRehearsalIsReadOnlyWithAScratchWorkspace() {
        let rehearsal = AgentToolingInstallation.Rehearsal.parse([
            "/Applications/Agent Tooling.app/Contents/MacOS/AgentTooling", "--workspace", "/tmp/qa/ws",
            "--installation-override", "disk-image", "--applications-folder", "/tmp/qa/Apps",
        ])
        #expect(rehearsal?.override == .diskImage)
        #expect(rehearsal?.applicationsFolder == URL(filePath: "/tmp/qa/Apps", directoryHint: .isDirectory))

        #expect(AgentToolingInstallation.Rehearsal.parse(["app", "--installation-override", "disk-image"]) == nil)
        #expect(AgentToolingInstallation.Rehearsal.parse(["app", "--workspace", "/tmp/qa/ws"]) == nil)
        #expect(
            AgentToolingInstallation.Rehearsal.parse(["app", "--workspace", "/tmp/qa/ws", "--installation-override", "moon"])
                == nil)
        #expect(
            AgentToolingInstallation.Rehearsal.parse(["app", "--workspace", "/tmp/qa/ws", "--applications-folder", "/tmp/qa/Apps"])?
                .override == nil)
    }

    @Test func aRehearsalsOverrideNamesTheLocation() throws {
        let place = try Place()
        defer { place.remove() }
        let build = try place.bundle(in: place.root.appending(path: "build"))
        let folder = build.deletingLastPathComponent()

        func inspect(_ override: AgentToolingInstallation.Rehearsal.Override) -> AgentToolingInstallation {
            place.inspect(build, adHoc: true, rehearsal: .init(override: override, applicationsFolder: place.rehearsalApplications))
        }

        #expect(inspect(.diskImage).location == .diskImage(volumeName: "Agent Tooling", volumeURL: folder))
        #expect(inspect(.diskImage).offersMove)
        #expect(inspect(.translocated).location == .translocated(folder))
        #expect(inspect(.elsewhere).location == .elsewhere(folder))
        #expect(inspect(.applications).location == .applications(place.rehearsalApplications))
        #expect(inspect(.applications).registrableHelperPath != nil)
        #expect(inspect(.development).location == .developmentBuild)
        #expect(inspect(.development).mcpHelperURL == nil)
    }

    // MARK: - Signatures

    /// An app signed by its maker is not ad hoc; a bundle signed ad hoc, or
    /// not at all, is.
    @Test func theLiveCheckTellsAnAdHocCopyFromASignedOne() throws {
        let place = try Place()
        defer { place.remove() }
        let unsigned = try place.bundle(in: place.root.appending(path: "unsigned"))
        let adHoc = try place.bundle(in: place.root.appending(path: "adhoc"), executable: true)
        let signing = Process()
        signing.executableURL = URL(filePath: "/usr/bin/codesign")
        signing.arguments = ["--sign", "-", "--force", "--deep", adHoc.path(percentEncoded: false)]
        signing.standardError = FileHandle.nullDevice
        try signing.run()
        signing.waitUntilExit()
        try #require(signing.terminationStatus == 0)

        #expect(AgentToolingInstallation.liveAdHocCheck(unsigned))
        #expect(AgentToolingInstallation.liveAdHocCheck(adHoc))
        #expect(!AgentToolingInstallation.liveAdHocCheck(URL(filePath: "/System/Applications/Calculator.app")))
    }

    @Test func theLiveVolumeFactsNameTheVolumeAFolderIsOn() throws {
        let place = try Place()
        defer { place.remove() }
        let facts = try #require(AgentToolingInstallation.VolumeFacts.live(place.root))
        #expect(!facts.isReadOnly)
        #expect(facts.url != nil)
    }

    // MARK: - A scratch Mac

    /// A scratch folder with a home in it, where bundles are made.
    private struct Place {
        let root: URL
        let home: URL
        let rehearsalApplications: URL

        init() throws {
            root = try TemporaryFolder("agent-tooling-installation").url
            home = root.appending(path: "Users/you", directoryHint: .isDirectory)
            rehearsalApplications = root.appending(path: "QA Apps", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        /// `named` in `folder`, with its two helpers unless `helpers` is
        /// false, and a runnable main executable when `executable`.
        func bundle(
            in folder: URL, named: String = "Agent Tooling.app", helpers: Bool = true, executable: Bool = false
        ) throws -> URL {
            let bundle = folder.appending(path: named, directoryHint: .isDirectory)
            try write(
                bundle.appending(path: "Contents/Info.plist"),
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                <key>CFBundleIdentifier</key><string>com.example.agent-tooling-test</string>
                <key>CFBundleExecutable</key><string>AgentTooling</string>
                <key>CFBundlePackageType</key><string>APPL</string>
                <key>CFBundleShortVersionString</key><string>0.1.0</string>
                </dict></plist>
                """)
            if executable {
                let main = bundle.appending(path: "Contents/MacOS/AgentTooling")
                try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: main)
            }
            if helpers {
                for helper in ["agent-tooling-mcp", "agent-tooling"] {
                    let file = bundle.appending(path: "Contents/Helpers/\(helper)")
                    try write(file, "#!/bin/sh\nexit 0\n")
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
                }
            }
            return bundle
        }

        func inspect(
            _ bundle: URL, adHoc: Bool = false, rehearsal: AgentToolingInstallation.Rehearsal? = nil,
            volume: (URL) -> AgentToolingInstallation.VolumeFacts? = { _ in .init(isReadOnly: false, name: "Macintosh HD") }
        ) -> AgentToolingInstallation {
            AgentToolingInstallation.inspect(
                bundleURL: bundle, homeURL: home, volume: volume, rehearsal: rehearsal, isAdHoc: { _ in adHoc })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
