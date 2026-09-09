import Foundation

struct SkillAvailabilityKey: Hashable, Sendable {
    var skillID: String
    var client: ClientKind
}

struct SkillAvailabilityInput: Hashable, Sendable {
    var key: SkillAvailabilityKey
    var url: URL
    var setting: String
    var identifier: String
    var installedPath: String
    var providerPluginID: String?
}

/// Transient native preferences. Reading a view only consults these resolved values;
/// disk access and parsing happen once per settings file on the refresh worker.
struct SkillAvailabilitySnapshot: Sendable {
    var inputs: [SkillAvailabilityInput] = []
    var values: [SkillAvailabilityKey: Bool] = [:]

    static func inputs(
        skills: [Skill], observations: [TargetObservation], enabledClients: Set<ClientKind>, homeURL: URL
    ) -> [SkillAvailabilityInput] {
        var metadataByClient: [ClientKind: [String: ObservedSkillMetadata]] = [:]
        for observation in observations {
            guard let client = observation.surface.client, enabledClients.contains(client) else { continue }
            for (id, metadata) in observation.skillMetadata where metadataByClient[client]?[id] == nil {
                metadataByClient[client, default: [:]][id] = metadata
            }
        }
        var result: [SkillAvailabilityInput] = []
        for skill in skills {
            for state in skill.clients where state.reportsLocalPresence && enabledClients.contains(state.client) {
                guard let metadata = metadataByClient[state.client]?[skill.id] else { continue }
                let key = SkillAvailabilityKey(skillID: skill.id, client: state.client)
                let installedPath = URL(fileURLWithPath: metadata.path).standardizedFileURL.path
                switch state.client {
                case .codex:
                    result.append(
                        SkillAvailabilityInput(
                            key: key, url: homeURL.appending(path: ".codex/config.toml"), setting: "codex",
                            identifier: URL(fileURLWithPath: metadata.path).appending(path: "SKILL.md").path,
                            installedPath: installedPath, providerPluginID: metadata.providerPluginID))
                case .claude:
                    result.append(
                        SkillAvailabilityInput(
                            key: key, url: homeURL.appending(path: ".claude/settings.json"),
                            setting: metadata.providerPluginID == nil ? "skillOverrides" : "enabledPlugins",
                            identifier: metadata.providerPluginID ?? skill.name,
                            installedPath: installedPath, providerPluginID: metadata.providerPluginID))
                case .gemini:
                    break
                }
            }
        }
        return result
    }

    static func read(inputs: [SkillAvailabilityInput]) -> SkillAvailabilitySnapshot {
        var result = SkillAvailabilitySnapshot(inputs: inputs)
        for (url, fileInputs) in Dictionary(grouping: inputs, by: \.url) {
            guard let data = try? readFile(url) else { continue }
            if fileInputs.first?.setting == "codex" {
                guard let document = try? SkillAvailability.CodexDocument(String(decoding: data, as: UTF8.self)) else { continue }
                for input in fileInputs { result.values[input.key] = try? document.isEnabled(path: input.identifier) }
            } else {
                guard let document = try? SkillAvailability.JSONDocument(data) else { continue }
                for input in fileInputs {
                    result.values[input.key] = try? document.isEnabled(key: input.setting, identifier: input.identifier)
                }
            }
        }
        return result
    }

    static func readFile(_ url: URL) throws -> Data {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw SkillAvailability.Failure.unsupported("The native settings path is a symlink. Manage availability in the client instead.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        // Apply the existing limit before allocation and reject non-regular files.
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw SkillAvailability.Failure.unsupported("The native settings path is not a regular file.")
        }
        guard let size = values.fileSize, size >= 0, size <= 2_000_000 else {
            throw SkillAvailability.Failure.unsupported("The native settings file is too large to edit here.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_000_001) ?? Data()
        guard data.count == size, data.count <= 2_000_000 else {
            throw SkillAvailability.Failure.unsupported("Settings changed while being read. Try again.")
        }
        return data
    }
}
