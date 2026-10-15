import CryptoKit
import Foundation

/// The device registry's commands. Each one is a recorded change to the shared
/// document, so every Mac learns of it on the next pass.
///
/// A device's identity is its store's id; its name is for people. Registering
/// is idempotent on the id, so a Mac that registers twice is one row.
public struct RegisterDeviceCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let name: String
    public let receivesSharedAssignments: Bool

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        deviceID: WorkspaceObjectID, name: String, receivesSharedAssignments: Bool = true
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.deviceID = deviceID
        self.name = name
        self.receivesSharedAssignments = receivesSharedAssignments
    }

    func inputDigest() throws -> String { try deviceCommandDigest(self, operation: "register") }
}

public enum DeviceRegistryChange: Codable, Sendable, Equatable {
    case rename(String)
    case receivesSharedAssignments(Bool)
    case retire
    /// Stamped by the device itself; other Macs never write another's.
    case seen(Date)
}

public struct UpdateDeviceCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let change: DeviceRegistryChange

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        deviceID: WorkspaceObjectID, change: DeviceRegistryChange
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.deviceID = deviceID
        self.change = change
    }

    func inputDigest() throws -> String { try deviceCommandDigest(self, operation: "update") }
}

public enum DeviceRegistryError: Error, Equatable, Sendable, LocalizedError {
    case unknownDevice
    case nameInUse(by: String)
    case retired
    case cannotRetireSelf

    public var errorDescription: String? {
        switch self {
        case .unknownDevice: "That Mac is not in this workspace."
        case .nameInUse(let name): "Another Mac is already called \u{201C}\(name)\u{201D}. Choose a different name."
        case .retired: "That Mac was retired. Its record is kept for history and cannot be changed."
        case .cannotRetireSelf: "A Mac cannot retire itself. Retire it from another Mac, or disconnect it from sync here."
        }
    }
}

private func deviceCommandDigest<T: Encodable>(_ command: T, operation: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var bytes = Data("agent-tooling.device-\(operation).v1\n".utf8)
    bytes.append(try encoder.encode(command))
    return SHA256.hash(data: bytes).lowercaseHex
}

extension WorkspaceApplicationService {
    /// Adds this device to the registry, or refreshes its row. Names are unique
    /// among living devices; a retired device's name may be taken again only
    /// by explicit rename, never by registration.
    public func registerDevice(_ command: RegisterDeviceCommand) throws -> WorkspaceCommandReceipt {
        let digest = try command.inputDigest()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: digest,
            writerID: writerID
        ) { document in
            let name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try WorkspaceDomainValidation.requireText(name, field: "device.name", maximum: 256)
            var devices = document.deviceRegistry
            if let clash = devices.first(where: {
                $0.id != command.deviceID && !$0.isRetired && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                throw DeviceRegistryError.nameInUse(by: clash.name)
            }
            if let index = devices.firstIndex(where: { $0.id == command.deviceID }) {
                guard !devices[index].isRetired else { throw DeviceRegistryError.retired }
                devices[index].name = name
                devices[index].receivesSharedAssignments = command.receivesSharedAssignments
                devices[index].lastSeenAt = .now
            } else {
                devices.append(.init(
                    id: command.deviceID, name: name,
                    receivesSharedAssignments: command.receivesSharedAssignments,
                    registeredAt: .now, lastSeenAt: .now))
            }
            document.devices = devices
            return []
        }
    }

    public func updateDevice(_ command: UpdateDeviceCommand) throws -> WorkspaceCommandReceipt {
        let digest = try command.inputDigest()
        let selfID = store.deviceID
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: digest,
            writerID: writerID
        ) { document in
            var devices = document.deviceRegistry
            guard let index = devices.firstIndex(where: { $0.id == command.deviceID }) else {
                throw DeviceRegistryError.unknownDevice
            }
            switch command.change {
            case .rename(let raw):
                guard !devices[index].isRetired else { throw DeviceRegistryError.retired }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                try WorkspaceDomainValidation.requireText(name, field: "device.name", maximum: 256)
                if let clash = devices.first(where: {
                    $0.id != command.deviceID && !$0.isRetired && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    throw DeviceRegistryError.nameInUse(by: clash.name)
                }
                devices[index].name = name
            case .receivesSharedAssignments(let value):
                guard !devices[index].isRetired else { throw DeviceRegistryError.retired }
                devices[index].receivesSharedAssignments = value
            case .retire:
                guard command.deviceID != selfID else { throw DeviceRegistryError.cannotRetireSelf }
                if devices[index].retiredAt == nil { devices[index].retiredAt = .now }
            case .seen(let date):
                devices[index].lastSeenAt = date
            }
            document.devices = devices
            return []
        }
    }
}

/// Changes which Macs a shared ("every Mac") assignment leaves out. Only a
/// shared destination has exclusions; one that names Macs is edited by
/// re-assigning. The merge treats exclusions as a set, so two Macs adding
/// different exceptions apart both land.
public struct SetAssignmentExclusionsCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let contributionID: WorkspaceObjectID
    public let excludedDeviceIDs: [WorkspaceObjectID]

    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        contributionID: WorkspaceObjectID, excludedDeviceIDs: [WorkspaceObjectID]
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.contributionID = contributionID
        self.excludedDeviceIDs = excludedDeviceIDs
    }

    func inputDigest() throws -> String { try deviceCommandDigest(self, operation: "exclusions") }
}

extension WorkspaceApplicationService {
    public func setAssignmentExclusions(_ command: SetAssignmentExclusionsCommand) throws -> WorkspaceCommandReceipt {
        let digest = try command.inputDigest()
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: digest,
            writerID: writerID
        ) { document in
            guard let index = document.assignments.firstIndex(where: { $0.id == command.contributionID }) else {
                throw WorkspaceAssignmentCommandError.missingContribution
            }
            guard document.assignments[index].destination.deviceIDs == nil else {
                throw WorkspaceAssignmentCommandError.unsupportedReason
            }
            let known = Set(document.deviceRegistry.map(\.id))
            let excluded = Array(Set(command.excludedDeviceIDs).filter(known.contains)).sorted()
            document.assignments[index].destination.excludedDeviceIDs = excluded.isEmpty ? nil : excluded
            return [document.assignments[index].artifactID]
        }
    }
}
