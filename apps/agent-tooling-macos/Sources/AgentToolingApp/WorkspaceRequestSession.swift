import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// The persisted review queue, behind a protocol.
///
/// Reading it opens this Mac's store and rewrites the queue when a row's review
/// window has closed, so a render test has to be able to hand in something that
/// does neither.
protocol PendingRequestQueuing: Sendable {
    func pendingRequests(store: WorkspaceRevisionStore) throws -> [PendingAgentRequest]
    func resolve(id: UUID, expectedFingerprint: String, store: WorkspaceRevisionStore) throws
        -> PendingAgentRequest?
    func restore(_ request: PendingAgentRequest, store: WorkspaceRevisionStore) throws
}

/// The real queue. Every rule about admission, collapsing and expiry lives in
/// the core service; this only carries the calls across.
struct LivePendingRequestQueue: PendingRequestQueuing {
    func pendingRequests(store: WorkspaceRevisionStore) throws -> [PendingAgentRequest] {
        try PendingRequestQueueService.pendingRequests(store: store)
    }

    func resolve(id: UUID, expectedFingerprint: String, store: WorkspaceRevisionStore) throws
        -> PendingAgentRequest?
    {
        try PendingRequestQueueService.resolve(
            id: id, expectedFingerprint: expectedFingerprint, store: store)
    }

    func restore(_ request: PendingAgentRequest, store: WorkspaceRevisionStore) throws {
        _ = try PendingRequestQueueService.restore(request, store: store)
    }
}

extension EnvironmentValues {
    @Entry var pendingRequestQueue: any PendingRequestQueuing = LivePendingRequestQueue()
}

/// What a local integration asked Agent Tooling to do, and what happens when
/// somebody says yes.
///
/// Every row here is untrusted local input. Nothing in the queue has changed a
/// client, and accepting one still changes no client: it turns a wish into
/// assignment intent this Mac holds, which somebody then installs as the
/// separate, reviewed step this screen is built around.
///
/// Accepting never creates a library item. A request naming something that is
/// not in the library resolves to nothing to assign, so it is refused and put
/// back rather than admitted as a new tool nobody wrote down.
@MainActor @Observable
final class WorkspaceRequestSession {
    /// What accepting a request produced, in the caller's terms.
    enum Acceptance: Equatable {
        /// Intent was saved and there is a deployment to review.
        case assignmentSaved
        /// Nothing was saved and the request is still in the queue.
        case refused(String)
    }

    private(set) var requests: [PendingAgentRequest] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private let access: QueueAccess
    private let library: WorkspaceLibrarySession
    private let device: WorkspaceDeviceSession

    init(
        store: WorkspaceRevisionStore,
        library: WorkspaceLibrarySession,
        device: WorkspaceDeviceSession,
        queue: any PendingRequestQueuing = LivePendingRequestQueue()
    ) {
        access = QueueAccess(store: store, queue: queue)
        self.library = library
        self.device = device
    }

    /// Re-reads the queue. Opening the store and expiring old rows is work, so
    /// it happens off this actor and the screen that asked keeps drawing.
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            requests = try await access.pending()
        } catch {
            // The last read is still the truest thing known about the queue, so
            // it stays on screen rather than being replaced by nothing.
            errorMessage =
                requests.isEmpty
                ? "The review queue could not be opened."
                : "The review queue could not be read again. What is shown is the last read."
        }
    }

    /// One row, re-read, so a review always opens the current entry rather than
    /// whatever was on screen when somebody clicked.
    func request(id: UUID) async -> PendingAgentRequest? {
        await refresh()
        guard let request = requests.first(where: { $0.id == id }) else {
            errorMessage = "That request is no longer waiting for review."
            return nil
        }
        return request
    }

    /// Removes one row without changing any client.
    @discardableResult
    func reject(_ request: PendingAgentRequest) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        let id = request.id
        do {
            let resolved = try await access.claim(id: id, fingerprint: request.fingerprint)
            guard resolved != nil else {
                errorMessage = "That request is no longer waiting for review."
                await reload()
                return false
            }
            // A request whose review window closed takes its draft with it; so
            // does one a person decided against.
            await access.discardDraft(id)
            requests.removeAll { $0.id == id }
            return true
        } catch PendingRequestQueueError.requestConflict {
            errorMessage =
                "That request changed after you opened it. Nothing was rejected; reopen the current queue entry."
            await reload()
            return false
        } catch {
            errorMessage = "The request could not be removed from the queue."
            return false
        }
    }

    /// Turns an untrusted wish into assignment intent this Mac holds.
    ///
    /// The row is claimed out of the queue first, so two windows cannot approve
    /// the same request twice; anything that then fails puts it back exactly as
    /// it was. No client is written here, and nothing this returns is an install.
    func accept(_ request: PendingAgentRequest) async -> Acceptance {
        guard !isBusy else { return .refused("Another decision is still being saved.") }
        errorMessage = nil
        guard library.access == .writable else {
            return refuse("This session cannot save changes, so nothing was approved.")
        }
        if let reason = PendingRequestEnvelope.rejection(for: request) {
            return refuse(reason)
        }
        let unmanaged = request.targets.filter { !device.isEnabled($0) }
        if !unmanaged.isEmpty {
            let names = unmanaged.map(\.rawValue).sorted().joined(separator: ", ")
            return refuse(
                "This Mac is not managing \(names). Turn that on in Choose apps first; nothing was approved.")
        }
        // Resolving the request against the library happens before the row is
        // claimed, so a request that resolves to nothing never leaves the queue.
        let intent = resolve(request)
        if case .refused(let reason) = intent { return refuse(reason) }

        isBusy = true
        defer { isBusy = false }
        let id = request.id
        let claimed: PendingAgentRequest
        do {
            guard let current = try await access.claim(id: id, fingerprint: request.fingerprint)
            else {
                await reload()
                return refuse("That request changed while it was being reviewed. Nothing was approved.")
            }
            guard current.fingerprint == request.fingerprint,
                PendingRequestEnvelope.rejection(for: current) == nil
            else {
                try? await access.restore(current)
                await reload()
                return refuse(
                    "That request changed while it was being reviewed. Nothing was approved; reopen the current queue entry."
                )
            }
            claimed = current
            requests.removeAll { $0.id == id }
        } catch PendingRequestQueueError.requestConflict {
            await reload()
            return refuse(
                "That request changed after you opened it. Nothing was approved; reopen the current queue entry.")
        } catch {
            return refuse("The request decision could not be saved.")
        }

        switch intent {
        case .assign(let artifactID, let destinations):
            await library.reviewAssignments(artifactIDs: [artifactID], destinations: destinations)
        case .withdraw(let contributionIDs):
            await library.reviewRemoval(contributionIDs: contributionIDs)
        case .refused(let reason):
            return await putBack(claimed, because: reason)
        }
        guard library.review != nil else {
            return await putBack(claimed, because: library.errorMessage)
        }
        await library.applyReviewedAssignments()
        guard library.lastReceipt != nil else {
            library.discardReview()
            return await putBack(claimed, because: library.errorMessage)
        }
        await access.discardDraft(claimed.id)
        return .assignmentSaved
    }

    // MARK: - Resolution

    /// What accepting one request would ask the library to record, or the
    /// reason it would ask for nothing.
    private enum RequestedIntent {
        case assign(ArtifactID, [PortableDestination])
        case withdraw([WorkspaceObjectID])
        case refused(String)
    }

    /// Matches an untrusted name against the library, and refuses anything that
    /// does not land on exactly one row this Mac is allowed to assign.
    private func resolve(_ request: PendingAgentRequest) -> RequestedIntent {
        guard let model = library.state?.library else {
            return .refused("The library has not been read yet. Nothing was approved.")
        }
        guard let identifier = request.componentID, !identifier.isEmpty else {
            return .refused("The request does not name anything. Nothing was approved.")
        }
        let wanted = kind(for: request)
        let matches = model.rows.filter { row in
            guard wanted == nil || wanted?.contains(row.kind) == true else { return false }
            return row.artifactID.rawValue.uuidString.lowercased() == identifier.lowercased()
                || row.displayName.localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }
        guard matches.count == 1, let row = matches.first else {
            return .refused(
                matches.isEmpty
                    ? "\(identifier) is not in your library, and approving a request never adds one. Add it yourself first, then review this request again."
                    : "\(identifier) matches more than one item in your library. Open the item you mean and assign it there."
            )
        }
        switch request.kind {
        case .removeComponent:
            let contributions = row.requestedAssignments.filter { assignment in
                guard let client = assignment.destination.surface.client else { return false }
                return request.targets.contains(client) && assignment.destination.scope == request.scope
            }
            guard !contributions.isEmpty else {
                return .refused(
                    "\(row.displayName) is not asked for in \(request.targets.map(\.rawValue).sorted().joined(separator: ", ")), so there is nothing to withdraw."
                )
            }
            return .withdraw(contributions.map(\.id))
        case .addMCPServer, .installSkill, .installPlugin, .createSkill:
            guard row.isAssignable else {
                return .refused(
                    row.assignmentExplanation
                        ?? "\(row.displayName) cannot be assigned from here. Nothing was approved.")
            }
            let destinations = request.targets.sorted { $0.rawValue < $1.rawValue }.map { client in
                PortableDestination(
                    surface: surface(client), scope: request.scope,
                    logicalProjectID: nil, deviceIDs: [library.deviceID])
            }
            return .assign(row.artifactID, destinations)
        }
    }

    /// Which library rows a request is even allowed to land on. A request to
    /// add a connection cannot be talked into assigning a plugin.
    private func kind(for request: PendingAgentRequest) -> Set<ArtifactKind>? {
        switch request.kind {
        case .addMCPServer: [.mcpServer]
        case .installSkill: [.skill]
        case .installPlugin: [.nativePlugin, .package]
        case .createSkill: [.skill]
        case .removeComponent:
            switch request.reviewDetails.componentKind {
            case "skill": [.skill]
            case "mcp-server": [.mcpServer]
            case "plugin": [.nativePlugin, .package]
            default: nil
            }
        }
    }

    private func surface(_ client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    // MARK: - Recovery

    /// Puts a claimed row back and says what went wrong, so a failed approval
    /// leaves the queue exactly as it found it.
    private func putBack(_ request: PendingAgentRequest, because message: String?) async -> Acceptance {
        let reason = message ?? "Agent Tooling could not record what this request asked for."
        do {
            try await access.restore(request)
            await reload()
            return refuse(reason + " The request is still waiting for review.")
        } catch {
            await reload()
            return refuse(reason + " The request could not be put back in the queue either.")
        }
    }

    /// Re-reads the queue from inside a decision, without taking the busy guard
    /// that decision already holds.
    private func reload() async {
        guard let current = try? await access.pending() else { return }
        requests = current
    }

    /// The queue calls, off the main actor.
    ///
    /// Each one opens this Mac's store, and one of them rewrites it, so none of
    /// them belongs on the actor a window draws from.
    private struct QueueAccess: Sendable {
        let store: WorkspaceRevisionStore
        let queue: any PendingRequestQueuing

        func pending() async throws -> [PendingAgentRequest] {
            let store = store
            let queue = queue
            return try await Task.detached { try queue.pendingRequests(store: store) }.value
        }

        /// Takes one row out of the queue, so nothing else can decide it too.
        func claim(id: UUID, fingerprint: String) async throws -> PendingAgentRequest? {
            let store = store
            let queue = queue
            return try await Task.detached {
                try queue.resolve(id: id, expectedFingerprint: fingerprint, store: store)
            }.value
        }

        func restore(_ request: PendingAgentRequest) async throws {
            let store = store
            let queue = queue
            try await Task.detached { try queue.restore(request, store: store) }.value
        }

        /// A draft with no row is a payload nothing can ever open.
        func discardDraft(_ id: UUID) async {
            let store = store
            await Task.detached { try? store.deleteRequestDraft(id) }.value
        }
    }

    private func refuse(_ message: String) -> Acceptance {
        errorMessage = message
        return .refused(message)
    }
}

/// Whether one queue row is well formed enough to act on.
///
/// This is the boundary a local integration writes across, so every field is
/// checked against the fingerprint it was admitted under before anything reads
/// it as a name, a scope or a path. A row that fails is shown and rejected, not
/// repaired: the app has no way to know what the requester meant.
enum PendingRequestEnvelope {
    /// The reason this request cannot be approved, or nil when it can.
    static func rejection(for request: PendingAgentRequest) -> String? {
        let targets = Set(request.targets)
        guard !targets.isEmpty, targets.count == request.targets.count,
            targets.isSubset(of: Set(ClientKind.allCases))
        else {
            return "The request has an invalid app selection. Nothing was approved."
        }
        guard request.scope == .user || request.scope == .project else {
            return "The request has an unsupported scope. Nothing was approved."
        }
        let root = request.reviewDetails.projectRoot
        if request.scope == .project {
            guard let root, root != "/", normalized(root) == root else {
                return "The request does not name one canonical project folder. Nothing was approved."
            }
        } else if root != nil {
            return "A This Mac request cannot carry a project folder. Nothing was approved."
        }
        let now = Date()
        guard !request.title.isEmpty, request.title.count <= 200,
            !request.summary.isEmpty, request.summary.count <= 600,
            (request.reason?.count ?? 0) <= 500,
            !request.requestedByLabels.isEmpty, request.requestedByLabels.count <= 8,
            request.requestedByLabels.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
            request.repeatCount >= 1,
            request.lastRequestedAt >= request.createdAt,
            request.lastRequestedAt <= now.addingTimeInterval(300),
            now.timeIntervalSince(request.createdAt) <= PendingAgentRequestQueue.maximumPendingAge,
            request.fingerprint.count == 64,
            request.fingerprint.allSatisfy({ $0.isHexDigit })
        else {
            return
                "The request metadata is invalid or expired. Reject it and ask the client to submit it again."
        }
        guard let inputs = fingerprintInputs(for: request) else {
            return "The request is incomplete or contains unexpected fields. Nothing was approved."
        }
        let expected = PendingRequestQueueService.fingerprint(
            kind: request.kind, inputs: inputs, scope: request.scope, targets: request.targets)
        guard expected == request.fingerprint else {
            return "The request payload no longer matches its integrity fingerprint. Nothing was approved."
        }
        return nil
    }

    /// The exact inputs each kind was fingerprinted from. A field a kind has no
    /// business carrying must be absent, not merely ignored, or two different
    /// requests could share one fingerprint.
    static func fingerprintInputs(for request: PendingAgentRequest) -> [String]? {
        let details = request.reviewDetails
        switch request.kind {
        case .addMCPServer:
            guard let identifier = request.componentID, !identifier.isEmpty,
                let endpoint = details.endpoint,
                endpoint.count <= MCPDefinitionValidator.maximumDestinationLength,
                let transport = details.transport, MCPTransport(rawValue: transport) != nil,
                details.source == nil, details.instruction == nil, details.componentKind == nil
            else { return nil }
            return [identifier, transport, endpoint, details.projectRoot ?? ""]
        case .createSkill:
            guard let instruction = details.instruction,
                !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                instruction.count <= CodexSkillDraftRequest.maximumInstructionCharacters,
                instruction.utf8.count <= CodexSkillDraftRequest.maximumInstructionBytes,
                details.endpoint == nil, details.transport == nil, details.source == nil,
                details.componentKind == nil
            else { return nil }
            return [request.componentID ?? "", instruction, details.projectRoot ?? ""]
        case .installSkill:
            guard let identifier = request.componentID, !identifier.isEmpty,
                details.endpoint == nil, details.transport == nil, details.source == nil,
                details.instruction == nil, details.componentKind == nil
            else { return nil }
            return [identifier, details.projectRoot ?? ""]
        case .installPlugin:
            guard let identifier = request.componentID, !identifier.isEmpty,
                (details.source?.count ?? 0) <= 256,
                details.endpoint == nil, details.transport == nil, details.instruction == nil,
                details.componentKind == nil
            else { return nil }
            return [identifier, details.source ?? "", details.projectRoot ?? ""]
        case .removeComponent:
            guard request.scope == .user, details.projectRoot == nil,
                let identifier = request.componentID, !identifier.isEmpty,
                let kind = details.componentKind, ["skill", "mcp-server", "plugin"].contains(kind),
                details.endpoint == nil, details.transport == nil, details.source == nil,
                details.instruction == nil
            else { return nil }
            return [kind, identifier]
        }
    }

    private static func normalized(_ value: String) -> String {
        URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path(percentEncoded: false)
    }
}
