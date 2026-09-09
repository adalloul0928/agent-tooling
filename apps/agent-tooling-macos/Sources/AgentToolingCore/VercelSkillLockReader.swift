import CoreFoundation
import Foundation

public enum VercelSkillLockReader {
    public static let maximumBytes = 4 * 1_024 * 1_024
    public static let globalVersion = 3
    public static let projectVersion = 1

    public static func globalContext(homeDirectory: String, xdgStateHome: String? = nil) throws -> SourceLockContext {
        let explicitXDG = xdgStateHome.flatMap { $0.isEmpty ? nil : $0 }
        try requireAbsoluteNormalized(homeDirectory)
        let root = explicitXDG ?? append(".agents", to: homeDirectory)
        try requireAbsoluteNormalized(root)
        let path = explicitXDG == nil
            ? append(".skill-lock.json", to: root)
            : append(".skill-lock.json", to: append("skills", to: root))
        return .global(lockFilePath: path)
    }

    public static func projectContext(projectRoot: String) throws -> SourceLockContext {
        try requireAbsoluteNormalized(projectRoot)
        return .project(lockFilePath: append("skills-lock.json", to: projectRoot), projectRoot: projectRoot)
    }

    public static func read(bytes: Data, context: SourceLockContext) -> SourceLockReadResult {
        let format = context.format
        guard isValid(context: context) else {
            return SourceLockReadResult(
                format: format, schemaVersion: nil, status: .malformed,
                diagnostics: [.init(code: .invalidContext)])
        }
        guard bytes.count <= maximumBytes else {
            return SourceLockReadResult(
                format: format, schemaVersion: nil, status: .malformed,
                diagnostics: [.init(code: .documentTooLarge)])
        }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) else {
            return SourceLockReadResult(
                format: format, schemaVersion: nil, status: .malformed,
                diagnostics: [.init(code: .malformedJSON)])
        }
        guard let root = object as? [String: Any] else {
            return SourceLockReadResult(
                format: format, schemaVersion: nil, status: .malformed,
                diagnostics: [.init(code: .invalidRoot)])
        }
        guard let version = integer(root["version"]) else {
            return SourceLockReadResult(
                format: format, schemaVersion: nil, status: .malformed,
                diagnostics: [.init(code: .invalidRoot, field: "version")])
        }
        let expected = format == .vercelGlobal ? globalVersion : projectVersion
        guard version == expected else {
            return SourceLockReadResult(
                format: format, schemaVersion: version, status: .unsupportedVersion,
                diagnostics: [.init(code: .unsupportedVersion, field: "version")])
        }
        guard let skills = root["skills"] as? [String: Any] else {
            return SourceLockReadResult(
                format: format, schemaVersion: version, status: .malformed,
                diagnostics: [.init(code: .invalidSkillsMap, field: "skills")])
        }

        var evidence: [SourceLockEvidence] = []
        var diagnostics: [SourceLockDiagnostic] = []
        for name in skills.keys.sorted() {
            guard isSafeText(name, maximum: 512), let entry = skills[name] as? [String: Any] else {
                diagnostics.append(.init(code: .invalidEntry, field: "skills entry"))
                continue
            }
            if let parsed = parse(name: name, entry: entry, context: context, diagnostics: &diagnostics) {
                evidence.append(parsed)
            }
        }
        return SourceLockReadResult(
            format: format, schemaVersion: version, status: .recognized,
            evidence: evidence, diagnostics: diagnostics)
    }

    private static func parse(
        name: String,
        entry: [String: Any],
        context: SourceLockContext,
        diagnostics: inout [SourceLockDiagnostic]
    ) -> SourceLockEvidence? {
        guard let source = safeString(entry["source"], maximum: 4_096),
            let sourceType = safeString(entry["sourceType"], maximum: 128)
        else {
            diagnostics.append(.init(code: .invalidEntry, skillNameHint: name, field: "source/sourceType"))
            return nil
        }

        var gaps: [SourceEvidenceGap] = []
        let sourceURL = safeString(entry["sourceUrl"], maximum: 4_096)
        let baseURL = safeString(entry["sourceBaseUrl"], maximum: 4_096)
        let locator: SourceLockLocator
        if unsafeRemoteLocator(source) || sourceURL.map(unsafeRemoteLocator) == true
            || baseURL.map(unsafeRemoteLocator) == true
        {
            locator = .unavailable(sourceType: sourceType)
            gaps.append(.invalidLocator)
            diagnostics.append(.init(code: .invalidLocator, skillNameHint: name, field: "source locator"))
        } else if sourceType == "local" {
            let resolved = resolveLocal(source, context: context)
            locator = .deviceLocal(originalPath: source, resolvedPath: resolved)
            gaps.append(.deviceLocalOnly)
            if resolved == nil { gaps.append(.invalidLocator) }
        } else {
            let validURL = sourceURL.flatMap(credentialFreeHTTPS)
            let validBaseURL = baseURL.flatMap(credentialFreeHTTPS)
            if context.format == .vercelGlobal, sourceURL == nil {
                gaps.append(.invalidLocator)
                diagnostics.append(.init(code: .invalidLocator, skillNameHint: name, field: "sourceUrl"))
            } else if sourceURL != nil, validURL == nil {
                gaps.append(.invalidLocator)
                diagnostics.append(.init(code: .invalidLocator, skillNameHint: name, field: "sourceUrl"))
            }
            if baseURL != nil, validBaseURL == nil {
                gaps.append(.invalidLocator)
                diagnostics.append(.init(code: .invalidLocator, skillNameHint: name, field: "sourceBaseUrl"))
            }
            locator = .remote(
                repositoryID: source,
                sourceType: sourceType,
                repositoryURL: validURL,
                baseURL: validBaseURL)
        }

        let requestedRef = safeString(entry["ref"], maximum: 256)
        if requestedRef == nil { gaps.append(.missingRequestedRef) }
        let revision = requestedRef.map(SourceLockRevisionEvidence.requestedRef)

        var skillPath: String?
        if let rawPath = safeString(entry["skillPath"], maximum: 4_096) {
            if isPortablePath(rawPath) {
                skillPath = rawPath
            } else {
                gaps.append(.invalidSkillPath)
                diagnostics.append(.init(code: .invalidSkillPath, skillNameHint: name, field: "skillPath"))
            }
        } else {
            gaps.append(.missingSkillPath)
        }

        var integrity: [SourceLockIntegrityEvidence] = []
        let primaryField = context.format == .vercelGlobal ? "skillFolderHash" : "computedHash"
        if let digest = safeString(entry[primaryField], maximum: 128) {
            if context.format == .vercelProject, isLowerHex(digest, count: 64) {
                integrity.append(.init(algorithm: .vercelProjectSkillFolderSHA256V1, value: digest))
            } else if context.format == .vercelGlobal, sourceType == "github", isGitObjectID(digest) {
                integrity.append(.init(algorithm: .githubSkillFolderTreeObjectID, value: digest))
            } else if context.format == .vercelGlobal, sourceType != "github", isOpaqueDigest(digest) {
                integrity.append(.init(algorithm: .vercelGlobalSkillFolderHashOpaque, value: digest))
            } else {
                gaps.append(.invalidIntegrity)
                diagnostics.append(.init(code: .invalidIntegrity, skillNameHint: name, field: primaryField))
            }
        } else {
            gaps.append(.invalidIntegrity)
            diagnostics.append(.init(code: .invalidIntegrity, skillNameHint: name, field: primaryField))
        }
        if let wellKnown = safeString(entry["wellKnownDigest"], maximum: 256), isOpaqueDigest(wellKnown) {
            integrity.append(.init(algorithm: .vercelWellKnownOpaque, value: wellKnown))
        }

        let rawInstalledAt = safeString(entry["installedAt"], maximum: 64)
        let rawUpdatedAt = safeString(entry["updatedAt"], maximum: 64)
        let observation = SourceLockObservation(
            installedAt: rawInstalledAt.flatMap { isISO8601($0) ? $0 : nil },
            updatedAt: rawUpdatedAt.flatMap { isISO8601($0) ? $0 : nil },
            pluginNameHint: safeString(entry["pluginName"], maximum: 512),
            subagentHints: safeStringArray(entry["subagents"], maximumCount: 256, maximumLength: 512))
        if context.format == .vercelGlobal,
            observation.installedAt == nil || observation.updatedAt == nil
        {
            diagnostics.append(.init(code: .invalidObservation, skillNameHint: name, field: "timestamps"))
        }
        return SourceLockEvidence(
            skillNameHint: name, locator: locator, revision: revision, skillPath: skillPath,
            integrity: integrity, observation: observation,
            gaps: Array(Set(gaps)).sorted { $0.rawValue < $1.rawValue })
    }

    private static func resolveLocal(_ path: String, context: SourceLockContext) -> String? {
        if path.hasPrefix("/") { return normalizedAbsolute(path) }
        guard case .project(_, let root) = context else { return nil }
        return normalizedAbsolute(root + "/" + path)
    }

    private static func normalizedAbsolute(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func requireAbsoluteNormalized(_ path: String) throws {
        guard normalizedAbsolute(path) == path else {
            throw WorkspaceDomainValidationError.invalidField("source lock context")
        }
    }

    private static func credentialFreeHTTPS(_ value: String) -> String? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
            parts.host != nil, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        return value
    }

    private static func unsafeRemoteLocator(_ value: String) -> Bool {
        if value.contains("?") || value.contains("#") { return true }
        guard value.contains("://") else { return false }
        guard let parts = URLComponents(string: value), parts.scheme != nil, parts.host != nil else { return true }
        return parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil
    }

    private static func isValid(context: SourceLockContext) -> Bool {
        switch context {
        case .global(let path):
            return normalizedAbsolute(path) == path
                && (path.hasSuffix("/.agents/.skill-lock.json") || path.hasSuffix("/skills/.skill-lock.json"))
        case .project(let path, let root):
            return normalizedAbsolute(root) == root && path == append("skills-lock.json", to: root)
        }
    }

    private static func append(_ component: String, to root: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(component).path
    }

    private static func isPortablePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
            && value.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        return number.doubleValue == Double(integer) ? integer : nil
    }

    private static func safeString(_ value: Any?, maximum: Int) -> String? {
        guard let string = value as? String, isSafeText(string, maximum: maximum) else { return nil }
        return string
    }

    private static func safeStringArray(_ value: Any?, maximumCount: Int, maximumLength: Int) -> [String] {
        guard let array = value as? [Any], array.count <= maximumCount else { return [] }
        let strings = array.compactMap { safeString($0, maximum: maximumLength) }
        return strings.count == array.count ? strings : []
    }

    private static func isSafeText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        isLowerHex(value, count: 40) || isLowerHex(value, count: 64)
    }

    private static func isOpaqueDigest(_ value: String) -> Bool {
        isSafeText(value, maximum: 256) && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }

    private static func isISO8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
}
