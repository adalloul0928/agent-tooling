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

