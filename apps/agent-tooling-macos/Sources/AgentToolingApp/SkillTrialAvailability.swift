import AgentToolingCore
import Foundation

/// Whether a skill can be tried in an app from here, and why not when it
/// cannot: the one check behind Library's Try… and Home's Try it, so the two
/// never disagree about what opens.
///
/// A skill is tried by opening its app in Terminal with the skill invoked,
/// so it has to be one the app can be asked for by name, in an app this Mac
/// can open that way, where the last check actually found it: an app that
/// does not have the skill would only say so.
enum SkillTrialAvailability {
    /// Why the skill that declares `skillName` cannot be tried in `client`
    /// right now, or nil when it can. `observedIn` is where the last check
    /// found it, `requestedIn` where somebody asked for it, and `canOpen`
    /// whether this Mac can open `client` in Terminal at all.
    static func cannotTryReason(
        skillName: String?, in client: ClientKind, observedIn: Set<ClientKind>, requestedIn: Set<ClientKind> = [],
        canOpen: Bool
    ) -> String? {
        guard SkillTrialCommandShapes.isSupported(client) else {
            return "Trying a skill in \(client.rawValue) from here is not supported yet."
        }
        guard let skillName, SkillTrialCommandShapes.isValidSkillReference(skillName) else {
            return "This skill has no name an app could call."
        }
        guard observedIn.contains(client) else {
            return requestedIn.contains(client)
                ? "Install it in \(client.rawValue) first; the last check did not find it there."
                : "The last check did not find this skill in \(client.rawValue)."
        }
        guard canOpen else {
            return "\(client.rawValue)’s command-line tool was not found on this Mac."
        }
        return nil
    }

    /// The apps whose last check found a skill declaring `skillName`, joined
    /// by that name the way the Library joins a row to what a check saw.
    static func observedApps(of skillName: String, in observations: [TargetObservation]) -> Set<ClientKind> {
        Set(observations.compactMap { $0.skillMetadata[skillName] == nil ? nil : $0.surface.client })
    }
}

extension WorkspaceSetupProgressSession {
    /// A skill was opened in an app to try it, from `place`: Home's "Try a
    /// skill" row is done, and names where ("from Library", "from Home"). It
    /// ticks once; a later trial keeps the first.
    func recordTrial(skillName: String, client: ClientKind, place: FinishSetupPlace, now: Date = .now) {
        tick(.trySkill, place: place, summary: LaunchpadCopy.FinishSetup.tried(skillName, in: client.rawValue), now: now)
    }
}
