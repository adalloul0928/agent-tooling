import CryptoKit
import Foundation

/// Adds accepted skill copies, catalog listings and fetched skills in one
/// revision. Each rejected row records a reason without failing accepted rows.
/// The batch's head and idempotency key replace those of its component commands.
/// Client installation remains a separate reviewed operation.
public struct WorkspaceLibraryAdditionBatch: Equatable, Sendable {
    /// A tracked skill made yours from the copy at `sourcePath`. The copy's
    /// files are the prepared skill handed in with the batch under the same
    /// artifact.
    public struct Adoption: Equatable, Sendable {
        public let artifactID: ArtifactID
        /// The folder the chosen copy was read from.
        public let sourcePath: String

        public init(artifactID: ArtifactID, sourcePath: String) {
            self.artifactID = artifactID
            self.sourcePath = sourcePath
        }
    }

    public let expectedRevisionID: WorkspaceObjectID
    let idempotencyKey: WorkspaceObjectID
    public let adoptions: [Adoption]
    public let catalogAdds: [NativePackageAdoptionCommand]
    public let intakes: [StandaloneSkillIntakeCommand]

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        adoptions: [Adoption] = [], catalogAdds: [NativePackageAdoptionCommand] = [],
        intakes: [StandaloneSkillIntakeCommand] = []
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.adoptions = adoptions
        self.catalogAdds = catalogAdds
        self.intakes = intakes
    }

    /// Whether there is nothing to add.
    public var isEmpty: Bool { adoptions.isEmpty && catalogAdds.isEmpty && intakes.isEmpty }

    /// Every row's artifact, in the order the rows apply: the skills made
    /// yours, then the catalog listings, then the new skills.
    public var artifactIDs: [ArtifactID] {
        adoptions.map(\.artifactID) + catalogAdds.map(\.artifactID) + intakes.map(\.artifactID)
    }

    /// The same batch without the rows for `artifactIDs`: what is left once
    /// the refused rows a preview named are taken out. It is a different
    /// edit, so it takes a key of its own.
    public func excluding(_ artifactIDs: Set<ArtifactID>) -> Self {
        Self(
            expectedRevisionID: expectedRevisionID,
            adoptions: adoptions.filter { !artifactIDs.contains($0.artifactID) },
            catalogAdds: catalogAdds.filter { !artifactIDs.contains($0.artifactID) },
            intakes: intakes.filter { !artifactIDs.contains($0.artifactID) })
    }

    // MARK: Applying the rows

    /// Applies every row the document accepts, in order, each against the
    /// document as the rows before it left it, and returns the artifacts that
    /// changed. A row that is refused leaves the document as it was and adds
    /// its reason to `refusals`.
    func apply(
        to document: inout PortableWorkspaceDocument, prepared: [ArtifactID: PreparedStandaloneSkill],
        refusals: inout [LibraryAdditionRefusal]
    ) -> [ArtifactID] {
        var landed: [ArtifactID] = []
        for adoption in adoptions {
            guard let skill = prepared[adoption.artifactID] else {
                refusals.append(.notAdoptable(adoption.artifactID, .notRead))
                continue
            }
            var candidate = document
            do {
                landed += try AdoptTrackedSkillCommand.adopt(
                    adoption.artifactID, content: skill.review, declaredName: skill.frontmatter.name, in: &candidate)
                document = candidate
            } catch {
                refusals.append(Self.refusal(adopting: adoption.artifactID, in: document, error))
            }
        }
        for command in catalogAdds {
            var candidate = document
            do {
                landed += try command.apply(to: &candidate)
                document = candidate
            } catch {
                refusals.append(.catalog(command.artifactID, error as? NativePackageAdoptionError ?? .identityCollision))
            }
        }
        for command in intakes {
            guard let skill = prepared[command.artifactID], skill.review == command.content else {
                refusals.append(.intake(command.artifactID, .reviewMismatch))
                continue
            }
            var candidate = document
            do {
                landed += try command.apply(to: &candidate, declaredName: skill.frontmatter.name)
                document = candidate
            } catch {
                refusals.append(.intake(command.artifactID, error as? WorkspaceSkillCommandError ?? .identityCollision))
            }
        }
        return landed
    }

    /// The rows that land, or `nothingToAdd` when every row is refused: a
    /// batch never writes a revision that changes nothing.
    func landing(in document: inout PortableWorkspaceDocument, prepared: [ArtifactID: PreparedStandaloneSkill]) throws -> [ArtifactID] {
        var refusals: [LibraryAdditionRefusal] = []
        let landed = apply(to: &document, prepared: prepared, refusals: &refusals)
        guard !landed.isEmpty else { throw LibraryAdditionError.nothingToAdd(refusals) }
        return landed
    }

    /// Why making `artifactID` yours was refused, from the error and the
    /// record as it stands.
    private static func refusal(
        adopting artifactID: ArtifactID, in document: PortableWorkspaceDocument, _ error: any Error
    ) -> LibraryAdditionRefusal {
        if case WorkspaceSkillCommandError.declaredNameMismatch(let recorded, let found) = error {
            return .declaredNameMismatch(artifactID, recorded: recorded, found: found)
        }
        guard let record = document.artifacts.first(where: { $0.identity.id == artifactID }) else {
            return .notAdoptable(artifactID, .missing)
        }
        switch record.authority {
        case .centralPersonal, .centralUpstream:
            return .notAdoptable(artifactID, .alreadyYours)
        default:
            break
        }
        guard record.identity.kind == .skill, record.identity.parentPackageID == nil, record.authority == .trackedOnly else {
            return .notAdoptable(artifactID, .notALooseSkill)
        }
        // A tracked skill whose files arrived with an upstream binding: it is
        // not a copy a person holds, so it cannot become theirs as one.
        return .notAdoptable(artifactID, .followsAnUpstream)
    }

    // MARK: Identity

    /// The key attempt `attempt` commits under: the batch's own first, then
    /// one derived from it for each retry, so the same batch handed in again
    /// finds the revision its retry wrote rather than writing another.
    func idempotencyKey(forAttempt attempt: Int) -> WorkspaceObjectID {
        guard attempt > 0 else { return idempotencyKey }
        let seed = "agent-tooling.library-additions.retry.v1|\(idempotencyKey.rawValue.uuidString.lowercased())|\(attempt)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        // A name-based UUID (version 5, RFC 4122 variant), so it reads as one.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        return WorkspaceObjectID(rawValue: uuid)
    }

    /// What attempt `attempt` asks for, as a digest the store keeps with its
    /// receipt: every row, with the content each skill is taken in with. The
    /// head a retry commits against is not part of it, so the replay of a
    /// retried batch matches the receipt the retry left.
    func inputDigest(prepared: [ArtifactID: PreparedStandaloneSkill], attempt: Int) throws -> String {
        let payload = DigestPayload(
            expectedRevisionID: expectedRevisionID, idempotencyKey: idempotencyKey, attempt: attempt,
            adoptions: adoptions.map {
                .init(
                    artifactID: $0.artifactID, sourcePath: $0.sourcePath, content: prepared[$0.artifactID]?.review,
                    declaredName: prepared[$0.artifactID]?.frontmatter.name)
            },
            catalogAdds: catalogAdds.map {
                .init(
                    artifactID: $0.artifactID, client: $0.client, externalPluginID: $0.externalPluginID,
                    displayName: $0.displayName)
            },
            intakes: intakes.map {
                .init(
                    artifactID: $0.artifactID, displayName: $0.displayName, aliases: $0.aliases, content: $0.content,
                    upstreamIDs: $0.upstreamIDs, declaredName: prepared[$0.artifactID]?.frontmatter.name)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data("agent-tooling.library-additions.v1\n".utf8)
        bytes.append(try encoder.encode(payload))
        guard bytes.count <= WorkspaceDocumentCoding.maximumDocumentBytes else { throw WorkspaceRevisionStoreError.recordTooLarge }
        return SHA256.hash(data: bytes).lowercaseHex
    }

    private struct DigestPayload: Encodable {
        struct Adoption: Encodable {
            let artifactID: ArtifactID
            let sourcePath: String
            let content: StandaloneSkillContentReview?
            let declaredName: String?
        }

        struct CatalogAdd: Encodable {
            let artifactID: ArtifactID
            let client: ClientKind
            let externalPluginID: String
            let displayName: String
        }

        struct Intake: Encodable {
            let artifactID: ArtifactID
            let displayName: String
            let aliases: [ExternalAlias]
            let content: StandaloneSkillContentReview
            let upstreamIDs: StandaloneSkillUpstreamIDs?
            let declaredName: String?
        }

        let expectedRevisionID: WorkspaceObjectID
        let idempotencyKey: WorkspaceObjectID
        let attempt: Int
        let adoptions: [Adoption]
        let catalogAdds: [CatalogAdd]
        let intakes: [Intake]
    }
}

/// One row of a batch of additions the library would not take, and why.
public enum LibraryAdditionRefusal: Equatable, Sendable {
    /// Why a tracked skill could not be made yours.
    public enum Reason: Equatable, Sendable {
        /// The record is no longer in the library.
        case missing
        /// It is yours already.
        case alreadyYours
        /// It is not a loose skill: one inside a plugin, or something other
        /// than a skill.
        case notALooseSkill
        /// No copy of it was read, so there are no files to take.
        case notRead
        /// The files offered follow a repository rather than being a copy an
        /// app holds.
        case followsAnUpstream
    }

    /// The copy's SKILL.md calls it `found`, and the record says `recorded`:
    /// it is not this skill until one is renamed to match.
    case declaredNameMismatch(ArtifactID, recorded: String, found: String)
    case notAdoptable(ArtifactID, Reason)
    /// A catalog listing the library refused, in the command's own words.
    case catalog(ArtifactID, NativePackageAdoptionError)
    /// A new skill the library refused.
    case intake(ArtifactID, WorkspaceSkillCommandError)

    /// The row's artifact.
    public var artifactID: ArtifactID {
        switch self {
        case .declaredNameMismatch(let id, _, _), .notAdoptable(let id, _), .catalog(let id, _), .intake(let id, _): id
        }
    }
}

/// Why a batch of additions wrote nothing.
public enum LibraryAdditionError: Error, Equatable, Sendable {
    /// Every row was refused, each with its reason, so there was nothing to
    /// write.
    case nothingToAdd([LibraryAdditionRefusal])
}
