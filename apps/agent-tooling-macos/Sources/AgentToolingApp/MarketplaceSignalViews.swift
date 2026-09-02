import AgentToolingCore
import SwiftUI

// MARK: - Provenance

extension PackageClassification {
    var symbol: String {
        switch self {
        case .reference: "books.vertical.fill"
        case .official: "checkmark.seal.fill"
        case .community: "person.2.fill"
        case .unverified: "questionmark.circle"
        }
    }

    /// Provenance is a verdict, so it borrows the status palette rather than
    /// the identity palette: a badge never competes with a package's tile.
    var tint: Color {
        switch self {
        case .reference: AgentTheme.blue
        case .official: AgentTheme.ok
        case .community: AgentTheme.graphite
        case .unverified: Color.secondary
        }
    }
}

/// The verdict at the end of a row: one glyph, one word, and the evidence
/// behind it in the tooltip. Never a claim the catalog did not make.
struct ProvenanceBadge: View {
    let verdict: PackageClassificationVerdict
    var showsLabel = true
    /// Selected rows draw on the accent fill, where only white stays legible.
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.classification.symbol)
                .font(.system(size: 11, weight: .semibold))
            if showsLabel {
                Text(verdict.classification.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint ?? verdict.classification.tint)
        .help(verdict.evidence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Provenance: \(verdict.classification.displayName)")
        .accessibilityHint(verdict.evidence)
    }
}

// MARK: - Grades

/// A letter in a chip, or the words "Not graded". An ungraded line is never
/// dropped and never dressed up as a pass.
struct GradeChip: View {
    let verdict: PackageGradeVerdict

    var body: some View {
        Group {
            if let grade = verdict.grade {
                Text(grade.letter)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(tint(grade))
                    .frame(width: 22, height: 20)
                    .background(tint(grade).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(PackageGradeVerdict.notGradedLetter)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 20)
            }
        }
        .accessibilityLabel("\(verdict.kind.displayName) grade: \(verdict.letter)")
    }

    private func tint(_ grade: PackageGrade) -> Color {
        switch grade {
        case .a, .b: AgentTheme.ok
        case .c: AgentTheme.warning
        case .d, .f: AgentTheme.failure
        }
    }
}

/// Three graded lines, each stating what it measured. The tooltip is the point
/// of the card: a letter with no stated measurement is a rumour.
struct PackageGradeRows: View {
    let verdicts: [PackageGradeVerdict]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(verdicts) { verdict in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdict.kind.displayName)
                            .font(.callout)
                        Text(verdict.kind.qualifier)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 132, alignment: .leading)
                    Text(verdict.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GradeChip(verdict: verdict)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .help(verdict.measurement)
                if verdict.id != verdicts.last?.id { Divider() }
            }
        }
    }
}

// MARK: - Declared tools

/// What an MCP server says it exposes, with MCP's own annotations. This is the
/// detail a person needs before approving a plan, so a destructive tool is
/// named as such — and a tool whose publisher declared nothing says that too.
struct DeclaredToolsCard: View {
    let tools: [MCPToolDescriptor]?
    let sourceName: String

    var body: some View {
        GroupBox("Tools") {
            if let tools, !tools.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tools) { tool in
                        DeclaredToolRow(tool: tool)
                        if tool.id != tools.last?.id { Divider() }
                    }
                    Divider()
                    Text(
                        "Declared by the publisher in the \(sourceName) listing. Agent Tooling has not run this server, so nothing here is observed behavior. MCP treats a tool with no annotations as one that may change or delete data."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            } else {
                Text(
                    "This listing publishes no tool list. The registry's server record has no field for tools, so only a publisher who adds one voluntarily has any to show — the tools themselves appear in the client once the server runs there."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }
}

private struct DeclaredToolRow: View {
    let tool: MCPToolDescriptor
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(tool.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                ToolAnnotationChips(annotations: tool.annotations)
            }
            if let summary = tool.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tool.annotations.isEmpty {
                Text("No annotations declared for this tool.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if tool.declaresInputSchema || tool.declaresOutputSchema {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        SchemaFieldList(title: "Input", fields: tool.inputFields, declared: tool.declaresInputSchema)
                        SchemaFieldList(title: "Output", fields: tool.outputFields, declared: tool.declaresOutputSchema)
                    }
                    .padding(.top, 7)
                } label: {
                    Text(schemaSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No input or output schema published for this tool.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var schemaSummary: String {
        var parts: [String] = []
        if tool.declaresInputSchema {
            parts.append("\(tool.inputFields.count) input field\(tool.inputFields.count == 1 ? "" : "s")")
        }
        if tool.declaresOutputSchema {
            parts.append("\(tool.outputFields.count) output field\(tool.outputFields.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

private struct SchemaFieldList: View {
    let title: String
    let fields: [MCPSchemaField]
    let declared: Bool

    var body: some View {
        if declared {
            VStack(alignment: .leading, spacing: 5) {
                SectionCaption(text: title)
                if fields.isEmpty {
                    Text("Declared with no fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fields) { field in
                        HStack(spacing: 6) {
                            if field.isSecretLike {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(AgentTheme.warning)
                                    .accessibilityLabel("Secret field, masked")
                            }
                            Text(field.name)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            if let type = field.type {
                                Text(type)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if field.isRequired {
                                Text("required")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if field.isSecretLike {
                                Text(SecretFieldMasking.placeholder)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .help("This field reads like a credential. Agent Tooling never stores or displays its value.")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ToolAnnotationChips: View {
    let annotations: MCPToolAnnotations

    var body: some View {
        FlowLayout(spacing: 5) {
            if annotations.destructive == true {
                chip("Destructive", symbol: "exclamationmark.triangle.fill", tint: AgentTheme.failure)
            }
            if annotations.readOnly == true {
                chip("Read-only", symbol: "eye", tint: AgentTheme.ok)
            }
            if annotations.readOnly == false {
                chip("Writes", symbol: "square.and.pencil", tint: AgentTheme.warning)
            }
            if annotations.destructive == false {
                chip("Non-destructive", symbol: "checkmark.shield", tint: AgentTheme.ok)
            }
            if annotations.idempotent == true {
                chip("Idempotent", symbol: "arrow.triangle.2.circlepath", tint: AgentTheme.graphite)
            }
            if annotations.idempotent == false {
                chip("Not idempotent", symbol: "arrow.triangle.2.circlepath", tint: AgentTheme.warning)
            }
            if annotations.openWorld == true {
                chip("Open world", symbol: "globe", tint: AgentTheme.warning)
            }
            if annotations.openWorld == false {
                chip("Closed world", symbol: "network.badge.shield.half.filled", tint: AgentTheme.graphite)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            annotations.isEmpty ? "No annotations declared" : "Annotations: \(annotations.declaredLabels.joined(separator: ", "))")
    }

    private func chip(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Credential names

/// Configuration a server asks for, by name only. Agent Tooling stores no
/// secret values, so a credential-shaped name shows a lock and a mask where a
/// value would otherwise be — there is nothing to reveal.
struct RequestedCredentialNames: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 5) {
                        Image(systemName: SecretFieldMasking.isSecretLike(name) ? "lock.fill" : "character.cursor.ibeam")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SecretFieldMasking.isSecretLike(name) ? AgentTheme.warning : Color.secondary)
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        if SecretFieldMasking.isSecretLike(name) {
                            Text(SecretFieldMasking.placeholder)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                    .help(
                        SecretFieldMasking.isSecretLike(name)
                            ? "\(name) reads like a credential. Agent Tooling never stores or shows its value, and no value is ever written into a plan."
                            : "\(name) is a configuration name this server asks the client for.")
                }
            }
            Text("Names only. Values are entered in the client and are never stored, displayed, or placed in a plan by Agent Tooling.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
