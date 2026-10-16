import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Console state

/// Drives one live MCP test connection for the selected server.
///
/// Nothing here starts on its own. Every connection begins with an explicit
/// per-server action that has already shown the exact command, and every
/// connection ends at ``MCPTestConnectionPolicy/sessionLifetime`` even if the
/// person walks away with the pane open.
@MainActor
@Observable
final class MCPTestConsoleModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case stopped
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var observation: MCPLiveObservation?
    private(set) var failure: String?
    private(set) var diagnostics = ""
    private(set) var connectedAt: Date?
    private(set) var outcome: MCPToolCallOutcome?
    private(set) var toolFailure: String?
    private(set) var runningToolName: String?

    private var session: MCPLiveTestSession?
    private var connectTask: Task<Void, Never>?
    private var lifetimeTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    var isBusy: Bool { phase == .connecting || runningToolName != nil }
    var isLive: Bool { phase == .live }

    var expiresAt: Date? {
        connectedAt.map { $0.addingTimeInterval(TimeInterval(MCPTestConnectionPolicy.sessionLifetimeSeconds)) }
    }

    var observedSafety: [String: MCPToolSafety] {
        guard let observation else { return [:] }
        return Dictionary(uniqueKeysWithValues: observation.tools.map { ($0.name, $0.safety) })
    }

    /// Opens a connection. The caller must already have taken consent for this
    /// exact target.
    func connect(target: MCPTestTarget, onObservation: @escaping @MainActor ([String]) -> Void) {
        guard phase != .connecting, phase != .live else { return }
        clearSession()
        phase = .connecting
        failure = nil
        toolFailure = nil
        outcome = nil
        observation = nil
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = MCPLiveTestSession(channel: try Self.makeChannel(for: target))
                self.session = session
                let result = try await session.open()
                guard !Task.isCancelled else { return }
                self.observation = result
                self.diagnostics = await session.diagnostics()
                self.connectedAt = .now
                self.phase = .live
                self.startLifetimeCountdown()
                onObservation(result.tools.map(\.name))
            } catch {
                guard !Task.isCancelled else { return }
                self.diagnostics = await self.session?.diagnostics() ?? ""
                await self.session?.close()
                self.session = nil
                self.phase = .failed
                self.failure = Self.message(for: error)
            }
            self.connectTask = nil
        }
    }

    /// Runs one tool after the caller has taken confirmation for this exact
    /// invocation. Server-provided annotations never grant local authority.
    func run(tool: MCPLiveTool, arguments: [String: JSONValue]) {
        guard phase == .live, runningToolName == nil, let session else { return }
        runningToolName = tool.name
        toolFailure = nil
        outcome = nil
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await session.callTool(named: tool.name, arguments: arguments)
                guard !Task.isCancelled else { return }
                self.outcome = result
            } catch {
                guard !Task.isCancelled else { return }
                self.toolFailure = Self.message(for: error)
                if Self.endsTheConnection(error) {
                    self.phase = .stopped
                    self.connectedAt = nil
                }
            }
            self.diagnostics = await session.diagnostics()
            self.runningToolName = nil
            self.runTask = nil
        }
    }

    func stop() {
        guard phase == .connecting || phase == .live else { return }
        phase = .stopped
        connectedAt = nil
        clearSession()
    }

    /// Used when the selection moves to another server or the pane goes away.
    func reset() {
        clearSession()
        phase = .idle
        observation = nil
        failure = nil
        toolFailure = nil
        outcome = nil
        diagnostics = ""
        connectedAt = nil
    }

    private func clearSession() {
        connectTask?.cancel()
        connectTask = nil
        runTask?.cancel()
        runTask = nil
        lifetimeTask?.cancel()
        lifetimeTask = nil
        runningToolName = nil
        let closing = session
        session = nil
        guard let closing else { return }
        Task { await closing.close() }
    }

    private func startLifetimeCountdown() {
        lifetimeTask?.cancel()
        lifetimeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: MCPTestConnectionPolicy.sessionLifetime)
            guard let self, !Task.isCancelled, self.phase == .live else { return }
            self.stop()
            self.failure = "The test connection reached its time limit and was stopped."
        }
    }

    private static func makeChannel(for target: MCPTestTarget) throws -> any MCPTestChannel {
        switch target {
        case .stdio: try MCPStdioTestChannel(target: target)
        case .http: try MCPHTTPTestChannel(target: target)
        }
    }

    private static func endsTheConnection(_ error: any Error) -> Bool {
        guard let live = error as? MCPLiveTestError else { return true }
        switch live {
        case .serverError, .toolNotOffered: return false
        default: return true
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? MCPLiveTestError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Detail pane entry point

/// The one view the MCP detail pane calls into: a live test console, and the
/// per-tool capability switches the console's observation feeds.
struct MCPServerCapabilitiesPane: View {
    let server: MCPServer

    @State private var console: MCPTestConsoleModel

    init(server: MCPServer, console: MCPTestConsoleModel = MCPTestConsoleModel()) {
        self.server = server
        _console = State(initialValue: console)
    }

    /// Resolved once here so the console and the capability card agree about
    /// whether a live test is even possible for this server.
    private var resolution: Result<MCPTestTarget, any Error> {
        Result { try MCPTestConnectionPolicy.resolve(server: server) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            MCPTestConsoleSection(server: server, resolution: resolution, console: console)
            MCPCapabilitySection(
                serverID: server.id,
                serverName: server.name,
                canRunLiveTest: (try? resolution.get()) != nil,
                observedSafety: console.observedSafety
            )
        }
        .onDisappear { console.stop() }
    }
}

// MARK: - Console section

private struct MCPTestConsoleSection: View {
    @Environment(MCPCapabilityModel.self) private var capabilities
    let server: MCPServer
    let resolution: Result<MCPTestTarget, any Error>
    let console: MCPTestConsoleModel

    @State private var isShowingConsent = false
    @State private var selectedToolName: String?
    @State private var pendingRun: MCPPendingToolRun?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header
            switch resolution {
            case .success(let target): connectableBody(target)
            case .failure(let error): unavailableBody(error)
            }
        }
        .onChange(of: server.id) { _, _ in
            console.reset()
            selectedToolName = nil
        }
        .sheet(isPresented: $isShowingConsent) {
            if case .success(let target) = resolution {
                MCPTestConsentSheet(serverName: server.name, target: target) {
                    console.connect(target: target) { toolNames in
                        capabilities.observe(toolNames: toolNames, serverID: server.id)
                    }
                }
            }
        }
        .alert(item: $pendingRun) { run in
            Alert(
                title: Text("Run \(run.tool.name) on \(server.name)?"),
                message: Text(runConfirmationMessage(run.tool)),
                primaryButton: .destructive(Text("Run tool")) {
                    console.run(tool: run.tool, arguments: run.arguments)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.md) {
            Text("Live test").font(AgentFont.heading)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, Space.xxs)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch console.phase {
        case .idle:
            Text("Not tested").font(AgentFont.caption).foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(AgentFont.caption).foregroundStyle(.secondary)
            }
        case .live:
            if let observation = console.observation {
                StatusBadge(state: .healthy, text: observation.headline)
            }
        case .stopped:
            Text("Stopped").font(AgentFont.caption).foregroundStyle(.secondary)
        case .failed:
            StatusBadge(state: .attention, text: "Did not respond")
        }
    }

    // MARK: Unavailable

    private func unavailableBody(_ error: any Error) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "bolt.slash").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("A live test is not possible for this connection")
                    .font(AgentFont.bodyMedium)
                Text(error.localizedDescription)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
    }

    // MARK: Connectable

    @ViewBuilder
    private func connectableBody(_ target: MCPTestTarget) -> some View {
        VStack(spacing: 0) {
            commandRow(target)
            Hairline()
            controlRow(target)
            if console.isLive, let observation = console.observation {
                Hairline()
                MCPObservationSummary(observation: observation)
            }
            if let failure = console.failure {
                Hairline()
                messageRow(failure, state: console.phase == .failed ? HealthState.attention : .pending)
            }
            if !console.diagnostics.isEmpty {
                Hairline()
                diagnosticsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()

        if console.isLive, let observation = console.observation {
            MCPToolInventoryList(
                tools: observation.tools,
                selectedToolName: $selectedToolName,
                isBusy: console.isBusy
            )
            if let tool = observation.tools.first(where: { $0.name == selectedToolName }) {
                MCPToolRunPanel(
                    tool: tool,
                    serverName: server.name,
                    isRunning: console.runningToolName == tool.name,
                    needsConfirmation: tool.requiresRunConfirmation,
                    outcome: console.outcome?.toolName == tool.name ? console.outcome : nil,
                    failure: console.toolFailure
                ) { arguments, needsConfirmation in
                    if needsConfirmation {
                        pendingRun = MCPPendingToolRun(tool: tool, arguments: arguments)
                    } else {
                        console.run(tool: tool, arguments: arguments)
                    }
                }
            }
        }
    }

    private func commandRow(_ target: MCPTestTarget) -> some View {
        LabeledValueRow(target.isProcessLaunch ? "Runs" : "Contacts") {
            HStack(alignment: .top, spacing: Space.md) {
                Text(target.displayCommand)
                    .font(AgentFont.mono)
                    .textSelection(.enabled)
                    .wrapsLines()
                Spacer(minLength: Space.md)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.displayCommand, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .inlineActionStyle()
                .controlSize(.small)
                .accessibilityLabel("Copy the test command")
            }
        }
    }

    @ViewBuilder
    private func controlRow(_ target: MCPTestTarget) -> some View {
        HStack(spacing: Space.lg) {
            if console.isLive, let connectedAt = console.connectedAt {
                MCPLiveIndicator(connectedAt: connectedAt, expiresAt: console.expiresAt)
            } else {
                Text(
                    target.isProcessLaunch
                        ? "Starts \(server.name)'s own program on this Mac. Nothing runs until you confirm."
                        : "Opens one MCP session with this endpoint. Nothing is contacted until you confirm."
                )
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            }
            Spacer(minLength: Space.lg)
            if console.isLive || console.phase == .connecting {
                Button("Stop", role: .destructive) { console.stop() }
                    .secondaryActionStyle()
                    .controlSize(.small)
            } else {
                Button(console.phase == .idle ? "Test connection…" : "Test again…") { isShowingConsent = true }
                    .secondaryActionStyle()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    private func messageRow(_ text: String, state: HealthState) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            StatusGlyph(state: state, size: Size.glyph)
            Text(text)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    private var diagnosticsRow: some View {
        DisclosureGroup {
            Text(console.diagnostics)
                .font(AgentFont.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.md)
        } label: {
            Text("Server output").font(AgentFont.caption)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    // MARK: Support

    private func runConfirmationMessage(_ tool: MCPLiveTool) -> String {
        "\(tool.safety.detail)\n\nThis is a real call to the running server, not a simulation. "
            + "Anything it changes on \(server.name) stays changed after the test connection stops."
    }
}

private struct MCPPendingToolRun: Identifiable {
    var id: String { tool.name }
    let tool: MCPLiveTool
    let arguments: [String: JSONValue]
}

