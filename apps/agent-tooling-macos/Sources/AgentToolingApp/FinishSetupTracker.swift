import AgentToolingCore
import SwiftUI

/// Ticks checklist rows once on positive evidence and records where they completed.
/// Initial or background completion uses the row's own location; user actions use
/// the current screen. Deferred setup preserves initial Checkup findings so
/// resolving them completes its row. Legacy, newer-format, and active first-run
/// records are ignored. This view performs no discovery itself.
struct FinishSetupTracker: View {
    let workspace: WorkspaceLaunch.Workspace
    /// The section on screen.
    let section: AppSection
    @Environment(\.stagePresented) private var stagePresented
    @State private var settled = false

    /// What one look is about: the rows the facts make true, and the
    /// findings Checkup shows.
    private struct Look: Equatable {
        let satisfied: Set<FinishSetupItem>
        let findings: [String]?
    }

    var body: some View {
        let facts = FinishSetupFacts.live(workspace: workspace)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(
                of: Look(satisfied: FinishSetupChecklist.satisfied(facts), findings: facts.openFindings?.map(\.id)), initial: true
            ) { _, look in
                if let findings = Self.findingsToKeep(facts) {
                    workspace.setupProgress.recordEvidence { $0.checkupFindingIDs = findings }
                }
                let now = Date.now
                for (item, place) in Self.ticks(
                    look.satisfied, facts: facts, section: section, stagePresented: stagePresented, settled: settled)
                {
                    workspace.setupProgress.tick(
                        item, place: place, summary: FinishSetupChecklist.summary(for: item, facts: facts, now: now),
                        now: now)
                }
                settled = true
            }
    }

    /// The findings a setup left for later keeps the first time Checkup
    /// shows any: the ones its Checkup row is about from then on. Nil when
    /// there is nothing to keep: a finished setup (Done kept its own), one
    /// that keeps some already, or no finding shown.
    static func findingsToKeep(_ facts: FinishSetupFacts) -> [String]? {
        guard let record = facts.record, record.state == .deferred, record.evidence.checkupFindingIDs.isEmpty,
            let open = facts.openFindings, !open.isEmpty
        else { return nil }
        return open.map(\.id)
    }

    /// The ticks one look makes: each satisfied row on the card not ticked
    /// yet, with where it happened.
    static func ticks(
        _ satisfied: Set<FinishSetupItem>, facts: FinishSetupFacts, section: AppSection, stagePresented: Bool,
        settled: Bool
    ) -> [(item: FinishSetupItem, place: FinishSetupPlace)] {
        guard let record = facts.record, record.state != .inProgress,
            record.formatVersion <= SetupProgressRecord.currentFormatVersion
        else { return [] }
        let onCard = Set(FinishSetupChecklist.rows(record, facts: facts))
        let ticked = Set(record.ticks.map(\.item))
        return FinishSetupItem.allCases
            .filter { satisfied.contains($0) && onCard.contains($0) && !ticked.contains($0) }
            .map { ($0, place(for: $0, record: record, section: section, stagePresented: stagePresented, settled: settled)) }
    }

    /// Where a row that just came true was done.
    static func place(
        for item: FinishSetupItem, record: SetupProgressRecord, section: AppSection, stagePresented: Bool, settled: Bool
    ) -> FinishSetupPlace {
        if stagePresented { return .setup }
        guard settled else {
            // The first look after the stage left a first run for later: what
            // setup's own steps did before it stopped, it did in setup. Agent
            // Tooling's own connection is setup's only once it showed Let
            // your apps ask; one there before that was made elsewhere.
            if record.state == .deferred, record.ticks.isEmpty, item.isSetupStep,
                item != .connectAgentTooling || record.seen.contains(.ask)
            {
                return .setup
            }
            return item.canonicalPlace
        }
        return item.flipsInBackground ? item.canonicalPlace : FinishSetupPlace(section: section)
    }
}
