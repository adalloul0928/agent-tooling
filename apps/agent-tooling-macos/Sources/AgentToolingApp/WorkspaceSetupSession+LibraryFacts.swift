import AgentToolingCore
import Foundation

/// What the library tells the audit, built in one place so the audit's
/// counts of what this app manages and what it does not can grow without the
/// audit itself changing.
extension WorkspaceSetupSession {
    /// The library as the audit reads it: the declared names of the skills
    /// and the connections this app manages (everything but tracked-only),
    /// and the apps this Mac has Agent Tooling's own connection set up for.
    /// A managed connection in several apps, Agent Tooling's own among them,
    /// is one definition placed in each, never a server configured
    /// separately in each; and where this Mac set Agent Tooling's own up, it
    /// is not one of the app's holdings.
    func libraryFacts() -> SetupAuditor.LibraryFacts {
        let document = library.state?.snapshot.document
        let managed = (document?.artifacts ?? []).filter { $0.authority != .trackedOnly }
        return SetupAuditor.LibraryFacts(
            managedSkillNames: Set(managed.filter { $0.identity.kind == .skill }.compactMap(\.declaredName)),
            managedConnectionNames: Set(managed.filter { $0.identity.kind == .mcpServer }.compactMap(\.declaredName)),
            ownConnectionApps: document.map { AgentToolingConnection.apps(on: library.deviceID, in: $0) } ?? [])
    }
}
