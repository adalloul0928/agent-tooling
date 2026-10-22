import AgentToolingCore
import AgentToolingTestSupport
import Darwin
import Foundation
import Security
import Testing

@testable import AgentToolingApp

/// Moving this copy to Applications, rehearsed in scratch folders: what the
/// move plans, the copy it makes (checked, its quarantine flag off, swapped
/// in), the older copy set aside and sent to the Trash, the copy opened with
/// `--after-move`, the disk image ejected once the old process has gone, and
/// every failure leaving things as they were.
@Suite("Move to Applications", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct MoveToApplicationsTests {
    // MARK: - Planning

    @Test func thePlanNamesTheDestinationAndWhatIsAlreadyThere() throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.bundleIdentifier = "dev.agenttooling.app"
        let move = rehearsal.move()

        let empty = move.plan()
        #expect(empty.destination == rehearsal.applications.appending(path: "Agent Tooling.app", directoryHint: .isDirectory))
        #expect(empty.existing == nil)
        #expect(!move.existingIsCurrent(empty))

        for (version, current) in [("0.0.9", false), ("0.1.0", true), ("0.10.0", true)] {
            try? FileManager.default.removeItem(at: empty.destination)
            try HelperBundle.make(in: rehearsal.applications, version: version)
            let plan = move.plan()
            #expect(plan.existing == empty.destination, "\(version)")
            #expect(plan.existingVersion == version)
            #expect(move.existingIsCurrent(plan) == current, "\(version)")
        }
    }

    // MARK: - The move

    /// The rehearsal: the copy lands in the scratch Applications folder,
    /// checked and without the quarantine flag macOS put on the download, no
    /// hidden partial is left, the new copy is opened told about this process
    /// and the disk image, and this one quits.
    @Test func aMoveCopiesChecksClearsTheQuarantineFlagAndReopens() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        try rehearsal.quarantineSource()

        let outcome = await rehearsal.move().move(replacingExisting: false)

        #expect(outcome == .relaunching)
        let destination = rehearsal.applications.appending(path: "Agent Tooling.app", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Helpers/agent-tooling-mcp").path))
        #expect(try Rehearsal.quarantined(in: destination).isEmpty)
        #expect(try !Rehearsal.quarantined(in: rehearsal.source).isEmpty, "the copy it moved from is left as it was")
        #expect(try rehearsal.hiddenLeftovers().isEmpty)
        #expect(rehearsal.recorder.opened.map(\.app) == [destination])
        #expect(
            rehearsal.recorder.opened.first?.arguments == [
                "--after-move", "4242", rehearsal.volume.path(percentEncoded: false), "--workspace", "/tmp/qa/ws",
            ])
        #expect(rehearsal.recorder.terminated == 1)
    }

    @Test func anOlderCopyIsReplacedOnlyOnceTheReplaceIsConfirmed() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        try HelperBundle.make(in: rehearsal.applications, version: "0.0.9")
        let move = rehearsal.move()

        #expect(await move.move(replacingExisting: false) == .needsReplaceConfirmation(existingVersion: "0.0.9"))
        #expect(rehearsal.recorder.opened.isEmpty)
        #expect(MoveToApplications.shortVersion(of: move.plan().destination) == "0.0.9")

        #expect(await move.move(replacingExisting: true) == .relaunching)
        #expect(MoveToApplications.shortVersion(of: move.plan().destination) == "0.1.0")
        #expect(rehearsal.recorder.trashed.count == 1, "the older copy goes to the Trash")
        #expect(rehearsal.recorder.trashed.map(\.lastPathComponent) == ["Agent Tooling.app"], "and is shown there as what it is")
        #expect(try rehearsal.hiddenLeftovers().isEmpty)
    }

    /// A rehearsal that names no scratch Applications folder of its own
    /// moves nothing and opens nothing, so the real `/Applications` is never
    /// touched from a rehearsal (D41).
    @Test func aRehearsalThatNamesNoApplicationsFolderMovesNothing() async throws {
        let rehearsing = ["app", "--workspace", "/tmp/qa/ws", "--installation-override", "disk-image"]
        #expect(HelperServices.live(arguments: rehearsing).refusesMove)
        #expect(!HelperServices.live(arguments: rehearsing + ["--applications-folder", "/tmp/qa/Apps"]).refusesMove)
        #expect(
            !HelperServices.live(arguments: ["app", "--installation-override", "disk-image"]).refusesMove, "no workspace: no rehearsal")
        #expect(!HelperServices.live(arguments: ["app"]).refusesMove)

        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        var services = rehearsal.services()
        services.refusesMove = true
        let move = MoveToApplications(
            installation: HelperBundle.onDiskImage(rehearsal.source, volume: rehearsal.volume), services: services)
        #expect(await move.move(replacingExisting: false) == .failed(LaunchpadCopy.Helper.Failures.notMoved))
        let existing = try HelperBundle.make(in: rehearsal.applications, version: "0.2.0")
        #expect(await move.open(existing) == .failed(LaunchpadCopy.Helper.Failures.notMoved))

        #expect(try FileManager.default.contentsOfDirectory(atPath: rehearsal.applications.path) == [HelperBundle.name])
        #expect(rehearsal.recorder.opened.isEmpty)
        #expect(rehearsal.recorder.terminated == 0)
    }

    /// A download opened straight from its disk image runs translocated; the
    /// move still names the disk image it came from for the opened copy to
    /// eject, once the read-only volume is seen to hold this app. A copy
    /// translocated from anywhere else has nothing to eject.
    @Test func aCopyTranslocatedFromADiskImageStillEjectsIt() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.volume = .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.volume)
        rehearsal.recorder.bundleIdentifier = "dev.agenttooling.app"
        rehearsal.recorder.image = rehearsal.root.appending(path: "Downloads/Agent-Tooling.dmg")
        var services = rehearsal.services()
        let original = rehearsal.source
        services.translocationSource = { _ in original }
        let translocated = AgentToolingInstallation(
            bundleURL: rehearsal.source, location: .translocated(rehearsal.source.deletingLastPathComponent()),
            mcpHelperURL: rehearsal.source.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil,
            isAdHocSigned: false)
        let move = MoveToApplications(installation: translocated, services: services)

        #expect(move.diskImageVolume?.standardizedFileURL.path == rehearsal.volume.standardizedFileURL.path)
        #expect(await move.move(replacingExisting: false) == .relaunching)
        #expect(
            rehearsal.recorder.opened.first?.arguments.prefix(3)
                == ["--after-move", "4242", rehearsal.volume.path(percentEncoded: false)])
        let model = LaunchpadMoveModel(installation: translocated, homeURL: rehearsal.root, services: services)
        #expect(model.caption.hasPrefix(LaunchpadCopy.Helper.movesFromDiskImage))

        rehearsal.recorder.volume = .init(isReadOnly: false, name: "Data", url: rehearsal.volume)
        #expect(MoveToApplications(installation: translocated, services: services).diskImageVolume == nil)
        services.translocationSource = { _ in nil }
        rehearsal.recorder.volume = .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.volume)
        #expect(MoveToApplications(installation: translocated, services: services).diskImageVolume == nil)
        #expect(
            LaunchpadMoveModel(installation: translocated, homeURL: rehearsal.root, services: services).caption
                == LaunchpadCopy.Helper.movesFromFolder)
    }

    /// While the copy is made, checked and swapped in, the move is finishing
    /// (D31): leaving is not offered, and a quit waits for it. A quit asked
    /// for then stops it at its next safe point: the copy is removed, nothing
    /// is opened, and nothing hidden is left in Applications.
    @Test func aQuitDuringTheMoveWaitsForItAndLeavesNothingBehind() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let gate = SignatureGate()
        var services = rehearsal.services()
        services.verifySignature = { _ in gate.hold() }
        let flow = fixture.flow()
        let model = flow.model(for: .move) {
            LaunchpadMoveModel(
                installation: HelperBundle.onDiskImage(rehearsal.source, volume: rehearsal.volume), homeURL: rehearsal.root,
                services: services)
        }

        model.primary()
        await gate.waitUntilHeld()
        #expect(model.interruption == .finishing(LaunchpadCopy.Helper.moving))
        #expect(flow.interruption == .finishing(LaunchpadCopy.Helper.moving))
        if case .none = LaunchpadMoveScreen.footer(flow).later {} else { Issue.record("leaving is offered while the copy is made") }
        let quit = Task { await flow.finishPendingWork() }
        // The quit runs first, as far as asking the move to stop; then the
        // check the move is held at answers.
        await Task.yield()
        gate.release()
        await quit.value

        #expect(model.phase == .failed(LaunchpadCopy.Helper.Failures.notMoved))
        #expect(model.interruption == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rehearsal.applications.path).isEmpty)
        #expect(rehearsal.recorder.opened.isEmpty)
        #expect(rehearsal.recorder.terminated == 0)
    }

    @Test func theSameOrANewerCopyIsOpenedInsteadOfReplaced() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.bundleIdentifier = "dev.agenttooling.app"
        let existing = try HelperBundle.make(in: rehearsal.applications, version: "0.2.0")
        let move = rehearsal.move()

        #expect(await move.move(replacingExisting: true) == .openExistingInstead(existing))
        #expect(MoveToApplications.shortVersion(of: existing) == "0.2.0")
        #expect(await move.open(existing) == .relaunching)
        #expect(rehearsal.recorder.opened.first?.app == existing)
        #expect(rehearsal.recorder.opened.first?.arguments.prefix(2) == ["--after-move", "4242"])
    }

    /// The copy in Applications that is already open is not started again
    /// beside it, over the same library: nothing opens and nothing quits.
    @Test func aCopyInApplicationsThatIsOpenIsNotStartedAgain() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.bundleIdentifier = "dev.agenttooling.app"
        let existing = try HelperBundle.make(in: rehearsal.applications, version: "0.2.0")
        rehearsal.recorder.running = [existing.standardizedFileURL.path(percentEncoded: false)]
        let move = rehearsal.move()

        #expect(await move.move(replacingExisting: false) == .openExistingInstead(existing))
        #expect(await move.open(existing) == .failed(LaunchpadCopy.Helper.Failures.otherCopyOpen))
        #expect(rehearsal.recorder.opened.isEmpty)
        #expect(rehearsal.recorder.terminated == 0)
    }

    /// An app under the same name that is not Agent Tooling, however new its
    /// version, is never opened as if it were: it is a copy to replace, and
    /// the person is asked first.
    @Test func anotherAppUnderTheSameNameIsNeverOpenedAsThisOne() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.bundleIdentifier = "com.example.not-agent-tooling"
        try HelperBundle.make(in: rehearsal.applications, version: "9.0.0")
        let move = rehearsal.move()

        #expect(!move.existingIsCurrent(move.plan()))
        #expect(await move.move(replacingExisting: false) == .needsReplaceConfirmation(existingVersion: "9.0.0"))
        #expect(rehearsal.recorder.opened.isEmpty)
    }

    @Test func aCopyThatIsOpenIsNeverReplaced() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let existing = try HelperBundle.make(in: rehearsal.applications, version: "0.0.9")
        rehearsal.recorder.running = [existing.standardizedFileURL.path(percentEncoded: false)]

        let outcome = await rehearsal.move().move(replacingExisting: true)

        #expect(outcome == .failed(LaunchpadCopy.Helper.Failures.otherCopyOpen))
        #expect(MoveToApplications.shortVersion(of: existing) == "0.0.9")
        #expect(try rehearsal.hiddenLeftovers().isEmpty)
        #expect(rehearsal.recorder.opened.isEmpty)
    }

    @Test func aCopyWhoseSignatureFailsIsRemovedAndNothingMoves() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.signatureHolds = false

        let outcome = await rehearsal.move().move(replacingExisting: false)

        #expect(outcome == .failed(LaunchpadCopy.Helper.Failures.notMoved))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rehearsal.applications.path).isEmpty)
        #expect(rehearsal.recorder.opened.isEmpty)
        #expect(rehearsal.recorder.terminated == 0)
    }

    @Test func aFolderItCannotWriteToMovesNothing() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rehearsal.applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rehearsal.applications.path) }

        let outcome = await rehearsal.move().move(replacingExisting: false)

        #expect(outcome == .failed(LaunchpadCopy.Helper.Failures.notMoved))
        #expect(rehearsal.recorder.opened.isEmpty)
    }

    /// The copy is in place, but it could not be opened: the person is told
    /// to open it themselves, and this copy keeps running.
    @Test func aCopyThatCannotBeOpenedSaysWhereItIs() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        rehearsal.recorder.openFails = true

        let outcome = await rehearsal.move().move(replacingExisting: false)

        #expect(outcome == .failed(LaunchpadCopy.Helper.openFromApplications))
        #expect(FileManager.default.fileExists(atPath: rehearsal.applications.appending(path: "Agent Tooling.app").path))
        #expect(rehearsal.recorder.terminated == 0)
    }

    @Test func theQuarantineFlagIsTakenOffEveryFileAndFolder() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        try rehearsal.quarantineSource()
        #expect(try Rehearsal.quarantined(in: rehearsal.source).count >= 4)

        try await MoveToApplications.removeQuarantine(in: rehearsal.source)

        #expect(try Rehearsal.quarantined(in: rehearsal.source).isEmpty)
    }

    // MARK: - After the move

    @Test func theCopyAMoveOpenedEjectsTheDiskImageOnceTheOldOneHasQuit() async throws {
        let rehearsal = try Rehearsal(aliveFor: 3)
        defer { rehearsal.remove() }
        rehearsal.recorder.volume = .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.volume)
        rehearsal.recorder.bundleIdentifier = "dev.agenttooling.app"
        rehearsal.recorder.image = rehearsal.root.appending(path: "Downloads/Agent-Tooling.dmg")
        let afterMove = MoveToApplications.AfterMove(previousProcess: 4242, volume: rehearsal.volume)

        await MoveToApplications.finishAfterMove(afterMove, services: rehearsal.services(afterMove: afterMove))

        #expect(rehearsal.recorder.ejected == [rehearsal.volume])
    }

    /// Only a read-only disk image, mounted where the move said, holding this
    /// app, is ever ejected, and only once the old copy has quit: never a
    /// read-only disk that is no disk image (a locked card, a read-only
    /// stick), whose eject would take every partition on it.
    @Test func nothingElseIsEverEjected() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let afterMove = MoveToApplications.AfterMove(previousProcess: 4242, volume: rehearsal.volume)
        let image = rehearsal.root.appending(path: "Downloads/Agent-Tooling.dmg")
        let cases: [(String, AgentToolingInstallation.VolumeFacts?, String?, Int, URL?)] = [
            ("writable", .init(isReadOnly: false, name: "Data", url: rehearsal.volume), "dev.agenttooling.app", 0, image),
            (
                "not the mount", .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.root), "dev.agenttooling.app", 0,
                image
            ),
            ("another app", .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.volume), "com.example.other", 0, image),
            ("no answer", nil, "dev.agenttooling.app", 0, image),
            (
                "still running", .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.volume), "dev.agenttooling.app",
                1_000, image
            ),
            (
                "a read-only disk that is no disk image", .init(isReadOnly: true, name: "Agent Tooling", url: rehearsal.volume),
                "dev.agenttooling.app", 0, nil
            ),
        ]
        for (name, facts, identifier, alive, imageFile) in cases {
            let recorder = HelperRecorder(trashFolder: rehearsal.root.appending(path: "Trash"), aliveFor: alive)
            recorder.volume = facts
            recorder.bundleIdentifier = identifier
            recorder.image = imageFile
            await MoveToApplications.finishAfterMove(
                afterMove, services: recorder.services(applications: rehearsal.applications, afterMove: afterMove))
            #expect(recorder.ejected.isEmpty, "\(name)")
        }
        await MoveToApplications.finishAfterMove(nil, services: rehearsal.services())
        #expect(rehearsal.recorder.ejected.isEmpty)
    }

    @Test func theAfterMoveArgumentsReadAsTheMoveWroteThem() {
        let written = MoveToApplications.AfterMove(previousProcess: 4242, volume: URL(filePath: "/Volumes/Agent Tooling"))
        let read = MoveToApplications.AfterMove.parse(["/Applications/Agent Tooling.app/Contents/MacOS/AgentTooling"] + written.arguments)
        #expect(read?.previousProcess == 4242)
        #expect(read?.volume?.path == "/Volumes/Agent Tooling")

        #expect(MoveToApplications.AfterMove.parse(["app", "--after-move", "4242", ""])?.volume == nil)
        #expect(MoveToApplications.AfterMove.parse(["app", "--after-move", "nobody"]) == nil)
        #expect(MoveToApplications.AfterMove.parse(["app", "--after-move", "0"]) == nil, "no process could be the one that moved it")
        #expect(MoveToApplications.AfterMove.parse(["app", "--workspace", "/tmp/qa"]) == nil)
    }

    /// The launch reads its arguments once, as `LaunchContext`: the move's
    /// destination, its refusal and what `--after-move` said all come from
    /// that one reading, and the installation's own reading of a rehearsal
    /// agrees with it.
    @Test func theMoveReadsTheLaunchAsTheLaunchReadsItself() {
        let launches: [[String]] = [
            ["app", "--workspace", "/tmp/qa/ws", "--installation-override", "disk-image", "--applications-folder", "/tmp/qa/Apps"],
            ["app", "--workspace", "/tmp/qa/ws", "--installation-override", "translocated"],
            ["app", "--workspace", "/tmp/qa/ws", "--applications-folder", "/tmp/qa/Apps"],
            ["app", "--installation-override", "disk-image", "--applications-folder", "/tmp/qa/Apps"],
            ["app", "--after-move", "4242", "/Volumes/Agent Tooling", "--workspace", "/tmp/qa/ws"],
            ["app", "--workspace", "/tmp/qa/ws"],
            ["app"],
        ]
        for arguments in launches {
            let launch = LaunchContext(arguments: arguments)
            let services = HelperServices.live(arguments: arguments)
            let rehearsal = AgentToolingInstallation.Rehearsal.parse(arguments)
            #expect(services.applicationsFolder.path == (launch.applicationsFolder?.path ?? "/Applications"), "\(arguments)")
            #expect(services.afterMove == MoveToApplications.AfterMove(launch.afterMove), "\(arguments)")
            #expect(services.refusesMove == (launch.installationOverride != nil && launch.applicationsFolder == nil), "\(arguments)")
            #expect(rehearsal?.override?.rawValue == launch.installationOverride?.rawValue, "\(arguments)")
            #expect(rehearsal?.applicationsFolder?.path == launch.applicationsFolder?.path, "\(arguments)")
        }
    }

    /// A moved copy keeps this launch's scratch folders and rehearsal folder,
    /// and never its override, which would offer the move again.
    @Test func theMovedCopyKeepsTheLaunchsScratchFoldersAndNotItsOverride() {
        let forwarded = HelperServices.forwarded([
            "/tmp/qa/Agent Tooling.app/Contents/MacOS/AgentTooling", "--workspace", "/tmp/qa/ws", "--home", "/tmp/qa/home",
            "--installation-override", "disk-image", "--applications-folder", "/tmp/qa/Apps", "--defaults-suite", "qa-1",
            "-ApplePersistenceIgnoreState", "YES",
        ])
        #expect(
            forwarded == [
                "--workspace", "/tmp/qa/ws", "--home", "/tmp/qa/home", "--applications-folder", "/tmp/qa/Apps",
                "--defaults-suite", "qa-1", "-ApplePersistenceIgnoreState", "YES",
            ])
    }

    /// The live check passes a copy signed ad hoc, as a local build is, and
    /// fails it once a file inside has changed since.
    @Test func theLiveSignatureCheckHoldsACopyToItsSignature() throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let bundle = try HelperBundle.make(in: rehearsal.root.appending(path: "signed"), executable: true)
        try Rehearsal.signAdHoc(bundle)
        #expect(HelperServices.liveSignatureCheck(bundle))

        try write(bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), "#!/bin/sh\nexit 1\n")
        #expect(!HelperServices.liveSignatureCheck(bundle))
    }

    /// The live check holds the copy to the signature of the copy it was
    /// made from: a copy of it passes; another app, however validly signed,
    /// does not.
    @Test func theLiveCheckHoldsACopyToTheSignatureItWasMadeFrom() throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let original = try HelperBundle.make(in: rehearsal.root.appending(path: "original"), executable: true)
        try Rehearsal.signAdHoc(original)
        let other = try HelperBundle.make(in: rehearsal.root.appending(path: "other"), version: "9.9.9", executable: true)
        try Rehearsal.signAdHoc(other)
        let copy = rehearsal.root.appending(path: "copy/\(HelperBundle.name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copy)
        var code: SecStaticCode?
        var designated: SecRequirement?
        try #require(SecStaticCodeCreateWithPath(original as CFURL, [], &code) == errSecSuccess)
        try #require(SecCodeCopyDesignatedRequirement(try #require(code), [], &designated) == errSecSuccess)
        let requirement = try #require(designated)

        #expect(HelperServices.liveSignatureCheck(copy, requirement: requirement))
        #expect(!HelperServices.liveSignatureCheck(other, requirement: requirement))
        #expect(HelperServices.liveSignatureCheck(other), "validly signed, all the same")
    }

    // MARK: - Before you start after a move (D42)

    /// A copy the move opened that macOS still runs from a temporary place
    /// says so, and offers to quit rather than a second move.
    @Test func aCopyStillTranslocatedAfterTheMoveOffersToQuitNotToMoveAgain() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let bundle = URL(filePath: "/private/var/folders/xy/T/AppTranslocation/0B1C/d/Agent Tooling.app", directoryHint: .isDirectory)
        let installation = AgentToolingInstallation(
            bundleURL: bundle, location: .translocated(bundle.deletingLastPathComponent()),
            mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil, isAdHocSigned: false)
        let afterMove = MoveToApplications.AfterMove(previousProcess: 4242, volume: nil)
        let model = LaunchpadMoveModel(
            installation: installation, homeURL: rehearsal.root, services: rehearsal.services(afterMove: afterMove))

        #expect(model.isStillOutsideApplications)
        #expect(model.primaryTitle == LaunchpadCopy.Helper.quit)
        #expect(model.caption == LaunchpadCopy.Helper.stillTranslocated)
        model.primary()
        #expect(rehearsal.recorder.terminated == 1)
        #expect(rehearsal.recorder.opened.isEmpty)
    }

    /// Before you start's primary moves once: the copy is made, the new one
    /// opened and this one asked to quit, and the primary stays busy so a
    /// second press moves nothing. A move that fails says so in the banner,
    /// and the primary is free again.
    @Test func beforeYouStartsPrimaryMovesOnceAndAFailureSaysSo() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        // The quit is the move's last act: the test waits for it to be asked.
        let (quits, quit) = AsyncStream.makeStream(of: Void.self)
        var services = rehearsal.services()
        let recorded = services.terminate
        services.terminate = {
            recorded()
            quit.yield()
        }
        let model = LaunchpadMoveModel(
            installation: HelperBundle.onDiskImage(rehearsal.source, volume: rehearsal.volume), homeURL: rehearsal.root,
            services: services)
        #expect(model.primaryTitle == LaunchpadCopy.Helper.moveAndReopen)

        model.primary()
        for await _ in quits { break }
        model.primary()

        #expect(model.phase == .moving)
        #expect(model.interruption == .idle, "once the moved copy opens, the quit it asks for is not held up")
        #expect(rehearsal.recorder.opened.count == 1)

        let failing = try Rehearsal()
        defer { failing.remove() }
        failing.recorder.signatureHolds = false
        let refused = LaunchpadMoveModel(
            installation: HelperBundle.onDiskImage(failing.source, volume: failing.volume), homeURL: failing.root,
            services: failing.services())
        refused.primary()
        await waitUntil { refused.phase != .moving }

        #expect(refused.phase == .failed(LaunchpadCopy.Helper.Failures.notMoved))
        refused.revealDestination()
        #expect(failing.recorder.revealed == [failing.applications])
    }

    // MARK: - Starting the moved copy

    /// A rehearsal's copy is started from its own executable with exactly
    /// the arguments the move gave it, an empty one and one with a space
    /// included, so its scratch folders reach it for certain. A copy opened
    /// without a scratch workspace or home goes through LaunchServices.
    @Test func aRehearsalsCopyStartsWithExactlyItsArguments() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let record = rehearsal.root.appending(path: "started with")
        let app = try HelperBundle.make(in: rehearsal.root.appending(path: "moved"), recordingArgumentsTo: record)
        let afterMove = MoveToApplications.AfterMove(previousProcess: 4242, volume: nil).arguments
        let arguments = afterMove + ["--workspace", "/tmp/qa/ws", "--home", "/tmp/qa/a home"]
        #expect(!HelperServices.startsDirectly(afterMove))
        #expect(!HelperServices.startsDirectly(afterMove + ["--defaults-suite", "qa"]))
        #expect(HelperServices.startsDirectly(afterMove + ["--home", "/tmp/qa/home"]))
        try #require(HelperServices.startsDirectly(arguments))

        try await HelperServices.live(arguments: []).open(app, arguments)

        #expect(try await Rehearsal.lines(of: record) == arguments)
        let noExecutable = try HelperBundle.make(in: rehearsal.root.appending(path: "empty"))
        await #expect(throws: (any Error).self) { try await HelperServices.live(arguments: []).open(noExecutable, arguments) }
    }

    // MARK: - A real disk image

    /// Opt-in real-DMG rehearsal: mounts an ad-hoc signed download, copies it into
    /// scratch Applications, verifies signing and quarantine removal, launches it with
    /// `--after-move`, waits for the old process and ejects the volume. Only quit is
    /// stubbed. Set `AGENT_TOOLING_DISK_IMAGE_REHEARSAL=1` to run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_TOOLING_DISK_IMAGE_REHEARSAL"] != nil))
    func aRealDiskImageIsMovedRelaunchedAndEjected() async throws {
        let rehearsal = try Rehearsal()
        defer { rehearsal.remove() }
        let record = rehearsal.root.appending(path: "relaunched with")
        let image = try DiskImage(
            containing: rehearsal.root.appending(path: "image source"), name: "WP6 Rehearsal", recordingArgumentsTo: record)
        defer { image.detach() }
        let bundle = image.volume.appending(path: HelperBundle.name, directoryHint: .isDirectory)

        let installation = AgentToolingInstallation.inspect(
            bundleURL: bundle, homeURL: rehearsal.root, rehearsal: nil)
        #expect(installation.location == .diskImage(volumeName: image.name, volumeURL: image.volume))
        #expect(installation.offersMove, "an ad-hoc disk image still moves")
        #expect(try !Rehearsal.quarantined(in: bundle).isEmpty, "the mounted copy reads as a download")

        // The copy that moves is a real process, which ends a moment later.
        let previous = Process()
        previous.executableURL = URL(filePath: "/bin/sleep")
        previous.arguments = ["1"]
        try previous.run()
        var services = rehearsal.services(processID: previous.processIdentifier)
        services.verifySignature = { HelperServices.liveSignatureCheck($0) }
        services.open = HelperServices.live(arguments: []).open
        #expect(services.forwardedArguments == ["--workspace", "/tmp/qa/ws"])
        let outcome = await MoveToApplications(installation: installation, services: services).move(replacingExisting: false)

        #expect(outcome == .relaunching)
        #expect(rehearsal.recorder.terminated == 1)
        let moved = rehearsal.applications.appending(path: HelperBundle.name, directoryHint: .isDirectory)
        #expect(HelperServices.liveSignatureCheck(moved))
        #expect(try Rehearsal.quarantined(in: moved).isEmpty)
        let relaunchedWith = try await Rehearsal.lines(of: record)
        #expect(Array(relaunchedWith.suffix(2)) == ["--workspace", "/tmp/qa/ws"])

        // The moved copy, as it launches with what it was started with.
        var live = HelperServices.live(arguments: [moved.path(percentEncoded: false)] + relaunchedWith)
        let afterMove = try #require(live.afterMove)
        #expect(afterMove.previousProcess == previous.processIdentifier)
        #expect(afterMove.volume?.standardizedFileURL.path == image.volume.standardizedFileURL.path)
        live.ownBundleIdentifier = "dev.agenttooling.app"
        await MoveToApplications.finishAfterMove(live.afterMove, services: live)

        #expect(!previous.isRunning)
        #expect(!FileManager.default.fileExists(atPath: image.volume.path), "the disk image was ejected")
    }

    // MARK: - A scratch Mac

    /// Holds the signature check until the test lets it answer, so a test can
    /// act while the move is under way.
    private final class SignatureGate: @unchecked Sendable {
        private let held = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        /// Called by the check: says it is held, then waits to be let go.
        func hold() -> Bool {
            held.signal()
            released.wait()
            return true
        }

        func waitUntilHeld() async {
            let held = held
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    held.wait()
                    continuation.resume()
                }
            }
        }

        func release() { released.signal() }
    }

    /// A disk image's worth of Agent Tooling, a scratch Applications folder
    /// and the recorder the move acts through.
    private struct Rehearsal {
        let root: URL
        let volume: URL
        let source: URL
        let applications: URL
        let recorder: HelperRecorder

        init(aliveFor: Int = 0) throws {
            root = try TemporaryFolder("move-to-applications").url
            volume = root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
            source = try HelperBundle.make(in: volume)
            applications = root.appending(path: "Applications", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            recorder = HelperRecorder(trashFolder: root.appending(path: "Trash"), aliveFor: aliveFor)
        }

        func services(afterMove: MoveToApplications.AfterMove? = nil, processID: Int32 = 4242) -> HelperServices {
            recorder.services(applications: applications, afterMove: afterMove, processID: processID)
        }

        /// What a started copy wrote down, one argument a line, once it has.
        static func lines(of record: URL) async throws -> [String] {
            for _ in 0..<100 {
                if let text = try? String(contentsOf: record, encoding: .utf8) {
                    return Array(text.components(separatedBy: "\n").dropLast())
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CocoaError(.fileReadNoSuchFile)
        }

        @MainActor
        func move() -> MoveToApplications {
            MoveToApplications(installation: HelperBundle.onDiskImage(source, volume: volume), services: services())
        }

        /// Flags every file and folder in the source as a download.
        func quarantineSource() throws {
            try Self.quarantine(source)
        }

        /// Flags every file and folder in `bundle` as a download.
        static func quarantine(_ bundle: URL) throws {
            let value = "0083;00000000;Safari;"
            var paths = [bundle.path(percentEncoded: false)]
            for case let url as URL in FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) ?? .init() {
                paths.append(url.path(percentEncoded: false))
            }
            for path in paths {
                guard setxattr(path, MoveToApplications.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }

        /// The files and folders under `bundle` flagged as a download.
        static func quarantined(in bundle: URL) throws -> [String] {
            var paths = [bundle.path(percentEncoded: false)]
            for case let url as URL in FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) ?? .init() {
                paths.append(url.path(percentEncoded: false))
            }
            return paths.filter { getxattr($0, MoveToApplications.quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        }

        /// A partial copy or a copy set aside, left in Applications.
        func hiddenLeftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: applications.path).filter { $0.hasPrefix(".") }
        }

        static func signAdHoc(_ bundle: URL) throws {
            let signing = Process()
            signing.executableURL = URL(filePath: "/usr/bin/codesign")
            signing.arguments = ["--sign", "-", "--force", "--deep", bundle.path(percentEncoded: false)]
            signing.standardError = FileHandle.nullDevice
            try signing.run()
            signing.waitUntilExit()
            try #require(signing.terminationStatus == 0)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A read-only disk image holding an ad-hoc signed copy of the app,
    /// flagged as downloaded and mounted, for the real rehearsal. The copy's
    /// executable writes down what it was started with to `record`.
    private struct DiskImage {
        let name: String
        let volume: URL

        init(containing source: URL, name: String, recordingArgumentsTo record: URL) throws {
            let unique = "\(name) \(UUID().uuidString.prefix(8))"
            let bundle = try HelperBundle.make(in: source, recordingArgumentsTo: record)
            try Rehearsal.signAdHoc(bundle)
            // Flagged before the image is made, so the copy on the volume
            // carries the flag a download's does.
            try Rehearsal.quarantine(bundle)
            let file = source.deletingLastPathComponent().appending(path: "\(unique).dmg")
            try Self.run(
                "/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-volname", unique, "-format", "UDZO", file.path])
            let flag = "0083;00000000;Safari;"
            guard setxattr(file.path, MoveToApplications.quarantineAttribute, flag, flag.utf8.count, 0, 0) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Self.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", file.path])
            self.name = unique
            volume = URL(filePath: "/Volumes/\(unique)", directoryHint: .isDirectory)
        }

        /// Leaves nothing mounted, whatever the test did.
        func detach() {
            guard FileManager.default.fileExists(atPath: volume.path) else { return }
            try? Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", volume.path])
        }

        private static func run(_ tool: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }
    }
}
