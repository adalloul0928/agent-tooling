import AgentToolingCore
import CryptoKit
import Foundation

/// What an agent is asking a person to look at.
enum PendingRequestKind: String, Codable, CaseIterable, Sendable {
    case addMCPServer
    case createSkill
    case installSkill
    case installPlugin
    case removeComponent

    var displayName: String {
        switch self {
        case .addMCPServer: "Add an MCP server"
        case .createSkill: "Create a skill"
        case .installSkill: "Install a skill"
        case .installPlugin: "Install a plugin"
        case .removeComponent: "Remove a component"
        }
    }
}

/// The parts of a request that exist for the person doing the review and are
/// never returned to any MCP caller.
///
/// A project root is a home directory. An endpoint is a URL or a command line.
/// Both belong in the review sheet, next to the file they would change, and
/// neither belongs in an agent transcript — including the transcript of the
/// agent that supplied them, which may not be the one that reads them back.
struct PendingRequestReviewDetails: Codable, Hashable, Sendable {
    var projectRoot: String?
    var endpoint: String?
    var transport: String?
    var source: String?
    var instruction: String?
}

/// One bounded row in the review queue.
///
/// A row is a *description of a wish*, not an operation. It carries no command,
/// no digest, and no `OperationPlan`. The app composes the plan from its own
/// state when a person opens the review link, which is what keeps the reviewed
/// artifact out of the caller's hands.
struct PendingAgentRequest: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var kind: PendingRequestKind
    var title: String
    var summary: String
    var componentID: String?
    var scope: ToolingScope
    var targets: [ClientKind]
    var reason: String?
    /// For the in-app reviewer only. `PendingRequestResponses` never encodes it.
    var reviewDetails: PendingRequestReviewDetails
    var createdAt: Date
    var lastRequestedAt: Date
    /// How many times a caller asked for exactly this. A repeat collapses into
    /// this row instead of adding another, so one injected instruction cannot
    /// become twenty rows a person has to dismiss one at a time.
    var repeatCount: Int
    /// Self-reported client labels, display only. See `UntrustedClientIdentity`.
    var requestedByLabels: [String]
    /// Stable hash of the normalized request, used only to collapse duplicates.
    var fingerprint: String

    var reviewURL: String { "agent-tooling://requests/\(id.uuidString.lowercased())" }
}

/// The queue itself: an ordered, bounded list persisted beside the app's own
/// state so the app and this server see the same rows.
struct PendingAgentRequestQueue: Codable, Sendable {
    /// A person can only meaningfully review a short list. Past this point the
    /// server refuses new rows and says so.
    ///
    /// It refuses rather than evicting on purpose: evicting the oldest row
    /// would let a caller flush a request a person had not read yet by sending
    /// thirty-two of its own.
    static let maximumPendingRequests = 32

    var requests: [PendingAgentRequest] = []
}

enum PendingRequestQueueError: LocalizedError, Sendable {
    case queueFull(Int)

    var errorDescription: String? {
        switch self {
        case .queueFull(let maximum):
            "\(maximum) requests are already waiting for review. Open Agent Tooling and work through the queue before asking for more."
        }
    }
}

/// The outcome of appending. `collapsed` means an identical row already existed
/// and was reused.
struct PendingRequestOutcome: Sendable {
    var request: PendingAgentRequest
    var collapsed: Bool
}

extension WorkspaceStore {
    private static var pendingAgentRequestQueueKey: String { "agent-mcp.request-queue.v1" }

    func loadPendingAgentRequestQueue() throws -> PendingAgentRequestQueue {
        try load(Self.pendingAgentRequestQueueKey, as: PendingAgentRequestQueue.self) ?? PendingAgentRequestQueue()
    }

    func savePendingAgentRequestQueue(_ queue: PendingAgentRequestQueue) throws {
        try save(queue, for: Self.pendingAgentRequestQueueKey)
    }
}

enum PendingRequestQueueService {
    /// Appends one row, or reuses the existing row when an identical request is
    /// already waiting. Exactly one component per call; there is no bulk form.
    static func enqueue(
        kind: PendingRequestKind,
        title: String,
        summary: String,
        componentID: String?,
        scope: ToolingScope,
        targets: [ClientKind],
        reason: String?,
        reviewDetails: PendingRequestReviewDetails,
        fingerprintInputs: [String],
        client: UntrustedClientIdentity,
        store: WorkspaceStore,
        now: Date = .now,
        identifier: UUID = UUID()
    ) throws -> PendingRequestOutcome {
        let fingerprint = self.fingerprint(kind: kind, inputs: fingerprintInputs, scope: scope, targets: targets)
        var queue = try store.loadPendingAgentRequestQueue()

        if let index = queue.requests.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var existing = queue.requests[index]
            existing.lastRequestedAt = now
            existing.repeatCount += 1
            if !existing.requestedByLabels.contains(client.displayLabel), existing.requestedByLabels.count < 8 {
                existing.requestedByLabels.append(client.displayLabel)
            }
            queue.requests[index] = existing
            try store.savePendingAgentRequestQueue(queue)
            return PendingRequestOutcome(request: existing, collapsed: true)
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
            requestedByLabels: [client.displayLabel],
            fingerprint: fingerprint
        )
        queue.requests.append(request)
        try store.savePendingAgentRequestQueue(queue)
        return PendingRequestOutcome(request: request, collapsed: false)
    }

    /// Deliberately excludes timestamps and the self-reported client label: the
    /// same wish asked twice, or asked by two clients, is one thing for a
    /// person to decide.
    static func fingerprint(
        kind: PendingRequestKind,
        inputs: [String],
        scope: ToolingScope,
        targets: [ClientKind]
    ) -> String {
        let canonical =
            ([kind.rawValue, scope.rawValue] + targets.map(\.rawValue).sorted() + inputs)
            .joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
