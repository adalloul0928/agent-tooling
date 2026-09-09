import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Onboarding presentation")
@MainActor
struct OnboardingWizardTests {
    @Test func returningToToolsKeepsSelectionsWithoutTryingToCopyCompletedSkillsAgain() {
        let draft = OnboardingSelection(itemIDs: ["skill:copied", "skill:pending"], copySkillIDs: ["copied", "pending"])
        let reviewed = OnboardingDraftPolicy.afterCopyReview(draft, ownedSkillIDs: ["copied", "unrelated"])
        #expect(reviewed.itemIDs == draft.itemIDs)
        #expect(reviewed.copySkillIDs == ["pending"])
        #expect(reviewed.configurationName == draft.configurationName)
    }

    @Test func reReviewMapsCompletedCopiesToManagedNamesAndRetainsPendingCopies() {
        let draft = OnboardingSelection(
            itemIDs: ["skill:old-name", "skill:pending", "plugin:bundle@catalog"],
            copySkillIDs: ["old-name", "pending"])
        let reviewed = OnboardingDraftPolicy.afterCopyReview(
            draft, ownedSkillIDs: ["portable-name"],
            adoptedSkillIDs: ["old-name": "portable-name", "pending": "not-yet-owned"])
        #expect(reviewed.itemIDs == ["skill:portable-name", "skill:pending", "plugin:bundle@catalog"])
        #expect(reviewed.copySkillIDs == ["pending"])
        #expect(reviewed.configurationName == draft.configurationName)
    }

    @Test func manyCopyIssuesRemainBoundedAndDoNotSkipDuringRendering() throws {
        let issues = (0..<240).map { index in
            SkillAdoptionRejection(
                id: "skill-\(index)", displayName: "Review project documentation \(index + 1)",
                reason:
                    "This skill references a symbolic link outside its source folder. Review the original folder before copying this skill and its supporting files."
            )
        }
        let paths = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, "/example/skills/\($0.id)") })
        for scheme in [ColorScheme.light, .dark] {
            var collapsedHeight: CGFloat = 0
            for expanded in [false, true] {
                var skipCalls = 0
                var disclosureChanges = 0
                let panel = OnboardingCopyIssuesView(
                    issues: issues, sourcePaths: paths,
                    isExpanded: Binding(get: { expanded }, set: { _ in disclosureChanges += 1 }),
                    onSkip: { skipCalls += 1 }
                )
                .frame(width: 844)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: panel)
                host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                host.frame = NSRect(x: 0, y: 0, width: 844, height: 350)
                let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
                let height = host.fittingSize.height
                if expanded {
                    #expect(height > collapsedHeight + 175)
                    #expect(height < 340)
                } else {
                    collapsedHeight = height
                    #expect(height > 60 && height < 130)
                }
                #expect(skipCalls == 0)
                #expect(disclosureChanges == 0)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let folder = ProcessInfo.processInfo.environment["ONBOARDING_LAYOUT_CAPTURE"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    let directory = URL(fileURLWithPath: folder, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(
                        to: directory.appending(
                            path: "copy-issues-\(expanded ? "expanded" : "collapsed")-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
    }

    @Test func automaticPresentationDoesNotInterruptExistingWorkOrRepeatAfterDeferral() {
        #expect(
            OnboardingPresentationPolicy.shouldPresent(
                completed: false, presented: false, hasExistingSetup: false, anotherPresentationActive: false))
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                completed: false, presented: false, hasExistingSetup: true, anotherPresentationActive: false))
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                completed: false, presented: true, hasExistingSetup: false, anotherPresentationActive: false))
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                completed: true, presented: false, hasExistingSetup: false, anotherPresentationActive: false))
        #expect(
            !OnboardingPresentationPolicy.shouldPresent(
                completed: false, presented: false, hasExistingSetup: false, anotherPresentationActive: true))
    }

    @Test func everyStepRendersWithoutRunningAnOperation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "onboarding-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesID = "onboarding-render-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: preferencesID))
        defer { preferences.removePersistentDomain(forName: preferencesID) }
        let store = try WorkspaceStore(rootURL: root.appending(path: "store"))
        let clientState = ClientState(client: .claude, state: .healthy, detail: "Found locally", isInstalled: true)
        let repository = try SkillRepositoryBinding(repositoryURL: "https://github.com/example/workflows", ref: "stable")
        let skills = (0..<240).map { index in
            Skill(
                id: "review-\(index)", name: "review-\(index)", displayName: "Review a pull request \(index + 1)",
                summary: "Review a change with its references and scripts.", bundle: "local-review-\(index)",
                scope: "User", owned: index < 120, triggers: [], negativeTrigger: "", files: ["SKILL.md"],
                clients: [clientState], validationCount: 0, repositoryBinding: index == 130 ? repository : nil)
        }
        let plugin = Plugin(
            id: "developer-workflows@agent-tooling", name: "Developer Workflows", summary: "A reusable workflow bundle.",
            source: "Agent Tooling", scope: "User", revision: "1", skills: (0..<120).map { "review-\($0)" }, profiles: [],
            clients: [clientState], installed: true)
        let server = MCPServer(
            id: "docs", name: "Project documentation", summary: "Read project docs.", endpoint: "https://example.invalid/mcp",
            transport: .http, authentication: "Native", scope: "User", clients: [clientState])
        let skillMetadata = Dictionary(
            uniqueKeysWithValues: (0..<240).map { index in
                (
                    "review-\(index)",
                    ObservedSkillMetadata(
                        path: "/example/skills/review-\(index)", source: index < 120 ? "Plugin" : "Standalone",
                        providerPluginID: index < 120 ? plugin.id : nil)
                )
            })
        let observation = TargetObservation(
            surface: .claudeCode, installed: true, commandAvailable: true, discoveredSkills: skills.map(\.id),
            discoveredPlugins: [plugin.id], discoveredMCPServers: [server.id], skillMetadata: skillMetadata,
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: true, supportsConnectorDiscovery: false, requiresNewSession: true,
                requiresRestart: false, supportsMachineReadableOutput: true))
        try store.save(
            WorkspaceSnapshot(skills: skills, mcpServers: [server], plugins: [plugin], targetObservations: [observation]),
            for: "workspace.snapshot")
        let model = try AppModel(store: store, homeURL: root.appending(path: "home"))
        let inventory = model.onboardingInventory
        let roots = inventory.plugins + inventory.standaloneSkills + inventory.standaloneServers
        let selection = OnboardingSelection(configurationName: "My development setup", itemIDs: Set(roots.map(\.id)))
        #expect(selection.copySkillIDs.isEmpty)
        let preview = try #require(model.previewOnboarding(selection))
        let completion = try #require(model.finishOnboarding(preview))
        #expect(completion.copiedSkillCount == 0)
        let profileCount = model.profiles.count
        let receiptCount = model.operationReceipts.count
        for scheme in [ColorScheme.light, .dark] {
            for step in OnboardingStep.allCases {
                let content = OnboardingWizard(
                    step: step, selection: selection, preview: preview, completion: completion, inventory: inventory, onNavigate: { _ in }
                )
                .environment(model)
                .defaultAppStorage(preferences)
                .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
                let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.size.width == 900 && bitmap.size.height == 700)
                #expect(model.pendingPlan == nil)
                #expect(model.operationReceipts.count == receiptCount)
                #expect(model.profiles.count == profileCount)
                #expect(!preferences.bool(forKey: "onboarding.completed.v1"))
                if let folder = ProcessInfo.processInfo.environment["ONBOARDING_LAYOUT_CAPTURE"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    let directory = URL(fileURLWithPath: folder, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appending(path: "\(step.label.lowercased())-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
    }
}
