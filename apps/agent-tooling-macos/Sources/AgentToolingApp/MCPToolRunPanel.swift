import AgentToolingCore
import AppKit
import SwiftUI

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
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Run \(tool.name)").font(AgentFont.heading)
                Spacer()
                MCPSafetyTag(text: tool.safety.label, isWarning: tool.safety != .readOnly)
            }
            .padding(.horizontal, Space.xxs)

            VStack(spacing: 0) {
                if tool.safety != .readOnly {
                    HStack(alignment: .top, spacing: Space.md) {
                        StatusGlyph(state: .attention, size: Size.glyph)
                        Text(tool.safety.detail)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.lg)
                    Hairline()
                }

                if form.takesNoArguments && !form.requiresRawObjectEditor {
                    LabeledValueRow("Arguments") {
                        Text("This tool takes none.").font(AgentFont.caption).foregroundStyle(.secondary)
                    }
                } else if form.requiresRawObjectEditor && form.fields.isEmpty {
                    rawEditor
                } else {
                    ForEach(form.fields) { field in
                        fieldRow(field)
                        Hairline()
                    }
                    if form.requiresRawObjectEditor { rawEditor }
                }

                Hairline()
                HStack(spacing: Space.lg) {
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .font(AgentFont.caption)
                            .foregroundStyle(AgentTheme.warning)
                            .wrapsLines()
                    } else {
                        Text("Calls the running \(serverName) server for real.")
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.lg)
                    if isRunning { ProgressView().controlSize(.small) }
                    Button(needsConfirmation ? "Run tool…" : "Run tool") { attemptRun() }
                        .primaryActionStyle()
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(AgentFont.caption)
                    .foregroundStyle(AgentTheme.warning)
                    .wrapsLines()
                    .padding(.horizontal, Space.xxs)
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
                .font(AgentFont.mono)
                .frame(minHeight: Size.sheetBarHeight)
                .scrollContentBackground(.hidden)
                .padding(Space.sm)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
                }
                .accessibilityLabel("Arguments as JSON")
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: MCPToolInputField) -> some View {
        LabeledValueRow(field.displayName + (field.isRequired ? " *" : "")) {
            VStack(alignment: .leading, spacing: Space.xs) {
                control(field)
                if let summary = field.summary {
                    Text(summary)
                        .font(AgentFont.micro)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
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
            .frame(maxWidth: Size.fieldChoice, alignment: .leading)
            .accessibilityLabel(field.displayName)
        case .text(let multiline) where multiline:
            TextEditor(text: binding)
                .font(AgentFont.mono)
                .frame(minHeight: Size.rowHeightTall)
                .scrollContentBackground(.hidden)
                .padding(Space.sm)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
                }
                .accessibilityLabel(field.displayName)
        case .text, .number:
            TextField("", text: binding, prompt: Text(field.name))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(field.displayName)
        case .rawJSON:
            TextField("", text: binding, prompt: Text("JSON value"))
                .textFieldStyle(.roundedBorder)
                .font(AgentFont.mono)
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
            HStack(spacing: Space.md) {
                StatusGlyph(state: outcome.isError ? .attention : .healthy, size: Size.glyph)
                Text(outcome.isError ? "The server reported a tool error" : "The server answered")
                    .font(AgentFont.bodyMedium)
                Spacer(minLength: Space.lg)
                Text("\(Int(outcome.latencyMilliseconds.rounded())) ms")
                    .font(AgentFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            if !outcome.text.isEmpty {
                Hairline()
                MCPResultText(text: outcome.text, font: AgentFont.monoMicro, tint: .primary)
            }
            if let structured = outcome.structuredText {
                Hairline()
                MCPResultText(text: structured, font: AgentFont.monoMicro, tint: .secondary)
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

    let text: String
    let font: Font
    let tint: Color

    var body: some View {
        Group {
            if isShort {
                content
            } else {
                ScrollView(.vertical) { content }
                    .frame(height: Size.sheetScrollCap)
            }
        }
        .padding(Space.xl)
    }

    private var content: some View {
        Text(text)
            .font(font)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .wrapsLines()
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

