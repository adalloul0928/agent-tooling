import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Your other Macs (S17), Join (J01, V08, Finish joining) and You joined (J02)
/// draw at the stage's size in both appearances, in each state the
/// fragments draw or specify. Drawing a screen runs no command and writes
/// nothing; the arrivals arriving after the stage laid out leave its window
/// as it was.
@Suite("Launchpad macs renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadMacsRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func yourOtherMacsDrawsInEachState(appearance: RenderAppearance) async throws {
        for state in MacsScene.S17.allCases {
            let scene = try await MacsScene.s17(state)
            let launches = scene.launches
            try expectDrawn(scene.view, size: WindowSize.stage, appearance: appearance)
            // Drawing it ran nothing.
            #expect(scene.launches == launches, "\(state) ran a command as it drew")
            await scene.close()
        }
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func joinDrawsInEachState(appearance: RenderAppearance) async throws {
        for state in MacsScene.J01.allCases {
            let scene = try await MacsScene.j01(state)
            try expectDrawn(scene.view, size: WindowSize.stage, appearance: appearance)
            await scene.close()
        }
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func youJoinedDrawsInEachState(appearance: RenderAppearance) async throws {
        for state in MacsScene.J02.allCases {
            let scene = try await MacsScene.j02(state)
            try expectDrawn(scene.view, size: WindowSize.stage, appearance: appearance)
            await scene.close()
        }
    }

    /// Drawing Join on a first run reads nothing and checks nothing: only a
    /// typed address and a pause start the check.
    @Test func drawingJoinRunsNothing() async throws {
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let flow = cedar.fixture.flow()
        flow.choosePath(.join)

        try expectDrawn(cedar.fixture.stage(flow), size: WindowSize.stage)

        #expect(cedar.runner.launches.isEmpty)
        #expect(cedar.fixture.firstReads.started.isEmpty)
        #expect(cedar.fixture.signIn.shellProbes == 0)
        #expect(!cedar.fixture.hasWorkspace)
    }

    /// What arrived lands after the stage has laid out, once the first pass
    /// and the look at what arrived end: the rows take the checking row's
    /// place and the stage's window stays exactly as it was.
    @Test func theArrivalsArrivingLateKeepTheStageInItsWindow() async throws {
        let scene = try await MacsScene.j02(.checking)
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: scene.flow))
        #expect(arrivals.phase == .checking)

        let layout = try await LateContentHarness.heightAfterChange(
            scene.view, windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            await arrivals.load()
        }

        #expect(arrivals.installCount == 5)
        #expect(layout.hostHeight == layout.windowHeight)
        await scene.close()
    }

    /// The result card rising under the warning keeps the stage in its window.
    @Test func theResultCardArrivingLateKeepsTheStageInItsWindow() async throws {
        let scene = try await MacsScene.s17(.typed)
        let model = try #require(LaunchpadMacsScreen.connect(for: scene.flow))

        let layout = try await LateContentHarness.heightAfterChange(
            scene.view, windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            model.connect(flow: scene.flow)
            await waitUntil { model.phase == .connected(.shared) }
        }

        #expect(layout.hostHeight == layout.windowHeight)
        await scene.close()
    }
}

// MARK: - The scenes

/// The states the fragments draw or specify, each a stage at its step over
/// the sample world, ready to draw or capture, and closed when done. The
/// repositories live on this Mac; an address that reads as github.com is
/// rewritten to one of them by the fixture home's Git configuration, and Git
/// may reach nothing else.
@MainActor
struct MacsScene {
    enum S17: String, CaseIterable {
        case empty
        case typed
        case connected
        case refused
        case scp
        case alreadyConnected
        /// The check could not reach the host: Try again ↩.
        case unreachable
    }

    enum J01: String, CaseIterable {
        case ready
        case joining
        case typo
        case finish
    }

    enum J02: String, CaseIterable {
        case ready
        case checking
        case underThePanel
        /// The plan could not be made: nothing listed, and why.
        case notWorkedOut
    }

    /// The address the mockups type, and the one with V08's typo.
    static let address = "https://github.com/you/agent-tooling-workspace.git"
    static let typo = "https://github.com/you/agent-tooling-workspce.git"

    let flow: LaunchpadFlow
    let view: AnyView
    let runner: JoinGitRunner
    private let closing: () async -> Void

    /// The system commands the stage has run so far.
    var launches: [CommandLaunch] { runner.launches }

    func close() async { await closing() }

    // MARK: S17

    static func s17(_ state: S17) async throws -> MacsScene {
        let stage = try await MacsStage.make()
        do {
            try rewrite(address, to: stage.repository.remote, in: stage.fixture.home)
            let model = stage.model
            switch state {
            case .empty:
                break
            case .typed:
                model.update(address: address)
                await model.check.checkNow(model.request)
            case .connected, .alreadyConnected:
                model.update(address: address)
                model.connect(flow: stage.flow)
                await waitUntil { model.phase == .connected(.shared) }
            case .refused:
                stage.runner.refusesPushes = true
                model.update(address: address)
                model.connect(flow: stage.flow)
                await waitUntil { model.failure != nil }
            case .scp:
                model.update(address: "git@github.com:you/agent-tooling-workspace.git")
            case .unreachable:
                stage.runner.cannotReachHost = true
                model.update(address: address)
                await model.check.checkNow(model.request)
            }
            var flow = stage.flow
            if state == .alreadyConnected {
                flow = stage.fixture.flow(.rerun, workspace: stage.workspace)
                flow.go(to: .macs)
                await LaunchpadMacsScreen.connect(for: flow)?.load()
            }
            return MacsScene(
                flow: flow, view: AnyView(stage.fixture.stage(flow)), runner: stage.runner, closing: { stage.remove() })
        } catch {
            stage.remove()
            throw error
        }
    }

    // MARK: J01

    static func j01(_ state: J01) async throws -> MacsScene {
        let juniper = try await JoinPublishedJuniper.make()
        let gate = GatedCommandRunner()
        let cedar: JoinCedar
        do {
            cedar = try await JoinCedar(readGate: state == .joining ? gate : nil)
        } catch {
            juniper.remove()
            throw error
        }
        func remove() {
            gate.release()
            cedar.remove()
            juniper.remove()
        }
        do {
            try rewrite(address, to: juniper.remote, in: cedar.fixture.home)
            try rewrite(
                typo, to: juniper.remote.deletingLastPathComponent().appending(path: "agent-tooling-workspce.git"),
                in: cedar.fixture.home)
            let (flow, model) = await cedar.joinStage()
            switch state {
            case .ready:
                model.update(address: address)
                await model.check.checkNow(model.request)
            case .joining:
                model.update(address: address)
                await model.check.checkNow(model.request)
                model.join(flow: flow)
                await gate.waitUntilCalled()
                await waitUntil { model.reading == [.codex, .claude] }
            case .typo:
                model.update(address: typo)
                await model.check.checkNow(model.request)
            case .finish:
                cedar.runner.refusesPushes = true
                model.update(address: address)
                await model.check.checkNow(model.request)
                model.join(flow: flow)
                await waitUntil { model.phase == .editing && model.mode != .join }
            }
            let view = AnyView(cedar.fixture.stage(flow))
            return MacsScene(
                flow: flow, view: view, runner: cedar.runner,
                closing: {
                    if model.phase == .joining {
                        model.stop()
                        await waitUntil { model.phase != .joining }
                    }
                    remove()
                })
        } catch {
            remove()
            throw error
        }
    }

    // MARK: J02

    /// You joined in `state`; with `sharing`, Juniper shares that many more
    /// skills than its own walk made, so more arrive than the card has room
    /// for.
    static func j02(_ state: J02, sharing extraSkills: Int = 0) async throws -> MacsScene {
        let juniper = try await JoinPublishedJuniper.make(sharing: extraSkills)
        let cedar: JoinCedar
        do {
            cedar = try await JoinCedar()
        } catch {
            juniper.remove()
            throw error
        }
        // Claude Code's folder, which the not-worked-out state makes
        // unreadable while it is drawn.
        let claude = cedar.fixture.home.appending(path: ".claude", directoryHint: .isDirectory).path(percentEncoded: false)
        func remove() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)
            cedar.remove()
            juniper.remove()
        }
        do {
            let (flow, model) = await cedar.joinStage()
            model.update(address: juniper.address)
            await model.check.checkNow(model.request)
            model.join(flow: flow)
            await waitUntil { flow.step == .arrivals }
            let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: flow))
            switch state {
            case .checking:
                break
            case .ready:
                await arrivals.load()
            case .underThePanel:
                await arrivals.load()
                LaunchpadStageView.footer(for: flow).primary?.action()
                await flow.presentedReview?.prepare()
            case .notWorkedOut:
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: claude)
                await arrivals.load()
            }
            return MacsScene(
                flow: flow, view: AnyView(cedar.fixture.stage(flow)), runner: cedar.runner, closing: { remove() })
        } catch {
            remove()
            throw error
        }
    }

    /// Makes `home`'s Git read `address` as the repository at `repository`.
    static func rewrite(_ address: String, to repository: URL, in home: URL) throws {
        let config = home.appending(path: ".gitconfig")
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let entry = "[url \"file://\(repository.path(percentEncoded: false))\"]\n\tinsteadOf = \(address)\n"
        try (existing + entry).write(to: config, atomically: true, encoding: .utf8)
    }
}
