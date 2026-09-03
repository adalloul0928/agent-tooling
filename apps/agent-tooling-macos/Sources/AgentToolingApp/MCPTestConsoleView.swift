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
    /// Tools already confirmed during this connection, so a second run of the
    /// same tool does not re-ask while the session stays open.
    private(set) var confirmedTools: Set<String> = []

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
        confirmedTools = []
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

    /// Runs one tool. Consent for a tool that is not annotated read-only is the
    /// caller's responsibility and is recorded here so it is asked once.
    func run(tool: MCPLiveTool, arguments: [String: JSONValue]) {
        guard phase == .live, runningToolName == nil, let session else { return }
        confirmedTools.insert(tool.name)
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
        confirmedTools = []
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
        VStack(alignment: .leading, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 7) {
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
        HStack(spacing: 8) {
            Text("Live test").font(.subheadline.weight(.semibold))
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch console.phase {
        case .idle:
            Text("Not tested").font(.caption).foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .live:
            if let observation = console.observation {
                StatusBadge(state: .healthy, text: observation.headline)
            }
        case .stopped:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        case .failed:
            StatusBadge(state: .attention, text: "Did not respond")
        }
    }

    // MARK: Unavailable

    private func unavailableBody(_ error: any Error) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.slash").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("A live test is not possible for this server")
                    .font(.callout.weight(.medium))
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
    }

    // MARK: Connectable

    @ViewBuilder
    private func connectableBody(_ target: MCPTestTarget) -> some View {
        VStack(spacing: 0) {
            commandRow(target)
            Divider().opacity(0.45)
            controlRow(target)
            if console.isLive, let observation = console.observation {
                Divider().opacity(0.45)
                MCPObservationSummary(observation: observation)
            }
            if let failure = console.failure {
                Divider().opacity(0.45)
                messageRow(failure, state: console.phase == .failed ? HealthState.attention : .pending)
            }
            if !console.diagnostics.isEmpty {
                Divider().opacity(0.45)
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
                    needsConfirmation: tool.requiresRunConfirmation && !console.confirmedTools.contains(tool.name),
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
            HStack(alignment: .top, spacing: 8) {
                Text(target.displayCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.displayCommand, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Copy the test command")
            }
        }
    }

    @ViewBuilder
    private func controlRow(_ target: MCPTestTarget) -> some View {
        HStack(spacing: 12) {
            if console.isLive, let connectedAt = console.connectedAt {
                MCPLiveIndicator(connectedAt: connectedAt, expiresAt: console.expiresAt)
            } else {
                Text(
                    target.isProcessLaunch
                        ? "Starts \(server.name)'s own program on this Mac. Nothing runs until you confirm."
                        : "Opens one MCP session with this endpoint. Nothing is contacted until you confirm."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if console.isLive || console.phase == .connecting {
                Button("Stop", role: .destructive) { console.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(console.phase == .idle ? "Test connection…" : "Test again…") { isShowingConsent = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func messageRow(_ text: String, state: HealthState) -> some View {
        HStack(alignment: .top, spacing: 9) {
            StatusGlyph(state: state, size: 13)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var diagnosticsRow: some View {
        DisclosureGroup {
            Text(console.diagnostics)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Text("Server output").font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

// MARK: - Live indicator

private struct MCPLiveIndicator: View {
    let connectedAt: Date
    let expiresAt: Date?

    var body: some View {
        TimelineView(.periodic(from: connectedAt, by: 1)) { context in
            HStack(spacing: 7) {
                Circle()
                    .fill(AgentTheme.ok)
                    .frame(width: 7, height: 7)
                    .opacity(Int(context.date.timeIntervalSince(connectedAt)) % 2 == 0 ? 1 : 0.35)
                Text(label(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live connection open")
        }
    }

    private func label(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(connectedAt)))
        guard let expiresAt else { return "Live · \(elapsed)s" }
        let remaining = max(0, Int(expiresAt.timeIntervalSince(date)))
        return "Live · \(elapsed)s open · stops in \(remaining)s"
    }
}

// MARK: - Observation summary

private struct MCPObservationSummary: View {
    let observation: MCPLiveObservation

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                counter("Tools", observation.declaresTools ? "\(observation.tools.count)" : "—")
                Divider().frame(height: 30).opacity(0.45)
                counter("Resources", observation.declaresResources ? "\(observation.resourceCount)" : "—")
                Divider().frame(height: 30).opacity(0.45)
                counter("Prompts", observation.declaresPrompts ? "\(observation.promptCount)" : "—")
                Divider().frame(height: 30).opacity(0.45)
                counter("Handshake", "\(Int(observation.handshakeMilliseconds.rounded())) ms")
                Divider().frame(height: 30).opacity(0.45)
                counter("Inventory", "\(Int(observation.inventoryMilliseconds.rounded())) ms")
            }
            .padding(.vertical, 11)
            Divider().opacity(0.45)
            LabeledValueRow("Reported by server") {
                Text(identity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if observation.unannotatedToolCount > 0 || observation.destructiveToolCount > 0 {
                Divider().opacity(0.45)
                LabeledValueRow("Before you run") {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().opacity(0.45)
            LabeledValueRow("Recorded") {
                Text(
                    "Nothing. This is what one connection saw at \(observation.observedAt.formatted(date: .omitted, time: .standard)), not this server's saved status."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func counter(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var identity: String {
        let name = observation.serverName ?? "an unnamed server"
        let version = observation.serverVersion.map { " \($0)" } ?? ""
        return "\(name)\(version) · MCP \(observation.protocolVersion)"
    }

    private var warning: String {
        var parts: [String] = []
        if observation.destructiveToolCount > 0 {
            parts.append("\(observation.destructiveToolCount) declared destructive")
        }
        if observation.unannotatedToolCount > 0 {
            parts.append("\(observation.unannotatedToolCount) with no annotations, which MCP treats as able to change or delete data")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tool inventory

private struct MCPToolInventoryList: View {
    private static let visibleLimit = 60

    let tools: [MCPLiveTool]
    @Binding var selectedToolName: String?
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Tools this connection offered").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(tools.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                    row(tool)
                    if index < visibleTools.count - 1 { Divider().opacity(0.45) }
                }
                if tools.count > Self.visibleLimit {
                    Divider().opacity(0.45)
                    Text("\(tools.count - Self.visibleLimit) more tools are not listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }

    private var visibleTools: [MCPLiveTool] { Array(tools.prefix(Self.visibleLimit)) }

    private func row(_ tool: MCPLiveTool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: tool.safety.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tool.safety == .readOnly ? Color.secondary : AgentTheme.warning)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(tool.name)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MCPSafetyTag(text: tool.safety.label, isWarning: tool.safety != .readOnly)
                    if tool.declaresIdempotent { MCPSafetyTag(text: "Idempotent", isWarning: false) }
                    if tool.declaresOpenWorld { MCPSafetyTag(text: "Open world", isWarning: false) }
                }
                if let summary = tool.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(selectedToolName == tool.name ? "Selected" : "Run…") {
                selectedToolName = tool.name
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy || selectedToolName == tool.name)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tool.name), \(tool.safety.label)")
    }
}

private struct MCPSafetyTag: View {
    let text: String
    let isWarning: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isWarning ? AgentTheme.warning : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill((isWarning ? AgentTheme.warning : AgentTheme.graphite).opacity(0.14))
            )
    }
}

// MARK: - Run panel

/// The generated form for one tool, plus its result.
///
/// Module-internal rather than file-private so a render test can exercise the
/// destructive path: this is the surface where a person turns a schema into a
/// real call, and it should fail in a test rather than in front of somebody.
struct MCPToolRunPanel: View {
    let tool: MCPLiveTool
    let serverName: String
    let isRunning: Bool
    let needsConfirmation: Bool
    let outcome: MCPToolCallOutcome?
    let failure: String?
    let onRun: ([String: JSONValue], Bool) -> Void

    @State private var values: [String: String] = [:]
    @State private var rawObject = "{}"
    @State private var validationError: String?

    private var form: MCPToolInputForm { MCPToolInputForm.make(from: tool.inputSchema) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Run \(tool.name)").font(.subheadline.weight(.semibold))
                Spacer()
                MCPSafetyTag(text: tool.safety.label, isWarning: tool.safety != .readOnly)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                if tool.safety != .readOnly {
                    HStack(alignment: .top, spacing: 9) {
                        StatusGlyph(state: .attention, size: 13)
                        Text(tool.safety.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    Divider().opacity(0.45)
                }

                if form.takesNoArguments && !form.requiresRawObjectEditor {
                    LabeledValueRow("Arguments") {
                        Text("This tool takes none.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if form.requiresRawObjectEditor && form.fields.isEmpty {
                    rawEditor
                } else {
                    ForEach(form.fields) { field in
                        fieldRow(field)
                        Divider().opacity(0.45)
                    }
                    if form.requiresRawObjectEditor { rawEditor }
                }

                Divider().opacity(0.45)
                HStack(spacing: 10) {
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AgentTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Calls the running \(serverName) server for real.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if isRunning { ProgressView().controlSize(.small) }
                    Button(needsConfirmation ? "Run tool…" : "Run tool") { attemptRun() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AgentTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            if let outcome { MCPToolOutcomeView(outcome: outcome) }
        }
        .onChange(of: tool.name) { _, _ in
            values = [:]
            rawObject = "{}"
            validationError = nil
        }
    }

    private var rawEditor: some View {
        LabeledValueRow("Arguments (JSON)") {
            TextEditor(text: $rawObject)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 76)
                .scrollContentBackground(.hidden)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AgentTheme.separator.opacity(0.55), lineWidth: 0.5)
                }
                .accessibilityLabel("Arguments as JSON")
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: MCPToolInputField) -> some View {
        LabeledValueRow(field.displayName + (field.isRequired ? " *" : "")) {
            VStack(alignment: .leading, spacing: 4) {
                control(field)
                if let summary = field.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ field: MCPToolInputField) -> some View {
        let binding = Binding(
            get: { values[field.name] ?? field.defaultText ?? "" },
            set: { values[field.name] = $0 }
        )
        switch field.kind {
        case .boolean:
            Toggle("", isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(field.displayName)
        case .choice(let options):
            Picker("", selection: binding) {
                Text("Not set").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityLabel(field.displayName)
        case .text(let multiline) where multiline:
            TextEditor(text: binding)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AgentTheme.separator.opacity(0.55), lineWidth: 0.5)
                }
                .accessibilityLabel(field.displayName)
        case .text, .number:
            TextField("", text: binding, prompt: Text(field.name))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(field.displayName)
        case .rawJSON:
            TextField("", text: binding, prompt: Text("JSON value"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .accessibilityLabel("\(field.displayName) as JSON")
        }
    }

    private func attemptRun() {
        do {
            let arguments = try MCPToolArgumentBuilder.build(form: form, values: values, rawObject: rawObject)
            validationError = nil
            onRun(arguments, needsConfirmation)
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct MCPToolOutcomeView: View {
    let outcome: MCPToolCallOutcome

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                StatusGlyph(state: outcome.isError ? .attention : .healthy, size: 13)
                Text(outcome.isError ? "The server reported a tool error" : "The server answered")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 12)
                Text("\(Int(outcome.latencyMilliseconds.rounded())) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !outcome.text.isEmpty {
                Divider().opacity(0.45)
                MCPResultText(text: outcome.text, font: .system(.caption, design: .monospaced), tint: .primary)
            }
            if let structured = outcome.structuredText {
                Divider().opacity(0.45)
                MCPResultText(text: structured, font: .system(.caption2, design: .monospaced), tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
    }
}

/// Server output grows to fit short answers and scrolls inside a fixed box only
/// once it would otherwise take over the pane.
private struct MCPResultText: View {
    private static let inlineLineLimit = 12
    private static let inlineCharacterLimit = 900
    private static let scrollHeight: CGFloat = 200

    let text: String
    let font: Font
    let tint: Color

    var body: some View {
        Group {
            if isShort {
                content
            } else {
                ScrollView(.vertical) { content }
                    .frame(height: Self.scrollHeight)
            }
        }
        .padding(14)
    }

    private var content: some View {
        Text(text)
            .font(font)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isShort: Bool {
        text.count <= Self.inlineCharacterLimit
            && text.split(separator: "\n", omittingEmptySubsequences: false).count <= Self.inlineLineLimit
    }
}

// MARK: - Argument encoding

enum MCPToolArgumentError: LocalizedError {
    case missingRequired(String)
    case badNumber(String)
    case badJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let name): "\(name) is required."
        case .badNumber(let name): "\(name) needs a number."
        case .badJSON(let name): "\(name) needs valid JSON."
        }
    }
}

enum MCPToolArgumentBuilder {
    static func build(form: MCPToolInputForm, values: [String: String], rawObject: String) throws -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        if form.requiresRawObjectEditor || (form.fields.isEmpty && !form.takesNoArguments) {
            arguments = try decodeObject(rawObject, name: "Arguments")
        }
        for field in form.fields {
            let raw = (values[field.name] ?? field.defaultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                if field.isRequired { throw MCPToolArgumentError.missingRequired(field.displayName) }
                continue
            }
            switch field.kind {
            case .boolean: arguments[field.name] = .bool(raw == "true")
            case .number(let isInteger):
                guard let number = Double(raw), number.isFinite, !isInteger || number == number.rounded() else {
                    throw MCPToolArgumentError.badNumber(field.displayName)
                }
                arguments[field.name] = .number(number)
            case .text, .choice: arguments[field.name] = .string(raw)
            case .rawJSON: arguments[field.name] = try decodeValue(raw, name: field.displayName)
            }
        }
        return arguments
    }

    private static func decodeObject(_ text: String, name: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard case .object(let body) = try decodeValue(trimmed, name: name) else {
            throw MCPToolArgumentError.badJSON(name)
        }
        return body
    }

    private static func decodeValue(_ text: String, name: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8),
            data.count <= MCPTestConnectionPolicy.maximumArgumentBytes,
            let value = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: data)
        else {
            throw MCPToolArgumentError.badJSON(name)
        }
        return value
    }
}

// MARK: - Consent

/// The one screen that turns "Agent Tooling manages this definition" into
/// "Agent Tooling is about to run somebody else's code on your Mac".
private struct MCPTestConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let serverName: String
    let target: MCPTestTarget
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: target.isProcessLaunch ? "bolt.badge.clock" : "network", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.isProcessLaunch ? "Start \(serverName) for a live test" : "Open a live test session")
                        .font(.title3.weight(.semibold))
                    Text("This is the only thing Agent Tooling will run or contact.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionCaption(text: target.isProcessLaunch ? "Exact command" : "Exact endpoint")
                        Text(target.displayCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .standardPanel()
                    }

                    Text(MCPTestConnectionPolicy.consentSummary(for: target, serverName: serverName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ForEach(Array(boundaries.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(item.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(13)
                            if index < boundaries.count - 1 { Divider().opacity(0.45) }
                        }
                    }
                    .standardPanel()
                }
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(target.isProcessLaunch ? "Start and connect" : "Connect") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .background(AgentTheme.contentBackground)
    }

    private var boundaries: [(symbol: String, text: String)] {
        var items: [(String, String)] = []
        if target.isProcessLaunch {
            items.append(
                (
                    "shield.lefthalf.filled",
                    "Only this program starts. Shells, `env`, and privilege wrappers are refused, so the line above is what runs."
                )
            )
            items.append(
                (
                    "key.slash",
                    "It gets a fresh, minimal environment — PATH, HOME, TMPDIR, LANG, USER. None of your exported keys or tokens are passed, "
                        + "so a server that needs credentials will say so instead of using them."
                )
            )
        } else {
            items.append(("key.slash", "No Authorization header, cookies, or saved credentials are sent."))
        }
        items.append(
            (
                "stopwatch",
                "Every step is time-limited, and the whole session stops after "
                    + "\(MCPTestConnectionPolicy.sessionLifetimeSeconds) seconds or whenever you press Stop."
            )
        )
        items.append(
            (
                "doc.badge.gearshape",
                "No client configuration changes, and the result is not saved as this server's status. It is one observation, shown once."
            )
        )
        items.append(
            (
                "hand.raised",
                "Running a tool afterwards is a real call. Agent Tooling asks again before the first run of any tool "
                    + "that is not annotated read-only."
            )
        )
        return items
    }
}
