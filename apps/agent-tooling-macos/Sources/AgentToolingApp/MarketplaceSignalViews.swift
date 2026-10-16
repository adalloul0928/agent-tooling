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
        case .reference: AgentTheme.selection
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
        HStack(spacing: Space.xs) {
            Image(systemName: verdict.classification.symbol)
                .font(AgentFont.captionSemibold)
            if showsLabel {
                Text(verdict.classification.displayName)
                    .font(AgentFont.captionMedium)
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
                    .font(AgentFont.mono.weight(.bold))
                    .foregroundStyle(tint(grade))
                    .frame(width: Size.pillHeight, height: Size.chipHeight)
                    .background(tint(grade).opacity(Opacity.badgeWash), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            } else {
                Text(PackageGradeVerdict.notGradedLetter)
                    .font(AgentFont.captionMedium)
                    .foregroundStyle(.secondary)
                    .frame(height: Size.chipHeight)
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
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(verdict.kind.displayName)
                            .font(AgentFont.body)
                        Text(verdict.kind.qualifier)
                            .font(AgentFont.micro)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: Size.labelColumn, alignment: .leading)
                    Text(verdict.detail)
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GradeChip(verdict: verdict)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
                .help(verdict.measurement)
                if verdict.id != verdicts.last?.id { Hairline() }
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
                        if tool.id != tools.last?.id { Hairline() }
                    }
                    Hairline()
                    Text(
                        "Declared by the publisher in the \(sourceName) listing. Agent Tooling has not run this server, so nothing here is observed behavior. MCP treats a tool with no annotations as one that may change or delete data."
                    )
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.lg)
                }
            } else {
                Text(
                    "This listing publishes no tool list. The registry's server record has no field for tools, so only a publisher who adds one voluntarily has any to show — the tools themselves appear in the client once the server runs there."
                )
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .wrapsLines()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.xl)
            }
        }
    }
}

private struct DeclaredToolRow: View {
    let tool: MCPToolDescriptor
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(tool.displayName)
                    .font(AgentFont.bodyMedium)
                    .lineLimit(1)
                Spacer(minLength: Space.md)
                ToolAnnotationChips(annotations: tool.annotations)
            }
            if let summary = tool.summary {
                Text(summary)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            if tool.annotations.isEmpty {
                Text("No annotations declared for this tool.")
                    .font(AgentFont.micro)
                    .foregroundStyle(.secondary)
            }
            if tool.declaresInputSchema || tool.declaresOutputSchema {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        SchemaFieldList(title: "Input", fields: tool.inputFields, declared: tool.declaresInputSchema)
                        SchemaFieldList(title: "Output", fields: tool.outputFields, declared: tool.declaresOutputSchema)
                    }
                    .padding(.top, Space.sm)
                } label: {
                    Text(schemaSummary)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No input or output schema published for this tool.")
                    .font(AgentFont.micro)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }

    private var schemaSummary: String {
        var parts: [String] = []
        if tool.declaresInputSchema {
            parts.append(CountNoun("input field").phrase(tool.inputFields.count))
        }
        if tool.declaresOutputSchema {
            parts.append(CountNoun("output field").phrase(tool.outputFields.count))
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
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionCaption(text: title)
                if fields.isEmpty {
                    Text("Declared with no fields.")
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fields) { field in
                        HStack(spacing: Space.sm) {
                            if field.isSecretLike {
                                Image(systemName: "lock.fill")
                                    .font(AgentFont.microSemibold)
                                    .foregroundStyle(AgentTheme.warning)
                                    .accessibilityLabel("Secret field, masked")
                            }
                            Text(field.name)
                                .font(AgentFont.mono)
                                .textSelection(.enabled)
                            if let type = field.type {
                                Text(type)
                                    .font(AgentFont.micro)
                                    .foregroundStyle(.secondary)
                            }
                            if field.isRequired {
                                Text("required")
                                    .font(AgentFont.micro)
                                    .foregroundStyle(.tertiary)
                            }
                            if field.isSecretLike {
                                Text(SecretFieldMasking.placeholder)
                                    .font(AgentFont.mono)
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
        FlowLayout(spacing: Space.xs) {
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
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(AgentFont.microSemibold)
            Text(title).font(AgentFont.microMedium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.sm)
        .frame(height: Size.chipHeight)
        .background(tint.opacity(Opacity.tagWash), in: Capsule())
    }
}

// MARK: - Credential names

/// Configuration a server asks for, by name only. Agent Tooling stores no
/// secret values, so a credential-shaped name shows a lock and a mask where a
/// value would otherwise be — there is nothing to reveal.
struct RequestedCredentialNames: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FlowLayout(spacing: Space.sm) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: Space.xs) {
                        Image(systemName: SecretFieldMasking.isSecretLike(name) ? "lock.fill" : "character.cursor.ibeam")
                            .font(AgentFont.microSemibold)
                            .foregroundStyle(SecretFieldMasking.isSecretLike(name) ? AgentTheme.warning : Color.secondary)
                        Text(name)
                            .font(AgentFont.mono)
                            .lineLimit(1)
                        if SecretFieldMasking.isSecretLike(name) {
                            Text(SecretFieldMasking.placeholder)
                                .font(AgentFont.mono)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: Size.pillHeight)
                    .background(AgentTheme.fillSubtle, in: Capsule())
                    .help(
                        SecretFieldMasking.isSecretLike(name)
                            ? "\(name) reads like a credential. Agent Tooling never stores or shows its value, and no value is ever written into a plan."
                            : "\(name) is a configuration name this server asks the client for.")
                }
            }
            Text("Names only. Values are entered in the client and are never stored, displayed, or placed in a plan by Agent Tooling.")
                .font(AgentFont.micro)
                .foregroundStyle(.secondary)
                .wrapsLines()
        }
    }
}
