import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Every section through the shell, at the default and minimum window sizes, in
/// light and dark. This is the backbone of the gallery: the screens a person
/// reaches from the sidebar, drawn the way a window would give them.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder, so a
/// normal `swift test` never renders any of it.
@Suite("Gallery · Sections", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GallerySectionsTests {
    /// The sidebar sections, with the area each belongs to and the `path:line`
    /// of the view the shell puts in its detail column.
    static let sections: [(section: AppSection, area: String, source: String)] = [
        (.overview, "Home", "Sources/AgentToolingApp/OverviewView.swift"),
        (.marketplace, "Discover", "Sources/AgentToolingApp/MarketplaceView.swift"),
        (.skills, "Library · Skills", "Sources/AgentToolingApp/SkillsView.swift"),
        (.plugins, "Library · Plugins", "Sources/AgentToolingApp/PluginsView.swift"),
        (.mcpServers, "Library · Connections", "Sources/AgentToolingApp/MCPServersView.swift"),
        (.presets, "Library · Presets", "Sources/AgentToolingApp/PresetsView.swift"),
        (.insights, "Insights", "Sources/AgentToolingApp/InsightsView.swift"),
        (.syncCenter, "Apps · Clients", "Sources/AgentToolingApp/Sections/ClientsSection.swift"),
        (.accounts, "Apps · Accounts", "Sources/AgentToolingApp/AccountsView.swift"),
        (.checkup, "Apps · Checkup", "Sources/AgentToolingApp/CheckupView.swift"),
        (.appSettings, "Apps · App settings", "Sources/AgentToolingApp/EffectiveSettingsView.swift"),
        (.health, "Apps · Health", "Sources/AgentToolingApp/HealthView.swift"),
        (.projects, "Projects", "Sources/AgentToolingApp/ProjectsView.swift"),
        (.activity, "Activity", "Sources/AgentToolingApp/Sections/ActivitySection.swift"),
        (.history, "History", "Sources/AgentToolingApp/Sections/HistorySection.swift"),
        (.settings, "Settings", "Sources/AgentToolingApp/SyncSettingsView.swift"),
        (.sync, "Sync", "Sources/AgentToolingApp/SyncSettingsView.swift"),
    ]

    /// A fixture populated past every screen's empty state, so the gallery
    /// shows real rows rather than onboarding gates.
    private func populated() async throws -> (ShellRenderFixture, RenderPreferences) {
        let fixture = try await ShellRenderFixture()
        let preferences = try ShellRenderFixture.preferences()
        await fixture.populateForGallery()
        return (fixture, preferences)
    }

    @Test func everySectionAtStandardSizeLightAndDark() async throws {
        for entry in Self.sections {
            let (fixture, preferences) = try await populated()
            defer { fixture.remove(); preferences.remove() }
            await fixture.refreshForGallery()
            for appearance in [RenderAppearance.light, .dark] {
                try galleryShellSnapshot(
                    renderShell(entry.section, fixture: fixture)
                        .environment(\.skillContentService, StubSkillContentService())
                        .environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: [ShellRenderFixture.receipt()]))
                        .defaultAppStorage(preferences.defaults),
                    area: entry.area, screen: entry.section.navigationTitle, state: "populated",
                    size: GallerySize.standard, appearance: appearance, source: entry.source)
            }
        }
    }

    @Test func everySectionAtMinimumSizeLight() async throws {
        for entry in Self.sections {
            let (fixture, preferences) = try await populated()
            defer { fixture.remove(); preferences.remove() }
            await fixture.refreshForGallery()
            try galleryShellSnapshot(
                renderShell(entry.section, fixture: fixture)
                    .environment(\.skillContentService, StubSkillContentService())
                    .environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: [ShellRenderFixture.receipt()]))
                    .defaultAppStorage(preferences.defaults),
                area: entry.area, screen: entry.section.navigationTitle, state: "populated",
                size: GallerySize.minimum, appearance: .light, source: entry.source)
        }
    }

    /// The empty and first-run states a reviewer should see distinctly from the
    /// populated screen: the library's getting-started gate, Discover with
    /// every catalog failed, and an empty projects list.
    @Test func distinctEmptyStates() async throws {
        // The library stands its onboarding gate in front of Skills and Plugins
        // until something is assigned.
        let gateFixture = try await ShellRenderFixture()
        defer { gateFixture.remove() }
        let gatePreferences = try ShellRenderFixture.preferences(onboardingSkipped: false)
        defer { gatePreferences.remove() }
        try galleryShellSnapshot(
            renderShell(.skills, fixture: gateFixture)
                .environment(\.skillContentService, StubSkillContentService())
                .defaultAppStorage(gatePreferences.defaults),
            area: "Library · Skills", screen: "Library", state: "onboarding-gate",
            source: "Sources/AgentToolingApp/Sections/SkillsSection.swift")

        // Discover with nothing to show because every catalog failed.
        let brokenFixture = try await ShellRenderFixture(
            marketplaceProviders: [StubMarketplaceProvider(displayName: "Broken catalog", fails: true)])
        defer { brokenFixture.remove() }
        await brokenFixture.workspace.marketplace.refresh()
        try galleryShellSnapshot(
            renderShell(.marketplace, fixture: brokenFixture),
            area: "Discover", screen: "Discover", state: "every-catalog-failed",
            source: "Sources/AgentToolingApp/MarketplaceView.swift")
    }
}
