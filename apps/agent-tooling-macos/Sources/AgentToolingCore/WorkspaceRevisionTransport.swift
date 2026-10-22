import Foundation

/// Reads and publishes portable workspace documents with an expected-head
/// check. Merging and conflict decisions belong to WorkspaceSyncCoordinator.
/// Heads are opaque transport tokens, compared only for equality and passed
/// back unchanged; unexpected remote heads must never be overwritten.
public protocol WorkspaceRevisionTransport: Actor {
    /// What is there now. A `nil` head means nothing has been published yet —
    /// which is not the same as an empty workspace.
    func remoteState() async throws -> GitWorkspaceRemoteState

    /// Publishes on top of `expectedRemoteHead`. A transport that finds
    /// something else there must refuse rather than overwrite it, and say what
    /// it found so the caller can merge.
    ///
    /// `content` is the trees to add beside the document, each under its own
    /// digest; a tree already there is left alone. `status` is this device's
    /// own published summary, written only by the device it names. A transport
    /// that cannot carry content (the encrypted folder) ignores both and says
    /// so through `carriesContent`.
    func publish(
        document: PortableWorkspaceDocument,
        content: [CapturedPackageTree],
        status: PublishedDeviceStatus?,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt

    /// Reads one content tree the remote holds, verified against its digest.
    func content(for digest: ContentDigest) async throws -> CapturedPackageTree?

    /// Whether this transport carries content trees and device status at all.
    nonisolated var carriesContent: Bool { get }
}

public extension WorkspaceRevisionTransport {
    /// Document only: the call every pre-content caller makes.
    func publish(
        document: PortableWorkspaceDocument,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt {
        try await publish(document: document, content: [], status: nil, expectedRemoteHead: expectedRemoteHead)
    }
}

/// One Mac's summary of itself, written beside the document for the other Macs
/// to show. Small on purpose: what is installed per app and what is pending,
/// never paths outside a `~` abbreviation, never credentials, never receipts.
public struct PublishedDeviceStatus: Codable, Hashable, Sendable {
    public static let formatVersion = 1

    public struct AppSummary: Codable, Hashable, Sendable {
        public var surface: TargetSurface
        public var installed: Bool
        public var version: String?
        public var skillCount: Int
        public var pluginCount: Int
        public var mcpServerCount: Int
        public init(surface: TargetSurface, installed: Bool, version: String?, skillCount: Int, pluginCount: Int, mcpServerCount: Int) {
            self.surface = surface
            self.installed = installed
            self.version = version
            self.skillCount = skillCount
            self.pluginCount = pluginCount
            self.mcpServerCount = mcpServerCount
        }
    }

    public var formatVersion: Int
    public var deviceID: WorkspaceObjectID
    public var name: String
    public var lastScan: Date?
    public var publishedAt: Date
    public var apps: [AppSummary]
    /// Items assigned to this device that its last plan could not yet carry
    /// out, by display name.
    public var pending: [String]
    /// The revision this device held when it published.
    public var revisionID: WorkspaceObjectID
    /// How each client on this device signs in to its hosted account, and
    /// whether it follows the shared account choices. Absent from devices
    /// that published before accounts were read; an older reader ignores it.
    public var accounts: [PublishedAccountSummary]?

    public init(
        deviceID: WorkspaceObjectID, name: String, lastScan: Date?, publishedAt: Date = .now,
        apps: [AppSummary], pending: [String], revisionID: WorkspaceObjectID,
        accounts: [PublishedAccountSummary]? = nil
    ) {
        formatVersion = Self.formatVersion
        self.deviceID = deviceID
        self.name = name
        self.lastScan = lastScan
        self.publishedAt = publishedAt
        self.apps = apps
        self.pending = pending
        self.revisionID = revisionID
        self.accounts = (accounts?.isEmpty ?? true) ? nil : accounts
    }
}

extension GitWorkspaceTransport: WorkspaceRevisionTransport {}
