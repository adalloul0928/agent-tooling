import Foundation

public struct ConfirmedSourceBinding: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var repositoryURL: String
    public var requestedRef: String
    public var packagePath: String

    public init(artifactID: ArtifactID, repositoryURL: String, requestedRef: String, packagePath: String) {
        self.artifactID = artifactID
        self.repositoryURL = repositoryURL
        self.requestedRef = requestedRef
        self.packagePath = packagePath
    }
}

public enum SourceEvidenceMatchContext: String, Hashable, Sendable {
    case exactRelativePath, checkoutRepository, nativeChild, nameOnly, ambiguousPath
}

public struct SourceEvidenceObservation: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var context: SourceEvidenceMatchContext
    public var evidence: SourceLockEvidence
    public var observedCommit: SourceRevision?

    public init(
        artifactID: ArtifactID, context: SourceEvidenceMatchContext,
        evidence: SourceLockEvidence, observedCommit: SourceRevision? = nil
    ) {
        self.artifactID = artifactID
        self.context = context
        self.evidence = evidence
        self.observedCommit = observedCommit
    }
}

public struct SourceEvidenceCandidate: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var repositoryURL: String
    public var requestedRef: String
    public var packagePath: String
    public var observedCommit: SourceRevision?
    public var integrity: [SourceLockIntegrityEvidence]

    public init(
        artifactID: ArtifactID, repositoryURL: String, requestedRef: String,
        packagePath: String, observedCommit: SourceRevision? = nil,
        integrity: [SourceLockIntegrityEvidence] = []
    ) {
        self.artifactID = artifactID
        self.repositoryURL = repositoryURL
        self.requestedRef = requestedRef
        self.packagePath = packagePath
        self.observedCommit = observedCommit
        self.integrity = integrity
    }
}

public enum SourceEvidenceConflictKind: String, Hashable, Sendable {
    case confirmedBindingDisagreement, competingObservations, competingEvidenceFacts
    case duplicateArtifactIdentity, duplicateConfirmedBinding
}

public struct SourceEvidenceConflict: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var kind: SourceEvidenceConflictKind
    /// Alternatives stay review-only and never enter an eligible fetch group.
    public var alternatives: [SourceEvidenceCandidate]

    public init(artifactID: ArtifactID, kind: SourceEvidenceConflictKind, alternatives: [SourceEvidenceCandidate] = []) {
        self.artifactID = artifactID
        self.kind = kind
        self.alternatives = alternatives
    }
}

public enum SourceEvidenceUnresolvedReason: String, Hashable, Sendable {
    case unknownArtifact, duplicateArtifactIdentity, invalidConfirmedBinding, duplicateConfirmedBinding
    case ineligibleArtifactAuthority, childArtifact, insufficientMatchContext, evidenceGap
    case invalidLocator, invalidPackagePath, invalidRequestedRef, invalidObservedCommit, invalidIntegrity
    case unsupportedArtifactKind, missingConfirmedUpstreamBinding, competingObservations, competingEvidenceFacts
}

public struct SourceEvidenceUnresolved: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var reason: SourceEvidenceUnresolvedReason

    public init(artifactID: ArtifactID, reason: SourceEvidenceUnresolvedReason) {
        self.artifactID = artifactID
        self.reason = reason
    }
}

public enum SourceEvidenceResolverDiagnostic: String, Hashable, Sendable {
    case unknownArtifactObservation, duplicateArtifactIdentity
    case invalidConfirmedBinding, duplicateConfirmedBinding, invalidObservation
}

public struct SourceEvidenceFetchArtifact: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var packagePath: String

    public init(artifactID: ArtifactID, packagePath: String) {
        self.artifactID = artifactID
        self.packagePath = packagePath
    }
}

public struct SourceEvidenceFetchGroup: Hashable, Sendable {
    public var repositoryURL: String
    public var requestedRef: String
    public var artifactPaths: [SourceEvidenceFetchArtifact]

    public init(repositoryURL: String, requestedRef: String, artifactPaths: [SourceEvidenceFetchArtifact]) {
        self.repositoryURL = repositoryURL
        self.requestedRef = requestedRef
        self.artifactPaths = artifactPaths
    }
}

public struct SourceEvidenceResolution: Hashable, Sendable {
    public var confirmedBindings: [ConfirmedSourceBinding]
    public var candidates: [SourceEvidenceCandidate]
    public var conflicts: [SourceEvidenceConflict]
    public var unresolved: [SourceEvidenceUnresolved]
    public var proposedFetchGroups: [SourceEvidenceFetchGroup]
    public var diagnostics: [SourceEvidenceResolverDiagnostic]

    public var unresolvedArtifactIDs: [ArtifactID] {
        Array(Set(unresolved.map(\.artifactID))).sorted()
    }

    public init(
        confirmedBindings: [ConfirmedSourceBinding], candidates: [SourceEvidenceCandidate],
        conflicts: [SourceEvidenceConflict], unresolved: [SourceEvidenceUnresolved],
        proposedFetchGroups: [SourceEvidenceFetchGroup], diagnostics: [SourceEvidenceResolverDiagnostic]
    ) {
        self.confirmedBindings = confirmedBindings
        self.candidates = candidates
        self.conflicts = conflicts
        self.unresolved = unresolved
        self.proposedFetchGroups = proposedFetchGroups
        self.diagnostics = diagnostics
    }
}

/// Reconciles caller-provided evidence without file, network, or native-client operations.
public enum SourceEvidenceResolver {
    public static func resolve(
        artifacts: [ArtifactRecord], confirmed: [ConfirmedSourceBinding], observations: [SourceEvidenceObservation]
    ) -> SourceEvidenceResolution {
        let artifactsByID = Dictionary(grouping: artifacts, by: { $0.identity.id })
        let duplicateArtifactIDs = Set(artifactsByID.compactMap { $0.value.count == 1 ? nil : $0.key })
        var unresolved = Set<SourceEvidenceUnresolved>()
        var diagnostics = Set<SourceEvidenceResolverDiagnostic>()
        var conflicts: [SourceEvidenceConflict] = duplicateArtifactIDs.map { id in
            unresolved.insert(.init(artifactID: id, reason: .duplicateArtifactIdentity))
            diagnostics.insert(.duplicateArtifactIdentity)
            return .init(artifactID: id, kind: .duplicateArtifactIdentity)
        }

        let confirmedGroups = Dictionary(grouping: confirmed, by: \.artifactID)
        var confirmedByID: [ArtifactID: ConfirmedSourceBinding] = [:]
        var canonicalConfirmed: [ArtifactID: CanonicalBinding] = [:]
        var suppressedConfirmedIDs = Set<ArtifactID>()
        for id in confirmedGroups.keys.sorted() {
            guard let values = confirmedGroups[id] else { continue }
            guard values.count == 1 else {
                suppressedConfirmedIDs.insert(id)
                unresolved.insert(.init(artifactID: id, reason: .duplicateConfirmedBinding))
                diagnostics.insert(.duplicateConfirmedBinding)
                conflicts.append(.init(artifactID: id, kind: .duplicateConfirmedBinding))
                continue
            }
            let binding = values[0]
            guard let artifact = uniqueArtifact(id, in: artifactsByID), eligible(artifact),
                artifact.identity.parentPackageID == nil, supportedKind(artifact.identity.kind),
                let canonical = canonicalBinding(binding)
            else {
                suppressedConfirmedIDs.insert(id)
                unresolved.insert(.init(artifactID: id, reason: .invalidConfirmedBinding))
                diagnostics.insert(.invalidConfirmedBinding)
                continue
            }
            confirmedByID[id] = binding
            canonicalConfirmed[id] = canonical
        }

        var observedByID: [ArtifactID: [SourceEvidenceCandidate]] = [:]
        for observation in observations {
            let id = observation.artifactID
            guard let artifact = uniqueArtifact(id, in: artifactsByID) else {
                let reason: SourceEvidenceUnresolvedReason = duplicateArtifactIDs.contains(id)
                    ? .duplicateArtifactIdentity : .unknownArtifact
                unresolved.insert(.init(artifactID: id, reason: reason))
                diagnostics.insert(reason == .unknownArtifact ? .unknownArtifactObservation : .duplicateArtifactIdentity)
                continue
            }
            guard eligible(artifact) else {
                unresolved.insert(.init(artifactID: id, reason: .ineligibleArtifactAuthority))
                continue
            }
            guard artifact.identity.parentPackageID == nil else {
                unresolved.insert(.init(artifactID: id, reason: .childArtifact))
                continue
            }
            guard supportedKind(artifact.identity.kind) else {
                unresolved.insert(.init(artifactID: id, reason: .unsupportedArtifactKind))
                continue
            }
            if case .centralUpstream = artifact.authority, canonicalConfirmed[id] == nil {
                unresolved.insert(.init(artifactID: id, reason: .missingConfirmedUpstreamBinding))
                continue
            }
            guard !suppressedConfirmedIDs.contains(id) else { continue }
            guard observation.context == .exactRelativePath else {
                unresolved.insert(.init(artifactID: id, reason: .insufficientMatchContext))
                continue
            }
            guard observation.evidence.gaps.isEmpty else {
                unresolved.insert(.init(artifactID: id, reason: .evidenceGap))
                continue
            }
            guard case .remote(_, _, let rawURL?, _) = observation.evidence.locator,
                let repositoryURL = canonicalGitHubURL(rawURL)
            else {
                reject(id, .invalidLocator, unresolved: &unresolved, diagnostics: &diagnostics)
                continue
            }
            guard let packagePath = observation.evidence.skillPath, safePath(packagePath) else {
                reject(id, .invalidPackagePath, unresolved: &unresolved, diagnostics: &diagnostics)
                continue
            }
            guard case .requestedRef(let requestedRef)? = observation.evidence.revision, safeRef(requestedRef) else {
                reject(id, .invalidRequestedRef, unresolved: &unresolved, diagnostics: &diagnostics)
                continue
            }
            guard validIntegrity(observation.evidence.integrity) else {
                reject(id, .invalidIntegrity, unresolved: &unresolved, diagnostics: &diagnostics)
                continue
            }
            if let commit = observation.observedCommit, !validCommit(commit) {
                reject(id, .invalidObservedCommit, unresolved: &unresolved, diagnostics: &diagnostics)
                continue
            }
            observedByID[id, default: []].append(.init(
                artifactID: id, repositoryURL: repositoryURL, requestedRef: requestedRef,
                packagePath: packagePath, observedCommit: observation.observedCommit,
                integrity: sortedIntegrity(observation.evidence.integrity)
            ))
        }

        var candidates: [SourceEvidenceCandidate] = []
        for id in observedByID.keys.sorted() {
            let alternatives = uniqueCandidates(observedByID[id] ?? [])
            if let binding = canonicalConfirmed[id] {
                let disagreements = alternatives.filter { !binding.matches($0) }
                if !disagreements.isEmpty {
                    conflicts.append(.init(artifactID: id, kind: .confirmedBindingDisagreement, alternatives: disagreements))
                }
            } else if alternatives.count == 1 {
                candidates.append(alternatives[0])
            } else {
                let locatorCount = Set(alternatives.map {
                    "\($0.repositoryURL)\n\($0.requestedRef)\n\($0.packagePath)"
                }).count
                let kind: SourceEvidenceConflictKind = locatorCount > 1 ? .competingObservations : .competingEvidenceFacts
                let reason: SourceEvidenceUnresolvedReason = locatorCount > 1 ? .competingObservations : .competingEvidenceFacts
                unresolved.insert(.init(artifactID: id, reason: reason))
                conflicts.append(.init(artifactID: id, kind: kind, alternatives: alternatives))
            }
        }

        candidates.sort(by: candidateOrder)
        conflicts = sortedConflicts(conflicts)
        return .init(
            confirmedBindings: confirmedByID.values.sorted { $0.artifactID < $1.artifactID },
            candidates: candidates,
            conflicts: conflicts,
            unresolved: unresolved.sorted(by: unresolvedOrder),
            proposedFetchGroups: fetchGroups(candidates),
            diagnostics: diagnostics.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private struct CanonicalBinding {
        var repositoryURL: String
        var requestedRef: String
        var packagePath: String

        func matches(_ candidate: SourceEvidenceCandidate) -> Bool {
            repositoryURL == candidate.repositoryURL && requestedRef == candidate.requestedRef
                && packagePath == candidate.packagePath
        }
    }

    private static func reject(
        _ id: ArtifactID, _ reason: SourceEvidenceUnresolvedReason,
        unresolved: inout Set<SourceEvidenceUnresolved>, diagnostics: inout Set<SourceEvidenceResolverDiagnostic>
    ) {
        unresolved.insert(.init(artifactID: id, reason: reason))
        diagnostics.insert(.invalidObservation)
    }

    private static func uniqueArtifact(_ id: ArtifactID, in values: [ArtifactID: [ArtifactRecord]]) -> ArtifactRecord? {
        guard let records = values[id], records.count == 1 else { return nil }
        return records[0]
    }

    private static func eligible(_ artifact: ArtifactRecord) -> Bool {
        switch artifact.authority {
        case .nativeOwned, .attachedAuthoring: false
        case .centralPersonal, .centralUpstream, .trackedOnly: true
        }
    }

    private static func supportedKind(_ kind: ArtifactKind) -> Bool {
        kind == .skill || kind == .package
    }

    private static func canonicalBinding(_ binding: ConfirmedSourceBinding) -> CanonicalBinding? {
        guard let url = canonicalGitHubURL(binding.repositoryURL), safeRef(binding.requestedRef), safePath(binding.packagePath) else {
            return nil
        }
        return .init(repositoryURL: url, requestedRef: binding.requestedRef, packagePath: binding.packagePath)
    }

    // Shared with the bounded checkout reader; neither route accepts credential-bearing URLs.
    static func canonicalGitHubURL(_ value: String) -> String? {
        guard value.count <= 4_096, var components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host?.caseInsensitiveCompare("github.com") == .orderedSame,
            components.port == nil, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.percentEncodedPath == components.path
        else { return nil }
        var path = components.path
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty,
            parts.dropFirst().allSatisfy({ safeRepositoryComponent(String($0)) })
        else { return nil }
        components.scheme = "https"
        components.host = "github.com"
        // GitHub repository identity is case-insensitive. This normalization
        // is intentionally host-specific and must not be applied to other Git hosts.
        components.path = path.lowercased()
        return components.string
    }

    private static func safeRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.count <= 100
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
            }
    }

    static func safePath(_ value: String) -> Bool {
        if value == "." { return true }
        guard !value.isEmpty, value.count <= 4_096, !value.hasPrefix("/"), !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
        }
    }

    static func safeRef(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && !value.hasPrefix("-") && !value.hasPrefix("/")
            && !value.hasSuffix("/") && !value.contains("..") && !value.contains("@{")
            && !value.contains("//") && !value.hasSuffix(".")
            && value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.+").contains($0)
            }
    }

    static func validCommit(_ revision: SourceRevision) -> Bool {
        let count: Int
        switch revision.kind {
        case .gitCommitSHA1: count = 40
        case .gitCommitSHA256: count = 64
        case .semanticVersion, .opaquePublisherRevision: return false
        }
        return revision.value.count == count && lowerHex(revision.value)
    }

    private static func validIntegrity(_ values: [SourceLockIntegrityEvidence]) -> Bool {
        guard Set(values.map(\.algorithm)).count == values.count else { return false }
        return values.allSatisfy { evidence in
            switch evidence.algorithm {
            case .githubSkillFolderTreeObjectID:
                [40, 64].contains(evidence.value.count) && lowerHex(evidence.value)
            case .vercelProjectSkillFolderSHA256V1:
                evidence.value.count == 64 && lowerHex(evidence.value)
            case .vercelGlobalSkillFolderHashOpaque, .vercelWellKnownOpaque:
                !evidence.value.isEmpty && evidence.value.count <= 512
                    && !evidence.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
        }
    }

    private static func lowerHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sortedIntegrity(_ values: [SourceLockIntegrityEvidence]) -> [SourceLockIntegrityEvidence] {
        Array(Set(values)).sorted {
            $0.algorithm == $1.algorithm ? $0.value < $1.value : $0.algorithm.rawValue < $1.algorithm.rawValue
        }
    }

    private static func uniqueCandidates(_ values: [SourceEvidenceCandidate]) -> [SourceEvidenceCandidate] {
        Array(Set(values)).sorted(by: candidateOrder)
    }

    private static func candidateOrder(_ lhs: SourceEvidenceCandidate, _ rhs: SourceEvidenceCandidate) -> Bool {
        let left = candidateKey(lhs)
        let right = candidateKey(rhs)
        if left != right { return left.lexicographicallyPrecedes(right) }
        // Opaque provider values may contain punctuation. Compare individual
        // fields rather than joining them with a delimiter that can collide.
        for (a, b) in zip(lhs.integrity, rhs.integrity) {
            if a.algorithm != b.algorithm { return a.algorithm.rawValue < b.algorithm.rawValue }
            if a.value != b.value { return a.value < b.value }
        }
        return lhs.integrity.count < rhs.integrity.count
    }

    private static func candidateKey(_ value: SourceEvidenceCandidate) -> [String] {
        [value.artifactID.rawValue.uuidString, value.repositoryURL, value.requestedRef, value.packagePath,
         value.observedCommit?.kind.rawValue ?? "", value.observedCommit?.value ?? ""]
    }

    private static func unresolvedOrder(_ lhs: SourceEvidenceUnresolved, _ rhs: SourceEvidenceUnresolved) -> Bool {
        lhs.artifactID == rhs.artifactID ? lhs.reason.rawValue < rhs.reason.rawValue : lhs.artifactID < rhs.artifactID
    }

    private static func sortedConflicts(_ values: [SourceEvidenceConflict]) -> [SourceEvidenceConflict] {
        values.map { conflict in
            var copy = conflict
            copy.alternatives.sort(by: candidateOrder)
            return copy
        }.sorted {
            $0.artifactID == $1.artifactID ? $0.kind.rawValue < $1.kind.rawValue : $0.artifactID < $1.artifactID
        }
    }

    private struct GroupKey: Hashable {
        var repositoryURL: String
        var requestedRef: String
    }

    private static func fetchGroups(_ candidates: [SourceEvidenceCandidate]) -> [SourceEvidenceFetchGroup] {
        Dictionary(grouping: candidates) {
            GroupKey(repositoryURL: $0.repositoryURL, requestedRef: $0.requestedRef)
        }.map { key, values in
            .init(
                repositoryURL: key.repositoryURL,
                requestedRef: key.requestedRef,
                artifactPaths: values.map { .init(artifactID: $0.artifactID, packagePath: $0.packagePath) }.sorted {
                    $0.artifactID == $1.artifactID ? $0.packagePath < $1.packagePath : $0.artifactID < $1.artifactID
                }
            )
        }.sorted {
            $0.repositoryURL == $1.repositoryURL
                ? $0.requestedRef < $1.requestedRef : $0.repositoryURL < $1.repositoryURL
        }
    }
}
