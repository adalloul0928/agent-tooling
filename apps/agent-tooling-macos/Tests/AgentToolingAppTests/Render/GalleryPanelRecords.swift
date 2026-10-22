import AgentToolingTestSupport
import Foundation
import Testing

/// One open or save panel the app builds, as the gallery's index lists it: the
/// words the panel shows and what it chooses. A record names the declaration
/// that builds the panel, never a line number. The index reads the line from
/// the source when it records the panel, so code moving above a panel cannot
/// leave its record pointing at the wrong line.
struct GalleryPanelRecord {
    /// Where the panel is built and the words it sets, which
    /// `GalleryPanelRecordTests` checks against the source.
    let panel: SourcePanel
    /// What the panel chooses, and what for when its own words do not say.
    let chooses: String

    var control: String { panel.kind == .save ? "Save panel" : "Open panel" }

    /// `Export package · prompt "Export" · "Choose a folder…" · folders`.
    var text: String {
        [panel.title, panel.prompt.map { "prompt \"\($0)\"" }, panel.message.map { "\"\($0)\"" }, chooses]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static let all = [
        GalleryPanelRecord(
            panel: SourcePanel(file: "CatalogSourceEditing.swift", builtIn: "AddCatalogSourceSheet.choose", prompt: "Use folder"),
            chooses: "folders (the folder a catalog is read from)"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "CollectionSharing.swift", builtIn: "PackageFileExport.chooseDestinationFolder",
                title: "Export package", prompt: "Export", message: "Choose a folder on this Mac to write the package into."),
            chooses: "folders"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "PasteImportSheet.swift", builtIn: "PasteImportSheet.chooseProjectFolder",
                title: "Choose this connection's project folder", prompt: "Choose"),
            chooses: "folders"),
        GalleryPanelRecord(
            panel: SourcePanel(file: "ProjectDetailView.swift", builtIn: "ProjectDetailView.chooseFolder", prompt: "Use folder"),
            chooses: "folders (the folder on this Mac that backs a project)"),
        GalleryPanelRecord(
            panel: SourcePanel(file: "ProjectEditingSheets.swift", builtIn: "NewProjectSheet.chooseFolder", prompt: "Use folder"),
            chooses: "folders (the folder a new project starts from)"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "ProjectsView.swift", builtIn: "ProjectsView.addScanRoot", prompt: "Look here",
                message: "Agent Tooling will look through this folder's children for projects."),
            chooses: "folders"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "SkillCreatorSheet.swift", builtIn: "SkillCreatorSheet.chooseProjectFolder",
                title: "Choose a project folder", prompt: "Choose"),
            chooses: "folders"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "SyncCenterView.swift", builtIn: "WorkspaceLinkDestinationSheet.choose", prompt: "Use folder"),
            chooses: "folders (where one app's tools go instead of its own folder)"),
        GalleryPanelRecord(
            panel: SourcePanel(file: "SyncSettingsView.swift", builtIn: "SyncSettingsView.chooseFolder", prompt: "Use folder"),
            chooses: "folders (the folder a file sync keeps in step)"),
        GalleryPanelRecord(
            panel: SourcePanel(file: "SyncSettingsView.swift", builtIn: "SyncSettingsView.chooseCheckout", prompt: "Use folder"),
            chooses: "folders (this Mac's checkout of the sync repository)"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "WorkspaceAuthoringSheets.swift", builtIn: "WorkspaceAttachFolderSheet.choose", prompt: "Use folder"),
            chooses: "folders (a folder you author in, to attach)"),
        GalleryPanelRecord(
            panel: SourcePanel(
                file: "WorkspaceAuthoringSheets.swift", builtIn: "WorkspacePackageExportSheet.choose", prompt: "Export here"),
            chooses: "folders (where one item is written out as a plain folder)"),
    ]
}

/// A panel as the app's source builds it: found by its `NSOpenPanel()` or
/// `NSSavePanel()`, and read from the plain strings set on it before it is
/// shown. Two are equal when they are built in the same declaration with the
/// same words; the line a panel sits on is not part of that.
struct SourcePanel: Hashable, CustomStringConvertible {
    enum Kind: String, CaseIterable {
        case open = "NSOpenPanel"
        case save = "NSSavePanel"
    }

    var kind = Kind.open
    /// The file, below `Sources/AgentToolingApp`.
    let file: String
    /// The declarations the panel is built in, outermost first:
    /// "SyncSettingsView.chooseCheckout".
    let builtIn: String
    var title: String?
    var prompt: String?
    var message: String?

    var description: String {
        let words = [("title", title), ("prompt", prompt), ("message", message)]
            .compactMap { name, value in value.map { "\(name) \"\($0)\"" } }
        return "\(file) \(builtIn): " + ([kind.rawValue] + words).joined(separator: ", ")
    }

    /// Why a panel could not be read, said the way a failing test should say it.
    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    /// Every panel `Sources/AgentToolingApp` builds, with the line it is built on.
    static func inApp() throws -> [(panel: SourcePanel, line: Int)] {
        try PackageSourceFile.all(in: "AgentToolingApp").flatMap { try panels(in: $0) }
    }

    /// The panels one file builds. A panel is found by
    /// `let <name> = NSOpenPanel()` and read up to the `<name>.runModal()` or
    /// `<name>.begin…` that shows it. A panel the check cannot vouch for, one
    /// that is never named or never shown or whose words are not one plain
    /// string literal, throws rather than reading as a panel with no words.
    static func panels(in file: PackageSourceFile) throws -> [(panel: SourcePanel, line: Int)] {
        try file.lines.indices.compactMap { index -> (panel: SourcePanel, line: Int)? in
            let code = file.lines[index].trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), let kind = Kind.allCases.first(where: { code.contains("\($0.rawValue)()") }) else {
                return nil
            }
            let place = "\(file.path):\(index + 1)"
            guard code.hasPrefix("let "), let equals = code.range(of: " = ") else {
                throw Unreadable(description: "\(place) builds a panel without naming it, so its words cannot be read")
            }
            let name = String(code[code.index(code.startIndex, offsetBy: "let ".count)..<equals.lowerBound])
            let rest = file.lines[(index + 1)...]
            guard let shown = rest.firstIndex(where: { $0.contains("\(name).runModal()") || $0.contains("\(name).begin") })
            else {
                throw Unreadable(description: "\(place): \(name) is never shown with runModal() or begin…")
            }
            let setup = file.lines[(index + 1)..<shown]
            func words(_ property: String) throws -> String? {
                let assignment = "\(name).\(property) = "
                let lines = setup.map { $0.trimmingCharacters(in: .whitespaces) }
                guard let line = lines.last(where: { $0.hasPrefix(assignment) }) else { return nil }
                let value = line.dropFirst(assignment.count)
                let inner = value.dropFirst().dropLast()
                guard value.count > 1, value.hasPrefix("\""), value.hasSuffix("\""), !inner.contains("\""), !inner.contains("\\")
                else {
                    throw Unreadable(description: "\(place): \(name).\(property) is not one plain string literal")
                }
                return String(inner)
            }
            let title = try words("title")
            let prompt = try words("prompt")
            let message = try words("message")
            let panel = SourcePanel(
                kind: kind, file: file.path, builtIn: scope(of: index, in: file.lines),
                title: title, prompt: prompt, message: message)
            return (panel: panel, line: index + 1)
        }
    }

    /// The declarations around line `index`, outermost first, found by walking
    /// up to each line indented less than the one before it. A line that opens
    /// with `)` or `}` is passed over, so a signature over several lines still
    /// leads to its `func`.
    static func scope(of index: Int, in lines: [String]) -> String {
        var names: [String] = []
        var indent = lines[index].prefix { $0 == " " }.count
        for line in lines[..<index].reversed() {
            if indent == 0 { break }
            let lead = line.prefix { $0 == " " }.count
            let code = line.dropFirst(lead)
            guard lead < indent, !code.isEmpty, !code.hasPrefix(")"), !code.hasPrefix("}"), !code.hasPrefix("//") else {
                continue
            }
            indent = lead
            if let name = declaredName(code) { names.insert(name, at: 0) }
        }
        return names.joined(separator: ".")
    }

    /// The name a line declares when it opens a type, a function or a
    /// computed property such as `body`; nil for any other line.
    static func declaredName(_ code: Substring) -> String? {
        let openers: Set<Substring> = ["struct", "enum", "class", "actor", "extension", "func", "var"]
        let words = code.split(separator: " ")
        guard let keyword = words.firstIndex(where: openers.contains), keyword + 1 < words.count,
            words[keyword] != "var" || code.hasSuffix("{")
        else { return nil }
        let name = words[keyword + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

/// The gallery lists each open and save panel in words instead of a picture,
/// and the gallery runs only on request, so a panel's title could change with
/// nothing to notice that its record no longer matches. This suite checks on
/// every run that the records and the panels the source builds are the same
/// set, word for word.
@Suite("Gallery · Panel records")
struct GalleryPanelRecordTests {
    @Test("Every panel the app builds is recorded, in the words the source gives it")
    func recordsMatchTheSource() throws {
        let built = try SourcePanel.inApp().map { $0.panel }
        let recorded = GalleryPanelRecord.all.map(\.panel)
        #expect(Set(built).count == built.count, "two panels are built in one declaration with the same words")
        #expect(Set(recorded).count == recorded.count, "a panel is recorded twice")
        let unrecorded = built.filter { !recorded.contains($0) }
        let stale = recorded.filter { !built.contains($0) }
        #expect(unrecorded.isEmpty, "built, but not recorded in these words: \(unrecorded)")
        #expect(stale.isEmpty, "recorded, but not built in these words: \(stale)")
    }

    @Test("A panel is placed in the declaration that builds it, and read only from plain words")
    func readsWhereAPanelIsBuilt() throws {
        let view = PackageSourceFile(
            path: "Probe.swift",
            lines: [
                "struct Probe: View {",
                "    var body: some View {",
                "        Button(\"Save…\") {",
                "            let picker = NSSavePanel()",
                "            picker.prompt = \"Save\"",
                "            _ = picker.runModal()",
                "        }",
                "    }",
                "}",
            ])
        let found = try SourcePanel.panels(in: view)
        #expect(found.map { $0.line } == [4])
        #expect(found.map { $0.panel } == [SourcePanel(kind: .save, file: "Probe.swift", builtIn: "Probe.body", prompt: "Save")])

        let computed = PackageSourceFile(
            path: "Probe.swift",
            lines: [
                "func choose() {",
                "    let panel = NSOpenPanel()",
                "    panel.title = name",
                "    _ = panel.runModal()",
                "}",
            ])
        #expect(throws: SourcePanel.Unreadable.self) { try SourcePanel.panels(in: computed) }
    }
}
