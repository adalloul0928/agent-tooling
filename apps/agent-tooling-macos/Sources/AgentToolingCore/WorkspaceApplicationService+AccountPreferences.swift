import CryptoKit
import Foundation

/// Records which account switches every Mac should follow.
///
/// Recording a choice writes the portable document and nothing else. Each Mac
/// then compares the choice with its own settings files and applies the
/// difference through a reviewed plan, the same way an assignment is saved
/// first and installed second.
public struct SetAccountPreferencesCommand: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public let key: AccountPreferenceKey
        /// Nil lets the choice go: each Mac keeps whatever it has.
        public let value: AccountPreferenceValue?

        public init(key: AccountPreferenceKey, value: AccountPreferenceValue?) {
            self.key = key
            self.value = value
        }
    }

    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let changes: [Change]

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        changes: [Change]
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.changes = changes
    }

    func inputDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data("agent-tooling.set-account-preferences.v1\n".utf8)
        bytes.append(try encoder.encode(self))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to document: inout PortableWorkspaceDocument) throws {
        guard !changes.isEmpty, changes.count <= AccountPreferences.maximumEntries else {
            throw WorkspaceDomainValidationError.invalidField("account preference changes")
        }
        guard Set(changes.map(\.key)).count == changes.count else {
            throw WorkspaceDomainValidationError.duplicate("account preference change")
        }
        document.raiseToAccountPreferencesSchema()
        let changed = Set(changes.map(\.key))
        var entries = (document.accountPreferences?.entries ?? []).filter { !changed.contains($0.key) }
        for change in changes {
            guard let value = change.value else { continue }
            let entry = AccountPreference(change.key, value: value)
            try AccountPreferences.validate(entry)
            entries.append(entry)
        }
        let preferences = AccountPreferences(entries: entries).canonicalized()
        try preferences.validate()
        document.accountPreferences = preferences
    }
}

extension WorkspaceApplicationService {
    /// Saves shared account choices in one revision. Nothing on this Mac's
    /// clients changes here; applying them is a separate, reviewed plan.
    public func setAccountPreferences(_ command: SetAccountPreferencesCommand) throws -> WorkspaceCommandReceipt {
        let digest = try command.inputDigest()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: digest,
            writerID: writerID
        ) { document in
            try command.apply(to: &document)
            return []
        }
    }
}
