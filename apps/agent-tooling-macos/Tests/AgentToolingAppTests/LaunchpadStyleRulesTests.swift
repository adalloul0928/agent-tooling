import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The house rules for the setup stage's words (plan §8.4), held over the
/// source of every copy file: `Launchpad/LaunchpadCopy*.swift`, and the copy
/// files later packages add beside them (`FinishSetup*`, `AssistantRunCopy`,
/// `AssistantRunsNotice`, `ConnectionsCheckConfirmation`,
/// `CompanionTipsPopover`) as each lands.
///
/// apps, never clients; the one-character ellipsis, only where something
/// opens or is under way, never "..." and never "!"; curly apostrophes and
/// quotes; "you", never "we"; sync only in its qualified forms; every failure
/// ending "Nothing was changed."; the apps in the app order; and sentence
/// case, because Title Case belongs to the menus alone.
@Suite("Launchpad style rules")
struct LaunchpadStyleRulesTests {
    /// The copy files outside `Launchpad/` the rules also hold, once they
    /// exist.
    static let copyFiles = [
        "AssistantRunCopy.swift", "AssistantRunsNotice.swift", "ConnectionsCheckConfirmation.swift",
        "CompanionTipsPopover.swift", "SkillTrialAvailability.swift",
    ]

    @Test func theRulesReadTheCopyFiles() throws {
        let paths = try Self.copySources().map(\.path)
        #expect(paths.contains("Launchpad/LaunchpadCopy.swift"))
        #expect(paths.contains("Launchpad/LaunchpadCopy+Footer.swift"))
        #expect(try Self.strings().count > 30)
    }

    @Test func appsNeverClients() throws {
        let found = try Self.strings().filter {
            $0.text.range(of: #"\bclients?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func theEllipsisIsOneCharacterAndEndsWhatItIsOn() throws {
        let found = try Self.strings().filter { string in
            string.text.contains("...") || (string.text.contains("…") && !string.text.hasSuffix("…"))
        }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    /// Navigation and in-place controls never take the ellipsis.
    @Test func navigationTakesNoEllipsis() {
        let footer = LaunchpadCopy.Footer.self
        for title in [footer.setUpLater, footer.stop, footer.back, footer.continue, footer.keepGoing, footer.quitSetup, footer.goToHome] {
            #expect(!title.hasSuffix("…"), "\(title)")
        }
    }

    @Test func noExclamationMarks() throws {
        let found = try Self.strings().filter { $0.text.contains("!") }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func apostrophesAndQuotesAreCurly() throws {
        let found = try Self.strings().filter { $0.text.contains("'") || $0.text.contains("\\\"") }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func youNeverWe() throws {
        let found = try Self.strings().filter { $0.text.range(of: #"\bwe\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    /// "Sync" alone names nothing a person can see; its qualified forms are
    /// the place ("Settings › Sync"), the status ("Synced just now") and
    /// what it does ("sync with your other Macs", as Done's Runs on its own
    /// says it).
    @Test func syncOnlyInItsQualifiedForms() throws {
        let found = try Self.strings().filter { string in
            let bare = string.text.replacingOccurrences(of: "Settings › Sync", with: "")
                .replacingOccurrences(of: "sync with your other Macs", with: "")
                .replacingOccurrences(of: #"\bSynced\b"#, with: "", options: .regularExpression)
            return bare.range(of: #"\bsync"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func everyFailureSaysNothingWasChanged() throws {
        let failures = try Self.strings().filter(\.isFailure)
        #expect(!failures.isEmpty)
        let found = failures.filter { !$0.text.hasSuffix("Nothing was changed.") }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func appsAreNamedInTheAppOrder() throws {
        let names = ClientKind.allCases.map(\.rawValue)
        let found = try Self.strings().filter { string in
            let positions = names.compactMap { string.text.range(of: $0)?.lowerBound }
            return positions != positions.sorted()
        }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func sentenceCaseOnly() throws {
        let found = try Self.strings().filter { Self.hasTitleCase($0.text) }
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    /// Proves the case check reads Title Case where it is and nowhere else.
    @Test func theCaseCheckFindsTitleCase() {
        #expect(Self.hasTitleCase("Review Changes…"))
        #expect(Self.hasTitleCase("Set Up Later"))
        #expect(!Self.hasTitleCase("Put Agent Tooling in Applications"))
        #expect(!Self.hasTitleCase("Run it again from Settings › General."))
        #expect(!Self.hasTitleCase("Finish later? Your choices so far are saved, and Home shows where you left off."))
        #expect(!Self.hasTitleCase("Press Command-Return to install."))
        #expect(!Self.hasTitleCase("Go to Home"))
        #expect(!Self.hasTitleCase("Release Notes goes to Codex and Claude Code on every Mac"))
        #expect(!Self.hasTitleCase("Webapp Testing"))
    }

    // MARK: - Reading the copy

    /// One string literal in a copy file.
    struct CopyString: CustomStringConvertible {
        let path: String
        let line: Int
        /// The literal's words, interpolations taken out.
        let text: String
        /// Inside a `Failures` enum.
        let isFailure: Bool

        var description: String { "\(path):\(line) \"\(text)\"" }
    }

    static func copySources() throws -> [PackageSourceFile] {
        try PackageSourceFile.all(in: "AgentToolingApp").filter { file in
            let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
            return (file.path.hasPrefix("Launchpad/") && name.hasPrefix("LaunchpadCopy")) || name.hasPrefix("FinishSetup")
                || copyFiles.contains(name)
        }
    }

    /// Every string literal in the copy files, outside comments.
    static func strings() throws -> [CopyString] {
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var strings: [CopyString] = []
        for file in try copySources() {
            var failureDepth: Int?
            var depth = 0
            for (index, line) in LaunchpadSourceRulesTests.code(of: file).enumerated() {
                if line.contains("enum Failures") { failureDepth = depth }
                for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let text = String(line[range]).replacingOccurrences(
                        of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
                    strings.append(
                        CopyString(path: file.path, line: index + 1, text: text, isFailure: failureDepth.map { depth > $0 } ?? false))
                }
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if let open = failureDepth, depth <= open, !line.contains("enum Failures") { failureDepth = nil }
            }
        }
        return strings
    }

    /// Words a title may capitalise past its first and still be a sentence:
    /// names of apps, places, keys and the sample world's tools, which keep
    /// their own case.
    static let properWords: Set<String> = [
        "Agent", "Tooling", "Codex", "Claude", "Code", "Gemini", "CLI", "Kiro", "ChatGPT", "GitHub", "Mac", "Macs", "Home",
        "Settings", "General", "Sync", "Checkup", "Discover", "Library", "Apps", "Projects", "Insights", "Activity",
        "Applications", "Finder", "Command", "Return", "Escape", "Shift", "Option", "Control", "MCP", "OAuth", "Supabase",
        "Juniper", "Cedar", "Max", "Plus", "Pro", "Release", "Notes", "Frontend", "Design", "Webapp", "Testing", "Sentry",
        "Context7", "Playwright", "Linear", "Vercel", "Builder", "Db", "Migrations", "Raycast", "Terminal", "Git", "SKILL",
    ]

    /// The short words Title Case leaves in lower case.
    static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "of", "on", "or", "the", "to", "with",
    ]

    /// Whether `text` is set in Title Case: some sentence or path segment of
    /// it capitalises every word that is not a short one, and at least one of
    /// those past the first is not a name. "Review Changes…" is; "Put Agent
    /// Tooling in Applications" is a sentence whose names keep their case.
    static func hasTitleCase(_ text: String) -> Bool {
        for segment in text.components(separatedBy: CharacterSet(charactersIn: ".?:›")) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "-" })
                .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
                .filter { $0.first?.isLetter == true }
            let significant = words.filter { !smallWords.contains($0) }
            guard significant.count >= 2, significant.allSatisfy({ $0.first?.isUppercase == true }) else { continue }
            if significant.dropFirst().contains(where: { !properWords.contains($0) }) { return true }
        }
        return false
    }
}
