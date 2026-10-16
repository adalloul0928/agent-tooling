import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The enrichment the gallery adds on top of the shared fixture: a library with
/// an assignment so the Skills and Plugins screens are past their onboarding
/// gate, a scanned device so the sidebar and Apps carry verdicts, and the
/// settings, marketplace, projects and insights sessions refreshed so their
/// screens draw rows rather than loading or empty states.
///
/// It only touches sessions the default fixture already wires with answering
/// stubs. Screens that need a differently-built fixture — Checkup with a kept
/// audit, Accounts with read contents, Health with a scripted listing — get
/// theirs in their own area suite rather than here.
extension ShellRenderFixture {
    /// Puts the library past onboarding and leaves a request in it, so Skills,
    /// Plugins and Connections all have real rows.
    func populateForGallery() async {
        await assignStandaloneSkill()
        try? await addRequestedPackage()
    }

    /// Refreshes every session whose screen reads from one, so the gallery
    /// captures drawn content instead of a first-frame loading state.
    func refreshForGallery() async {
        await workspace.library.refresh()
        await workspace.device.refresh()
        await workspace.settings.refresh()
        await workspace.marketplace.refresh()
        await workspace.projectDiscovery.refresh()
    }
}
