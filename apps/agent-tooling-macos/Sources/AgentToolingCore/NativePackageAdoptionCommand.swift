import CryptoKit
import Foundation

/// Why a catalog listing was not added to the library.
///
/// Each case carries the sentence a screen shows, because a refusal a person
/// cannot read is the same as a disabled button with no explanation — which is
/// exactly what this command exists to remove. Two of them are decided while
/// the command is built, from the listing alone; the rest are decided against
/// the document inside the writing transaction.
public enum NativePackageAdoptionError: LocalizedError, Equatable, Sendable {
    /// The listing does not carry the identity its catalog's own parser
    /// preserves, so there is no package to name.
    case unrecognizedListing
    /// Nothing has written down how this client installs one of its packages.
    case noRecordedInstallCommand(ClientKind)
    /// This library already holds this exact package.
    case alreadyInLibrary(NativePackageAdoption.Match)
    /// A package declaring the same identifier is already here without a route
    /// naming this client. Equal names are not identity evidence, so this is
    /// reported for a person to settle rather than merged or duplicated.
    case ambiguousExistingRecord(NativePackageAdoption.Match, externalPluginID: String)
    /// This package was removed from the library before.
    case previouslyRemoved
    /// The identity this command was built with is already used here.
    case identityCollision

    public var errorDescription: String? {
        switch self {
        case .unrecognizedListing:
            "This listing does not carry the package identity its catalog records, so it cannot be added by name."
        case .noRecordedInstallCommand(let client):
            "Nothing has recorded how \(client.rawValue) installs a package, so this would be a library item Install could never act on."
        case .alreadyInLibrary(let match):
            "\(match.displayName) is already in your library. Open it to choose where it goes."
        case .ambiguousExistingRecord(let match, let externalPluginID):
            """
            Your library already has a package called \(externalPluginID) — \(match.displayName) — recorded from another app. \
            Open it rather than adding a second record of the same name.
            """
        case .previouslyRemoved:
            "You removed this package from your library before. Add it back from the library rather than from a catalog listing."
        case .identityCollision:
            "That identity is already used in this workspace."
        }
    }
}

/// Turns one catalog listing into one library item.
///
/// This is the missing step between "this catalog publishes a package" and
/// "this package is an item in my library that I can assign and then install".
/// It writes exactly one `ArtifactRecord`, and that record claims provenance
/// and nothing else: no assignment, no content digest, no device state, no
/// identity-map entry, and no client file. Adding a package to the library and
/// asking for it somewhere are two different acts, and installing is a third.
///
/// The initializer takes the whole `MarketplacePackage` rather than a
/// client/identifier pair so a caller cannot assemble an identity the catalog
/// parser never produced: `NativeCatalogPackageIdentity.recognize` is the only
/// way in. Building the command is where a listing is refused; applying it is
/// where the library is.
public struct NativePackageAdoptionCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let client: ClientKind
    public let externalPluginID: String
    public let displayName: String

    /// Fails when the listing does not carry the exact catalog identity its
    /// parser preserved, or when no install command has been recorded for the
    /// client.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(),
        package: MarketplacePackage,
        client: ClientKind
    ) throws(NativePackageAdoptionError) {
        let identity = try Self.recognized(package, for: client)
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.client = identity.client
        externalPluginID = identity.externalPluginID
        displayName = Self.label(package.name, orElse: identity.externalPluginID)
    }

    /// Why this listing cannot be added for this client, or `nil` when it can.
    ///
    /// The initializer refuses on exactly these, so a screen that asks before
    /// offering the control and a command applied afterwards cannot disagree
    /// about what is possible. This answers from the listing alone; whether the
    /// library already holds the package is a question for the document, and
    /// `NativePackageAdoption.recognize` answers that one.
    public static func refusal(
        adding package: MarketplacePackage, for client: ClientKind
    ) -> NativePackageAdoptionError? {
        do {
            _ = try recognized(package, for: client)
            return nil
        } catch {
            return error
        }
    }

    /// The catalog's own identity for this listing, when this client can act on
    /// it, and the refusal that names why when it cannot.
    private static func recognized(
        _ package: MarketplacePackage, for client: ClientKind
    ) throws(NativePackageAdoptionError) -> NativeCatalogPackageIdentity {
        guard let identity = NativeCatalogPackageIdentity.recognize(package) else {
            throw .unrecognizedListing
        }
        // Asked about the client whose route this is, not the one the identifier
        // belongs to. Two catalogs describing one package combine their routes,
        // so a listing can carry a route for a client nothing has recorded a
        // command for — and a library item Install could never act on is worth
        // saying plainly, ahead of any point about whose namespace the
        // identifier is in.
        guard
            NativePluginInstallRegister.command(for: client, externalPluginID: identity.externalPluginID) != nil
        else { throw .noRecordedInstallCommand(client) }
        // A `claude:` identifier names a package inside Claude Code's namespace.
        // Adding it as another client's package would record an identity no
        // catalog published, which is what the parser's identity exists to stop.
        guard identity.client == client else { throw .unrecognizedListing }
        return identity
    }

    /// The catalog's declared name, or the identifier it did record.
    ///
    /// A label the document cannot hold — empty, oversized, or carrying control
    /// characters — is replaced by the package identifier rather than trimmed
    /// into something no catalog published. The identifier is bounded and
    /// checked by the parser, so the row always has a name that came from the
    /// catalog.
    private static func label(_ declared: String, orElse identifier: String) -> String {
        let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? WorkspaceDomainValidation.requireText(trimmed, field: "artifact display name", maximum: 512)) != nil
        else { return identifier }
        return trimmed
    }

    func inputDigest() -> String {
        let fields = [
            "native-package.adoption.v1",
            expectedRevisionID.rawValue.uuidString.lowercased(),
            idempotencyKey.rawValue.uuidString.lowercased(),
            artifactID.rawValue.uuidString.lowercased(),
            client.rawValue,
            externalPluginID,
            displayName,
        ]
        let framed = fields.map {
            let value = $0.precomposedStringWithCanonicalMapping
            return String(value.utf8.count) + ":" + value
        }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the one record, or refuses and names the row already here.
    ///
    /// `nativeOwned` is the authority because that is exactly what adopting a
    /// listing records: the client will own these bytes and this workspace will
    /// not. Recording a route is not a presence claim — a saved assignment, a
    /// resolved target for this Mac, matching capability evidence and a
    /// reviewed install route all still have to hold before anything installs.
    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        switch NativePackageAdoption.recognize(client: client, externalPluginID: externalPluginID, in: document) {
        case .exact(let match):
            throw NativePackageAdoptionError.alreadyInLibrary(match)
        case .removed:
            throw NativePackageAdoptionError.previouslyRemoved
        case .sameDeclaredName(let match):
            throw NativePackageAdoptionError.ambiguousExistingRecord(match, externalPluginID: externalPluginID)
        case .none:
            break
        }
        guard !document.artifacts.contains(where: { $0.identity.id == artifactID }),
            !document.tombstones.contains(where: { $0.artifactID == artifactID })
        else { throw NativePackageAdoptionError.identityCollision }
        document.artifacts.append(
            .init(
                identity: .init(
                    id: artifactID, kind: .nativePlugin, displayName: displayName,
                    aliases: [NativePackageAdoption.pluginAlias(client: client, externalPluginID: externalPluginID)]),
                authority: .nativeOwned,
                declaredName: externalPluginID,
                packageRelativePath: nil,
                contentDigest: nil,
                nativeRoutes: [.init(client: client, externalPluginID: externalPluginID)]))
        return [artifactID]
    }
}
