import CryptoKit
import Foundation

/// A bounded, review-only request written by an untrusted local integration.
public enum PendingRequestKind: String, Codable, CaseIterable, Sendable {
    case addMCPServer
    case createSkill
    case installSkill
    case installPlugin
    case removeComponent

    public var displayName: String {
        switch self {
        case .addMCPServer: "Add an MCP server"
        case .createSkill: "Create a skill"
        case .installSkill: "Install a skill"
        case .installPlugin: "Install a plugin"
        case .removeComponent: "Remove a component"
        }
    }
}

/// Sensitive request fields stay local to the review UI and are never included
/// in MCP list/get responses.
public struct PendingRequestReviewDetails: Codable, Hashable, Sendable {
    public var projectRoot: String?
    public var endpoint: String?
    public var transport: String?
    public var source: String?
    public var instruction: String?
    public var componentKind: String?

    public init(
        projectRoot: String? = nil,
        endpoint: String? = nil,
        transport: String? = nil,
        source: String? = nil,
        instruction: String? = nil,
        componentKind: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.endpoint = endpoint
        self.transport = transport
        self.source = source
        self.instruction = instruction
        self.componentKind = componentKind
    }
}

public struct PendingAgentRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: PendingRequestKind
    public var title: String
    public var summary: String
    public var componentID: String?
    public var scope: ToolingScope
    public var targets: [ClientKind]
    public var reason: String?
    public var reviewDetails: PendingRequestReviewDetails
    public var createdAt: Date
    public var lastRequestedAt: Date
    public var repeatCount: Int
    public var requestedByLabels: [String]
    public var fingerprint: String

    public var reviewURL: String { "agent-tooling://requests/\(id.uuidString.lowercased())" }
}

public struct PendingAgentRequestQueue: Codable, Sendable {
    /// Admission is bounded globally and by the row's original creation time.
    /// `requestedByLabels` is self-reported display text, so it deliberately
    /// does not grant capacity or act as a per-client security identity.
    public static let maximumPendingRequests = 32
    public static let maximumPendingAge: TimeInterval = 30 * 24 * 60 * 60

    public var requests: [PendingAgentRequest]

    public init(requests: [PendingAgentRequest] = []) {
        self.requests = requests
    }
}

public enum PendingRequestQueueError: LocalizedError, Sendable, Equatable {
    case queueFull(Int)
    case requestConflict

    public var errorDescription: String? {
        switch self {
        case .queueFull(let maximum):
            "\(maximum) requests are already waiting for review. Open Agent Tooling and work through the queue before asking for more."
        case .requestConflict:
            "A different request already uses this review identifier. Close this review and open the current queue entry."
        }
    }
}

public struct PendingRequestOutcome: Sendable {
    public var request: PendingAgentRequest
    public var collapsed: Bool
}

extension WorkspaceStore {
    private static var pendingAgentRequestQueueKey: String { "agent-mcp.request-queue.v1" }

    public func loadPendingAgentRequestQueue() throws -> PendingAgentRequestQueue {
        try load(Self.pendingAgentRequestQueueKey, as: PendingAgentRequestQueue.self) ?? PendingAgentRequestQueue()
    }

    public func savePendingAgentRequestQueue(_ queue: PendingAgentRequestQueue) throws {
        try save(queue, for: Self.pendingAgentRequestQueueKey)
    }
}

public enum PendingRequestQueueService {
    public static func enqueue(
        kind: PendingRequestKind,
        title: String,
        summary: String,
        componentID: String?,
        scope: ToolingScope,
        targets: [ClientKind],
        reason: String?,
        reviewDetails: PendingRequestReviewDetails,
        fingerprintInputs: [String],
        clientLabel: String,
        store: WorkspaceStore,
        now: Date = .now,
        identifier: UUID = UUID()
    ) throws -> PendingRequestOutcome {
        let fingerprint = self.fingerprint(kind: kind, inputs: fingerprintInputs, scope: scope, targets: targets)
        let result: (PendingRequestOutcome, [UUID]) = try store.updatePendingAgentRequestQueue { queue in
            let expired = queue.requests.filter {
                now.timeIntervalSince($0.createdAt) > PendingAgentRequestQueue.maximumPendingAge
            }
            queue.requests.removeAll { request in expired.contains(where: { $0.id == request.id }) }

            if let index = queue.requests.firstIndex(where: { $0.fingerprint == fingerprint }) {
                var existing = queue.requests[index]
                existing.lastRequestedAt = now
                if existing.repeatCount < Int.max { existing.repeatCount += 1 }
                if !existing.requestedByLabels.contains(clientLabel), existing.requestedByLabels.count < 8 {
                    existing.requestedByLabels.append(clientLabel)
                }
                queue.requests[index] = existing
                return (PendingRequestOutcome(request: existing, collapsed: true), expired.filter { $0.kind == .createSkill }.map(\.id))
            }

            guard queue.requests.count < PendingAgentRequestQueue.maximumPendingRequests else {
                throw PendingRequestQueueError.queueFull(PendingAgentRequestQueue.maximumPendingRequests)
            }

            let request = PendingAgentRequest(
                id: identifier,
                kind: kind,
                title: title,
                summary: summary,
                componentID: componentID,
                scope: scope,
                targets: targets,
                reason: reason,
                reviewDetails: reviewDetails,
                createdAt: now,
                lastRequestedAt: now,
                repeatCount: 1,
                requestedByLabels: [clientLabel],
                fingerprint: fingerprint
            )
            queue.requests.append(request)
            return (PendingRequestOutcome(request: request, collapsed: false), expired.filter { $0.kind == .createSkill }.map(\.id))
        }
        for id in result.1 { try? store.deleteCodexSkillDraftRequest(id: id) }
        return result.0
    }

    /// Atomically removes one decision from the persisted queue. The returned
    /// row is the exact artifact the app approved or rejected.
    @discardableResult
    public static func resolve(
        id: UUID,
        expectedFingerprint: String,
        store: WorkspaceStore
    ) throws -> PendingAgentRequest? {
        try store.updatePendingAgentRequestQueue { queue in
            guard let index = queue.requests.firstIndex(where: { $0.id == id }) else { return nil }
            guard queue.requests[index].fingerprint == expectedFingerprint else {
                throw PendingRequestQueueError.requestConflict
            }
            return queue.requests.remove(at: index)
        }
    }

    /// Restores an app-claimed row when app-owned validation or plan building
    /// fails. The same admission limits still apply, so this cannot be used as
    /// an unbounded side door into the queue.
    @discardableResult
    public static func restore(_ request: PendingAgentRequest, store: WorkspaceStore) throws -> PendingAgentRequest {
        try store.updatePendingAgentRequestQueue { queue in
            if let existing = queue.requests.first(where: { $0.id == request.id }) {
                guard existing.fingerprint == request.fingerprint else {
                    throw PendingRequestQueueError.requestConflict
                }
                return existing
            }
            if let duplicate = queue.requests.first(where: { $0.fingerprint == request.fingerprint }) {
                return duplicate
            }
            guard queue.requests.count < PendingAgentRequestQueue.maximumPendingRequests else {
                throw PendingRequestQueueError.queueFull(PendingAgentRequestQueue.maximumPendingRequests)
            }
            queue.requests.append(request)
            queue.requests.sort { $0.createdAt < $1.createdAt }
            return request
        }
    }

    public static func request(id: UUID, store: WorkspaceStore) throws -> PendingAgentRequest? {
        try pendingRequests(store: store).first { $0.id == id }
    }

    /// Returns the current queue while transactionally removing rows whose
    /// original review window has expired. This gives the app and read-only MCP
    /// surface the same lifecycle view even when no new request is arriving.
    public static func pendingRequests(
        store: WorkspaceStore,
        now: Date = .now
    ) throws -> [PendingAgentRequest] {
        let result: ([PendingAgentRequest], [UUID]) = try store.updatePendingAgentRequestQueue { queue in
            let expired = queue.requests.filter {
                now.timeIntervalSince($0.createdAt) > PendingAgentRequestQueue.maximumPendingAge
            }
            queue.requests.removeAll { request in expired.contains(where: { $0.id == request.id }) }
            queue.requests.sort {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt < $1.createdAt
            }
            return (queue.requests, expired.filter { $0.kind == .createSkill }.map(\.id))
        }
        for id in result.1 { try? store.deleteCodexSkillDraftRequest(id: id) }
        return result.0
    }

    public static func fingerprint(
        kind: PendingRequestKind,
        inputs: [String],
        scope: ToolingScope,
        targets: [ClientKind]
    ) -> String {
        let canonical = ([kind.rawValue, scope.rawValue] + targets.map(\.rawValue).sorted() + inputs)
            .joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
