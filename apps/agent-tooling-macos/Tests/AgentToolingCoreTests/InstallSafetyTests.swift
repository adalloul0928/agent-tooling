import Foundation
import Testing

@testable import AgentToolingCore

private struct SilentRunner: CommandRunning {
    func run(executable _: String, arguments _: [String], currentDirectory _: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: "", standardError: "")
    }
}

@Suite("Install safety")
struct InstallSafetyTests {
    // MARK: - Removal guard

    @Test func aRemovalIsListedInThePlanBeforeApproval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed", "reference.md": "notes"])
        try fixture.writeDestination([
            "SKILL.md": "older", "dropped-a.md": "gone", "dropped-b.md": "gone", "legacy/dropped-c.md": "gone",
        ])
        let reviewer = OperationPlanSafetyReviewer(
            authority: ManagedInstallAuthority(ledger: fixture.ledgerProvingDestination()),
            managedRoots: OperationPlanSafetyReviewer.managedRoots(for: fixture.store)
        )

        let review = reviewer.review(try fixture.plan())
        let step = try #require(review.steps.first)
        let replacement = try #require(step.replacement)

        #expect(!step.isBlocked)
        #expect(replacement.removalHeadline == "This update removes 3 files and 1 folder.")
        #expect(replacement.removedPaths == ["dropped-a.md", "dropped-b.md", "legacy/", "legacy/dropped-c.md"])
        #expect(replacement.addedPaths == ["reference.md"])
        #expect(review.headline?.contains("4 existing items removed") == true)
        // The review only reads. Nothing has been deleted yet.
        #expect(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "dropped-a.md").path(percentEncoded: false)))
    }

    @Test func anUpdateThatRemovesNothingSaysNothingAboutRemovals() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed", "reference.md": "notes"])
        try fixture.writeDestination(["SKILL.md": "older"])
        let reviewer = OperationPlanSafetyReviewer(
            authority: ManagedInstallAuthority(ledger: fixture.ledgerProvingDestination()),
            managedRoots: OperationPlanSafetyReviewer.managedRoots(for: fixture.store)
        )

        let review = reviewer.review(try fixture.plan())

        #expect(review.steps.first?.replacement?.removalHeadline == nil)
        #expect(review.headline == nil)
    }

    // MARK: - Ownership guard

    @Test func anUnprovableDestinationIsBlockedInReviewAndRefusedByTheEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        try fixture.writeDestination(["SKILL.md": "hand written by the user"])
        let reviewer = OperationPlanSafetyReviewer(
            authority: .fromStore(fixture.store),
            managedRoots: OperationPlanSafetyReviewer.managedRoots(for: fixture.store)
        )
        let plan = try fixture.plan()

        let review = reviewer.review(plan)
        let step = try #require(review.steps.first)

        #expect(step.isBlocked)
        #expect(step.blockReason?.contains("no record of installing them") == true)
        #expect(review.hasBlockedSteps)

        let receipt = await fixture.engine().execute(plan)

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("cannot prove it installed") == true)
        #expect(try fixture.destinationContents("SKILL.md") == "hand written by the user")
    }

    @Test func anEmptyOrAbsentDestinationNeedsNoPriorRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        let authority = ManagedInstallAuthority()
        let roots = OperationPlanSafetyReviewer.managedRoots(for: fixture.store)

        let absent = DestinationOwnershipInspector.ownership(of: fixture.destination, managedRoots: roots, authority: authority)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let empty = DestinationOwnershipInspector.ownership(of: fixture.destination, managedRoots: roots, authority: authority)

        #expect(absent == .absent)
        #expect(empty == .empty)
        #expect(absent.isProven && empty.isProven)
    }

    @Test func aPriorInstallRecordedByAPlanAndReceiptProvesOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        try fixture.writeDestination(["SKILL.md": "installed earlier by this app"])
        let priorPlan = try fixture.plan()
        let priorStep = try #require(priorPlan.steps.first)
        try fixture.store.saveEntity(priorPlan, id: priorPlan.id.uuidString.lowercased(), domain: .plans)
        let priorReceipt = OperationReceipt(
            planID: priorPlan.id,
            kind: .installSkill,
            title: "Earlier install",
            state: .healthy,
            targetSurfaces: [],
            results: [
                OperationStepResult(stepID: priorStep.id, status: .succeeded, output: "Installed", startedAt: .now, finishedAt: .now)
            ],
            verificationSummary: "Installed"
        )
        try fixture.store.saveEntity(priorReceipt, id: priorReceipt.id.uuidString, domain: .receipts)
        let plan = try fixture.plan()

        let review = OperationPlanSafetyReviewer(
            authority: .fromStore(fixture.store),
            managedRoots: OperationPlanSafetyReviewer.managedRoots(for: fixture.store)
        ).review(plan)
        let receipt = await fixture.engine().execute(plan)

        #expect(review.steps.first?.isBlocked == false)
        #expect(review.steps.first?.ownership.summary.contains("stored receipt") == true)
        #expect(receipt.results.first?.status == .succeeded)
        #expect(try fixture.destinationContents("SKILL.md") == "reviewed")
    }

    @Test func aReceiptWithoutASuccessfulStepProvesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        try fixture.writeDestination(["SKILL.md": "not ours"])
        let priorPlan = try fixture.plan()
        let priorStep = try #require(priorPlan.steps.first)
        try fixture.store.saveEntity(priorPlan, id: priorPlan.id.uuidString.lowercased(), domain: .plans)
        let failed = OperationReceipt(
            planID: priorPlan.id,
            kind: .installSkill,
            title: "Failed install",
            state: .attention,
            targetSurfaces: [],
            results: [
                OperationStepResult(stepID: priorStep.id, status: .failed, output: "Refused", startedAt: .now, finishedAt: .now)
            ],
            verificationSummary: "Failed"
        )
        try fixture.store.saveEntity(failed, id: failed.id.uuidString, domain: .receipts)

        let review = OperationPlanSafetyReviewer(
            authority: .fromStore(fixture.store),
            managedRoots: OperationPlanSafetyReviewer.managedRoots(for: fixture.store)
        ).review(try fixture.plan())

        #expect(review.steps.first?.isBlocked == true)
    }

    /// A receipt proves the step in *its own* plan succeeded. Step identifiers
    /// are decoded from plan files, so a second plan can reuse one; if that
    /// were enough to claim ownership, an unreviewed folder could be dressed up
    /// as something this app installed and then replaced without a warning.
    @Test func aReceiptFromOnePlanDoesNotProveAStepInAnother() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        try fixture.writeDestination(["SKILL.md": "hand-written, never installed by this app"])

        let sharedStepID = UUID()
        let scratch = fixture.home.appending(path: ".claude/skills/scratch", directoryHint: .isDirectory)
        var provenStep = try fixture.copyStep(title: "Install example at scratch", destination: scratch)
        provenStep.id = sharedStepID
        let provenPlan = OperationPlan(
            kind: .installSkill, title: "Install example", summary: "Install the reviewed package.", steps: [provenStep])
        try fixture.store.saveEntity(provenPlan, id: provenPlan.id.uuidString, domain: .plans)
        let receipt = OperationReceipt(
            planID: provenPlan.id,
            kind: .installSkill,
            title: "Install example",
            state: .healthy,
            targetSurfaces: [],
            results: [
                OperationStepResult(stepID: sharedStepID, status: .succeeded, output: "Installed", startedAt: .now, finishedAt: .now)
            ],
            verificationSummary: "Installed"
        )
        try fixture.store.saveEntity(receipt, id: receipt.id.uuidString, domain: .receipts)

        var borrowedStep = try fixture.copyStep(title: "Replace a hand-written skill", destination: fixture.destination)
        borrowedStep.id = sharedStepID
        let forgedPlan = OperationPlan(
            kind: .installSkill, title: "Replace example", summary: "Replace the package.", steps: [borrowedStep])
        try fixture.store.saveEntity(forgedPlan, id: forgedPlan.id.uuidString, domain: .plans)

        // `id` is the normalised destination; `destinationPath` is the raw one.
        let proven = ManagedInstallAuthority.fromStore(fixture.store).provenInstalls.map(\.id)

        #expect(proven.contains(ManagedInstallPath.normalized(scratch.path(percentEncoded: false))))
        #expect(proven.contains(ManagedInstallPath.normalized(fixture.destination.path(percentEncoded: false))) == false)
    }

    // MARK: - Drift detection

    @Test func aModifiedInstallIsReportedAsDriftedAndAnUntouchedOneIsNot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        let second = fixture.home.appending(path: ".agents/skills/example", directoryHint: .isDirectory)
        let receipt = await fixture.engine().execute(try fixture.plan(destinations: [fixture.destination, second]))
        #expect(receipt.results.allSatisfy { $0.status == .succeeded })

        let untouched = InstalledPackageDriftInspector.inspect(.fromStore(fixture.store))
        #expect(untouched.count == 2)
        #expect(untouched.allSatisfy { $0.state == .matchesReview })

        try Data("edited in place after the review".utf8).write(
            to: second.appending(path: "SKILL.md", directoryHint: .notDirectory), options: .atomic)

        let reports = InstalledPackageDriftInspector.inspect(.fromStore(fixture.store))
        let drifted = try #require(reports.first { $0.hasDrifted })
        let stable = try #require(reports.first { $0.state == .matchesReview })

        #expect(reports.count == 2)
        #expect(drifted.destinationPath == second.path(percentEncoded: false))
        #expect(drifted.headline == "Installed but modified since you reviewed it.")
        #expect(drifted.explanation.contains("is normal"))
        #expect(drifted.currentFingerprint != drifted.reviewedFingerprint)
        #expect(stable.destinationPath == fixture.destination.path(percentEncoded: false))
        #expect(InstalledPackageDriftInspector.summary(for: reports)?.contains("modified since you reviewed") == true)
    }

    @Test func aRemovedInstallIsReportedWithoutBeingCalledAFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        _ = await fixture.engine().execute(try fixture.plan())
        try FileManager.default.removeItem(at: fixture.destination)

        let reports = InstalledPackageDriftInspector.inspect(.fromStore(fixture.store))

        #expect(reports.first?.state == .removed)
        #expect(reports.first?.hasDrifted == false)
    }

    @MainActor
    @Test func theSetupCheckReportsDriftWithoutChangingAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try AppModel(store: fixture.store, runner: SilentRunner(), homeURL: fixture.home)
        var draft = SkillDraft()
        draft.name = "release-readiness"
        draft.purpose = "Verify a release candidate before submission."
        draft.triggers = ["Check release readiness", "", ""]
        draft.negativeTrigger = "Building an unrelated feature"
        draft.runCanary = false
        draft.selectedTargets = [.claude, .codex]
        _ = try #require(model.createSkill(from: draft))

        await model.executePendingPlan()
        #expect(model.installDrift.count == 2)
        #expect(model.installDrift.allSatisfy { $0.state == .matchesReview })

        let edited = fixture.home.appending(path: ".claude/skills/release-readiness/SKILL.md", directoryHint: .notDirectory)
        try Data("edited by hand".utf8).write(to: edited, options: .atomic)
        await model.runDoctor()

        #expect(model.installDrift.count(where: \.hasDrifted) == 1)
        #expect(model.installDrift.first { $0.hasDrifted }?.packageName == "release-readiness")
        #expect(model.activities.first?.detail.contains("modified since you reviewed") == true)
        #expect(try Data(contentsOf: edited) == Data("edited by hand".utf8))
    }

    // MARK: - Itemized batch outcomes

    @Test func batchOutcomesNameEveryItemIncludingSkipsAndTheirReasons() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSource(["SKILL.md": "reviewed"])
        let install = try fixture.copyStep(title: "Install example in Claude Code", destination: fixture.destination)
        let preflight = OperationStep(
            kind: .command,
            title: "Check Codex plugin state",
            detail: "Must fail",
            executable: "codex",
            arguments: ["exec", "not-approved"],
            stopsOnFailure: true
        )
        let neverRuns = try fixture.copyStep(
            title: "Install example in Codex",
            destination: fixture.home.appending(path: ".agents/skills/example", directoryHint: .isDirectory)
        )
        let plan = OperationPlan(
            kind: .installSkill,
            title: "Install example",
            summary: "Three steps",
            steps: [install, preflight, neverRuns]
        )

        let receipt = await fixture.engine().execute(plan)

        #expect(receipt.outcomeTally == "succeeded 1 · failed 1 · skipped 1")
        #expect(
            receipt.itemOutcomes.map(\.title) == ["Install example in Claude Code", "Check Codex plugin state", "Install example in Codex"])
        #expect(receipt.itemOutcomes.map(\.status) == [.succeeded, .failed, .skipped])
        let skipped = try #require(receipt.itemOutcomes.first { $0.status == .skipped })
        #expect(skipped.reason == "Skipped because a required preflight or integrity check failed.")
        #expect(receipt.verificationSummary.hasPrefix("succeeded 1 · failed 1 · skipped 1."))
        #expect(receipt.verificationSummary.contains("Failed: Check Codex plugin state — "))
        #expect(receipt.verificationSummary.contains("Skipped: Install example in Codex — Skipped because a required preflight"))
    }

    @Test func aReceiptStoredBeforeItemizationExistedStillDecodes() throws {
        let legacy = """
            {"createdAt":"2026-01-02T03:04:05Z","id":"8B1F0E2A-0000-4000-8000-000000000001",\
            "kind":"installSkill","planID":"8B1F0E2A-0000-4000-8000-000000000002","results":[],\
            "state":"healthy","targetSurfaces":[],"title":"Older receipt","verificationSummary":"Done"}
            """
        let decoded = try AgentToolingCoding.decoder().decode(OperationReceipt.self, from: Data(legacy.utf8))

        #expect(decoded.itemOutcomes.isEmpty)
        #expect(decoded.outcomeTally == "succeeded 0 · failed 0 · skipped 0")
    }

    // MARK: - Fixture

    /// An installed copy the app cannot read is reported rather than skipped.
    /// A single symlink inside the folder makes the fingerprint unreadable, so
    /// staying quiet would be the cheapest way to hide a modified install.
    @Test func aPackageThatCannotBeReadIsNamedInTheSummary() {
        let summary = InstalledPackageDriftInspector.summary(for: [
            InstalledPackageDrift(
                destinationPath: "/tmp/example/.claude/skills/opaque",
                packageName: "opaque",
                state: .unreadable,
                reviewedFingerprint: "recorded-at-install-time",
                reviewedAt: .now
            )
        ])

        #expect(summary?.contains("could not be read") == true)
        #expect(summary?.contains("opaque") == true)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let home: URL
        let source: URL
        let destination: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "InstallSafetyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
            home = root.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            source = store.libraryURL.appending(path: "packages/example/skills/example", directoryHint: .isDirectory)
            destination = home.appending(path: ".claude/skills/example", directoryHint: .isDirectory)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        func engine() -> OperationEngine {
            OperationEngine(store: store, runner: SilentRunner(), homeURL: home)
        }

        func writeSource(_ files: [String: String]) throws {
            try Self.write(files, into: source)
        }

        func writeDestination(_ files: [String: String]) throws {
            try Self.write(files, into: destination)
        }

        func destinationContents(_ relativePath: String) throws -> String {
            String(decoding: try Data(contentsOf: destination.appending(path: relativePath)), as: UTF8.self)
        }

        func copyStep(title: String, destination target: URL) throws -> OperationStep {
            OperationStep(
                kind: .copyDirectory,
                title: title,
                detail: "Copies the reviewed package.",
                sourcePath: source.path(percentEncoded: false),
                sourceFingerprint: try DirectoryFingerprint.sha256(of: source),
                destinationPath: target.path(percentEncoded: false)
            )
        }

        func plan(destinations: [URL]? = nil) throws -> OperationPlan {
            let targets = destinations ?? [destination]
            return OperationPlan(
                kind: .installSkill,
                title: "Install example",
                summary: "Install the reviewed package.",
                steps: try targets.map { try copyStep(title: "Install example at \($0.lastPathComponent)", destination: $0) }
            )
        }

        /// A ledger that already records this app installing at `destination`,
        /// standing in for a previous approved install.
        func ledgerProvingDestination() -> ManagedInstallLedger {
            ManagedInstallLedger(records: [
                ManagedInstallRecord(
                    destinationPath: destination.path(percentEncoded: false),
                    sourcePath: source.path(percentEncoded: false),
                    reviewedFingerprint: "recorded-at-install-time",
                    reviewedAt: .now
                )
            ])
        }

        private static func write(_ files: [String: String], into root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (relativePath, contents) in files {
                let url = root.appending(path: relativePath, directoryHint: .notDirectory)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
            }
        }
    }
}
