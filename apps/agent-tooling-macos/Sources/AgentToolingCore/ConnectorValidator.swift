import Foundation

struct ValidatedConnectorDraft: Sendable, Equatable {
    var name: String
    var provider: String
    var secretReferenceNames: [String]

    init(name: String, provider: String, secretReferenceNames: [String]) {
        self.name = name
        self.provider = provider
        self.secretReferenceNames = secretReferenceNames
    }
}

enum ConnectorValidator {
    static let maximumNameLength = 128
    static let maximumProviderLength = 128
    static let maximumSecretReferences = 64
    static let maximumSecretReferenceLength = 128

    static func validate(
        name: String,
        provider: String,
        target: TargetSurface,
        scope: ToolingScope,
        secretReferenceNames: [String]
    ) throws -> ValidatedConnectorDraft {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
            normalizedName.count <= maximumNameLength,
            !normalizedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ConnectorValidationError.invalidName
        }
        guard normalizedProvider.count <= maximumProviderLength,
            !normalizedProvider.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ConnectorValidationError.invalidProvider
        }
        let allowedScopes: Set<ToolingScope> =
            target.isCloud
            ? [.account, .managed]
            : ConfigurationValidator.editableScopes
        guard allowedScopes.contains(scope) else {
            throw ConnectorValidationError.incompatibleScope
        }
        guard secretReferenceNames.count <= maximumSecretReferences else {
            throw ConnectorValidationError.tooManySecretReferences
        }
        var referencesByKey: [String: String] = [:]
        for rawValue in secretReferenceNames {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard value.count <= maximumSecretReferenceLength,
                value.unicodeScalars.allSatisfy(isReferenceCharacter),
                SensitiveValueRedactor.redact(value) == value
            else {
                throw ConnectorValidationError.invalidSecretReference(value)
            }
            referencesByKey[value.lowercased()] = value
        }
        return ValidatedConnectorDraft(
            name: normalizedName,
            provider: normalizedProvider,
            secretReferenceNames: referencesByKey.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    private static func isReferenceCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
            || ["_", "-", ".", ":"].contains(Character(scalar))
    }
}

enum ConnectorValidationError: LocalizedError, Sendable {
    case invalidName
    case invalidProvider
    case incompatibleScope
    case tooManySecretReferences
    case invalidSecretReference(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Give the connection a name of at most 128 characters."
        case .invalidProvider:
            "The optional provider name must be at most 128 characters."
        case .incompatibleScope:
            "Choose an account scope for a hosted product or a local scope for an installed app."
        case .tooManySecretReferences:
            "Record at most 64 secret reference names."
        case .invalidSecretReference(let value):
            "Secret references must be names such as OPENAI_API_KEY, not secret values: \(value)"
        }
    }
}
