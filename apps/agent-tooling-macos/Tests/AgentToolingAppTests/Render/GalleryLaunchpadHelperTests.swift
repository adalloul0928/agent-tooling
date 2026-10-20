import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Before you start and Let your apps ask Agent Tooling in the gallery, in
/// both appearances: the states the fragments draw (the disk image; Gemini
/// CLI unticked with the keyboard on it) and the ones they specify (an older
/// copy in Applications, a translocated copy, one in Downloads, the failed
/// move, the copy still translocated after a move; registrations, a copy
/// outside Applications, a development build, Cedar's detour).
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad helper", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadHelperTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let moveSource = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadMoveScreen.swift"
    private static let askSource = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadAskScreen.swift"

    // MARK: - S00

    @Test func beforeYouStart() async throws {
        for appearance in Self.both {
            for state in GalleryMoveState.allCases {
                let stage = try await GalleryMoveStage(state)
                defer { stage.remove() }
                try galleryStageSnapshot(
                    stage.view, screen: "S00 Before you start", state: state.rawValue, appearance: appearance,
                    source: Self.moveSource)
            }
        }
    }

    // MARK: - S11

    @Test func letYourAppsAsk() async throws {
        for appearance in Self.both {
            for state in GalleryAskState.allCases {
                let stage = try await GalleryAskStage(state)
                defer { stage.remove() }
                try galleryStageSnapshot(
                    stage.view, screen: "S11 Let your apps ask", state: state.rawValue, appearance: appearance,
                    source: Self.askSource)
            }
        }
    }
}

// MARK: - Before you start, staged

/// The states Before you start is captured in.
enum GalleryMoveState: String, CaseIterable {
    case diskImage = "disk image"
    case olderCopy = "an older copy in Applications"
    case translocated = "translocated"
    case downloads = "in Downloads"
    case failed = "the move failed"
    case stillTranslocated = "still translocated after the move"
}

/// Before you start on a Mac of the sample world, in one state, with the
/// move's outside world recorded.
@MainActor
struct GalleryMoveStage {
    let fixture: LaunchpadFixture
    let flow: LaunchpadFlow
    let services: HelperServices
    let recorder: HelperRecorder

    /// `pressesPrimary` false leaves a failing move unpressed, for a test to
    /// press once the stage has laid out.
    init(_ state: GalleryMoveState, pressesPrimary: Bool = true) async throws {
        var fixture = try await LaunchpadFixture()
        let home = fixture.home
        let scratch = fixture.world.home.root
        let installation: AgentToolingInstallation
        switch state {
        case .diskImage, .olderCopy, .failed:
            let volume = URL(filePath: "/Volumes/Agent Tooling", directoryHint: .isDirectory)
            installation = HelperBundle.onDiskImage(volume.appending(path: HelperBundle.name, directoryHint: .isDirectory), volume: volume)
        case .translocated, .stillTranslocated:
            let folder = URL(filePath: "/private/var/folders/x8/k1v9f2_n3qb5/T/AppTranslocation/4F1E8C2A/d", directoryHint: .isDirectory)
            installation = Self.copy(in: folder, location: .translocated(folder))
        case .downloads:
            let downloads = home.appending(path: "Downloads", directoryHint: .isDirectory)
            installation = Self.copy(in: downloads, location: .elsewhere(downloads))
        }
        fixture.environment.installation = { installation }
        let recorder = HelperRecorder(trashFolder: scratch.appending(path: "Trash"))
        recorder.image = home.appending(path: "Downloads/Agent-Tooling-0.1.0-arm64.dmg")
        let applications: URL
        let fileManager: FileManager
        switch state {
        case .olderCopy:
            applications = home.appending(path: "Applications", directoryHint: .isDirectory)
            try HelperBundle.make(in: applications, version: "0.0.9")
            fileManager = .default
        case .failed:
            // The fixture's own home, so the copy that fails fails there.
            applications = home.appending(path: "Applications", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            fileManager = .default
        default:
            applications = URL(filePath: "/Applications", directoryHint: .isDirectory)
            fileManager = NothingInApplicationsFileManager()
        }
        let afterMove = state == .stillTranslocated ? MoveToApplications.AfterMove(previousProcess: 4242, volume: nil) : nil
        let services = recorder.services(applications: applications, afterMove: afterMove)
        let flow = fixture.flow()
        let model = flow.model(for: .move) {
            LaunchpadMoveModel(installation: installation, homeURL: home, services: services, fileManager: fileManager)
        }
        if state == .failed {
            // The check fails whatever the copy finds, so the move fails on
            // any Mac, and only ever inside the fixture's own home.
            recorder.signatureHolds = false
            if pressesPrimary {
                model.primary()
                await waitUntil { model.phase != .moving }
            }
        }
        self.fixture = fixture
        self.flow = flow
        self.services = services
        self.recorder = recorder
    }

    var view: some View {
        fixture.stage(flow).environment(\.helperServices, services)
    }

    func remove() { fixture.remove() }

    private static func copy(in folder: URL, location: AgentToolingInstallation.Location) -> AgentToolingInstallation {
        let bundle = folder.appending(path: HelperBundle.name, directoryHint: .isDirectory)
        return AgentToolingInstallation(
            bundleURL: bundle, location: location, mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"),
            cliHelperURL: nil, isAdHocSigned: false)
    }
}

/// A file manager that finds nothing in `/Applications`, so a capture of
/// the move to `/Applications` draws the same on any Mac.
final class NothingInApplicationsFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath path: String) -> Bool {
        path.hasPrefix("/Applications/") ? false : super.fileExists(atPath: path)
    }
}

// MARK: - Let your apps ask, staged

/// The states Let your apps ask is captured in.
enum GalleryAskState: String, CaseIterable {
    case geminiUnticked = "Gemini CLI unticked, the keyboard on it"
    case registrations = "already connected, and another copy"
    /// D10: Claude Code connected by Agent Tooling (a receipt shows it),
    /// unticked on a revisit, showing the removal the review runs.
    case takingItOut = "Claude Code connected by Agent Tooling, unticked"
    case outsideApplications = "kept outside Applications"
    case developmentBuild = "a development build"
    case cedarsDetour = "Cedar, from You joined"
}

/// Let your apps ask on the sample world, in one state.
@MainActor
struct GalleryAskStage {
    let fixture: LaunchpadFixture
    let flow: LaunchpadFlow
    let sample: LaunchpadSample

    init(_ state: GalleryAskState) async throws {
        var fixture = try await LaunchpadFixture(state == .cedarsDetour ? .cedar : .juniper)
        let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)
        switch state {
        case .geminiUnticked, .registrations, .takingItOut, .cedarsDetour:
            fixture.environment.installation = { HelperBundle.inApplications(applications) }
        case .outsideApplications:
            let volume = URL(filePath: "/Volumes/Agent Tooling", directoryHint: .isDirectory)
            fixture.environment.installation = {
                HelperBundle.onDiskImage(volume.appending(path: HelperBundle.name, directoryHint: .isDirectory), volume: volume)
            }
        case .developmentBuild:
            break
        }
        let snapshot: LaunchpadSampleSnapshot =
            switch state {
            case .cedarsDetour: .cedarJoined
            case .takingItOut: .afterAsk
            default: .afterPlace
            }
        let (flow, sample) = try await fixture.flow(at: snapshot)
        if state == .cedarsDetour { flow.go(to: .ask) }
        if state == .takingItOut {
            let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
            try fixture.world.home.plant(
                ".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(helper)","args":[]}}}"#)
            await sample.workspace.device.adopt(
                sample.workspace.device.observations.map { observation in
                    guard observation.surface == .claudeCode else { return observation }
                    var registered = observation
                    registered.discoveredMCPServers.append(AgentToolingConnection.declaredName)
                    registered.mcpMetadata[AgentToolingConnection.declaredName] = .init(
                        transport: "stdio", authentication: "Not inferred", source: "configuration")
                    return registered
                })
            try fixture.recordThatAgentToolingSetUpItsConnection(in: .claudeCode, workspace: sample.workspace)
        }
        if state == .registrations {
            let elsewhere = "/Users/example/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
            let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
            try fixture.world.home.plant(
                ".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(helper)","args":[]}}}"#)
            try fixture.world.home.plant(".gemini/settings.json", #"{"mcpServers":{"agent-tooling":{"command":"\#(elsewhere)"}}}"#)
            await sample.workspace.device.adopt(
                sample.workspace.device.observations.map { observation in
                    guard observation.surface == .claudeCode || observation.surface == .geminiCLI else { return observation }
                    var registered = observation
                    registered.discoveredMCPServers.append(AgentToolingConnection.declaredName)
                    registered.mcpMetadata[AgentToolingConnection.declaredName] = .init(
                        transport: "stdio", authentication: "Not inferred", source: "configuration")
                    return registered
                })
        }
        let model = AgentToolingHookUp.of(flow)
        await model.load(decisions: flow.decisions)
        if state == .geminiUnticked {
            model.toggle(.gemini)
            model.focused = .gemini
        }
        if state == .takingItOut {
            model.toggle(.claude)
            model.focused = .claude
        }
        self.fixture = fixture
        self.flow = flow
        self.sample = sample
    }

    var view: some View { fixture.stage(flow) }

    func remove() {
        sample.remove()
        fixture.remove()
    }
}
