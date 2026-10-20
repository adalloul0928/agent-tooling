import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// WP0c's screens in the gallery, in the stage's own window, named by their
/// mockup ids so each pairs with `a-launchpad/NN-<id>-<mode>.png`: Welcome
/// with the keyboard on each row and with FooterConfirm up, and the
/// unreadable screen in each of its states. (The stage's window root sizes
/// itself for a real title bar, so it is drawn by the render tests, not
/// captured here.)
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad windows", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadWindowTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let welcomeSource = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadWelcomeScreen.swift"

    @Test func welcome() async throws {
        for appearance in Self.both {
            var fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            // The version line reads the copy's bundle; the sample world's is
            // the mockups' 0.1.0.
            fixture.environment.bundleURL = try Self.bundle(in: fixture.support)
            let flow = fixture.flow()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s01-welcome", state: "start here", appearance: appearance,
                source: Self.welcomeSource)
            LaunchpadWelcomeScreen.choice(flow).focus(.join)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s01-welcome", state: "join", appearance: appearance, source: Self.welcomeSource)
            flow.requestClose()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s01-welcome", state: "footer confirm", appearance: appearance,
                source: Self.welcomeSource)
        }
    }

    @Test func unreadable() throws {
        let reasons: [(AppLaunchState.UnreadableReason, String)] = [
            (.newerFormat, "newer"), (.damaged, "damaged"), (.io(WorkspaceLocatorError.unreadable.localizedDescription), "io"),
        ]
        for appearance in Self.both {
            for (reason, state) in reasons {
                try galleryStageSnapshot(
                    LaunchpadUnreadableScreen(reason: reason), screen: "unreadable", state: state, appearance: appearance,
                    source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadUnreadableScreen.swift")
            }
        }
    }

    /// A copy of the app with only the Info.plist the version line reads.
    private static func bundle(in folder: URL) throws -> URL {
        let bundle = folder.appending(path: "Gallery Agent Tooling.app", directoryHint: .isDirectory)
        try write(
            bundle.appending(path: "Contents/Info.plist"),
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1.0</string></dict></plist>
            """)
        return bundle
    }
}
