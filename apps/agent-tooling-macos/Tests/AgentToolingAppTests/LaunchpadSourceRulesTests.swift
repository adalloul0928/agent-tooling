import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The setup stage's code rules (plan §8.6), held over the code itself: no
/// raw number in a stage view, no wrapping hack, no second door to the
/// resource bundle, and the hero size kept to one title per stage screen.
///
/// The stage's files are everything under `Launchpad/`, every new App file the
/// plan lists, and any file that names itself a Launchpad contract or
/// placeholder in its first line, so a later package's new file is held to
/// the rules from its first commit.
@Suite("Launchpad source rules")
struct LaunchpadSourceRulesTests {
    /// The App files outside `Launchpad/` the stage added.
    static let newAppFiles: Set<String> = [
        "AppAppearance.swift", "CommandLineDisplay.swift", "Components+Keys.swift", "Components+Stage.swift",
        "DeploymentOutcome.swift", "HelperServices.swift", "MacModel.swift", "MoveToApplications.swift", "ScopedPlanReview.swift",
        "SyncStatusProvider.swift",
        "WorkspaceDeploymentSession+Connections.swift", "WorkspaceDeploymentSession+WhatIf.swift",
        "WorkspaceSetupSession+Adoption.swift", "WorkspaceSetupSession+LibraryFacts.swift",
        // Home's Finish setting up card and what it reads (WP9).
        "CompanionPresence.swift", "CompanionTipsPopover.swift", "ConnectionsCheckConfirmation.swift",
        "FinishSetupCard.swift", "FinishSetupChecklist.swift", "FinishSetupChip.swift", "FinishSetupFacts.swift",
        "FinishSetupTracker.swift", "SkillTrialAvailability.swift",
    ]

    /// Where a raw number is a design decision made in a view instead of in
    /// `DesignTokens.swift`.
    static let measuredCalls = [
        ".frame(", ".padding(", ".offset(", ".opacity(", ".system(size:", ".delay(", ".shadow(", ".scaleEffect(",
        ".position(", "Task.sleep(",
    ]
    static let measuredArguments = ["spacing:", "cornerRadius:", "lineWidth:", "duration:"]

    @Test func noStageViewTypesANumber() throws {
        let found = try Self.stageFiles().flatMap(Self.rawNumbers(in:))
        #expect(found.isEmpty, "raw numbers in stage views: \(found.joined(separator: "; "))")
    }

    @Test func theRulesScanTheStagesFiles() throws {
        let paths = Set(try Self.stageFiles().map(\.path))
        #expect(paths.contains("Launchpad/LaunchpadFlow.swift"))
        #expect(paths.contains("Launchpad/Stage/StageFooterBar.swift"))
        #expect(paths.contains("Components+Keys.swift"))
        #expect(paths.isSuperset(of: Self.newAppFiles), "a listed new file is missing: \(Self.newAppFiles.subtracting(paths))")
        #expect(!paths.contains("DesignTokens.swift"))
        #expect(!paths.contains("Theme.swift"))
    }

    /// Proves the scan reads what it says: a number in a measured call is
    /// found, on its own line, even when the call spans lines; a token, 0, 1,
    /// a comment and a number elsewhere are not.
    @Test func theNumberScanFindsWhatItShould() {
        let file = PackageSourceFile(
            path: "Launchpad/Example.swift",
            lines: [
                "Text(\"Step 2\")", ".padding(.top, Space.lg)", ".frame(width: 0, height: 1)", "// .frame(width: 20)",
                ".opacity(0.5)", ".padding(", "    .horizontal,", "    14", ")", "HStack(spacing: Space.xs) {",
                ".offset(y: StageLayout.Poster.markTop) // 40 on the stage", "VStack(spacing: 3) {",
                ".animation(AgentMotion.selection.delay(0.3), value: x)",
            ])

        let found = Self.rawNumbers(in: file)

        #expect(
            found == [
                "Launchpad/Example.swift:5 .opacity( 0.5", "Launchpad/Example.swift:8 .padding( 14",
                "Launchpad/Example.swift:12 spacing: 3", "Launchpad/Example.swift:13 .delay( 0.3",
            ])
    }

    @Test func noViewInTheAppWrapsWithTheFixedSizeHack() throws {
        let found = try Self.lines(in: try PackageSourceFile.all(in: "AgentToolingApp")) { line in
            line.contains("fixedSize(horizontal: false, vertical: true)")
        }
        #expect(found.isEmpty, "use .wrapsLines() at \(found.joined(separator: ", "))")
    }

    @Test func onlyAppResourcesReachesTheResourceBundle() throws {
        let module = try NSRegularExpression(pattern: #"Bundle\.module\b|(?<![A-Za-z0-9_])\.module\b"#)
        let files = try PackageSourceFile.all(in: "AgentToolingApp").filter { $0.path != "AppResources.swift" }
        let found = try Self.lines(in: files) { line in
            module.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        #expect(found.isEmpty, "Bundle.module outside AppResources at \(found.joined(separator: ", "))")
    }

    /// One hero-sized title per stage screen, and the hero size nowhere but
    /// the stage.
    @Test func theHeroSizeIsOneTitlePerScreenAndOnlyOnTheStage() throws {
        let hero = try NSRegularExpression(pattern: #"AgentFont\.hero\b|StageHeader\(\.hero\b"#)
        func count(_ line: String) -> Int { hero.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) }
        for file in try PackageSourceFile.all(in: "AgentToolingApp") where file.path.hasPrefix("Launchpad/") {
            let uses = Self.code(of: file).reduce(0) { $0 + count($1) }
            #expect(uses <= 1, "\(file.path) sets \(uses) hero titles")
        }
        let outside = try PackageSourceFile.all(in: "AgentToolingApp").filter {
            !$0.path.hasPrefix("Launchpad/") && $0.path != "DesignTokens.swift"
        }
        let found = try Self.lines(in: outside) { count($0) > 0 }
        #expect(found.isEmpty, "the hero size outside the stage at \(found.joined(separator: ", "))")
    }

    // MARK: - The scan

    /// The files the stage rules hold: `Launchpad/`, the listed new files and
    /// every file marked as a Launchpad contract or placeholder, less the
    /// token files where numbers belong.
    static func stageFiles() throws -> [PackageSourceFile] {
        try PackageSourceFile.all(in: "AgentToolingApp").filter { file in
            guard file.path != "DesignTokens.swift", file.path != "Theme.swift" else { return false }
            return file.path.hasPrefix("Launchpad/") || newAppFiles.contains(file.path)
                || file.lines.first?.hasPrefix("// Launchpad") == true
        }
    }

    /// Each raw number other than 0 or 1 in a measured call or argument, as
    /// "path:line pattern number".
    static func rawNumbers(in file: PackageSourceFile) -> [String] {
        let code = code(of: file)
        let text = code.joined(separator: "\n")
        let characters = Array(text)
        var lineStarts: [Int] = [0]
        for (index, character) in characters.enumerated() where character == "\n" { lineStarts.append(index + 1) }
        func line(at offset: Int) -> Int { (lineStarts.lastIndex { $0 <= offset } ?? 0) + 1 }

        var found: [(offset: Int, entry: String)] = []
        for pattern in measuredCalls + measuredArguments {
            let needle = Array(pattern)
            var index = 0
            while index + needle.count <= characters.count {
                guard Array(characters[index..<(index + needle.count)]) == needle else {
                    index += 1
                    continue
                }
                let start = index + needle.count
                let end = argumentEnd(in: characters, from: start, wholeCall: pattern.hasSuffix("(") || pattern.contains("("))
                let segment = String(characters[start..<end])
                for (numberOffset, number) in numbers(in: segment) where !["0", "1", "0.0", "1.0"].contains(number) {
                    found.append((start + numberOffset, "\(file.path):\(line(at: start + numberOffset)) \(pattern) \(number)"))
                }
                index = start
            }
        }
        return found.sorted { $0.offset < $1.offset }.map(\.entry)
    }

    /// Where the argument list (or the one argument) starting at `start` ends:
    /// the closing parenthesis of the call, or the next top-level comma.
    private static func argumentEnd(in characters: [Character], from start: Int, wholeCall: Bool) -> Int {
        var depth = 0
        var index = start
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "(", "[", "{": depth += 1
                case ")", "]", "}":
                    if depth == 0 { return index }
                    depth -= 1
                case "," where depth == 0 && !wholeCall: return index
                default: break
                }
            }
            index += 1
        }
        return characters.count
    }

    /// The numeric literals in `segment` outside string literals, with their
    /// offsets: never a digit that is part of a name (`h1`, `Context7`).
    private static func numbers(in segment: String) -> [(Int, String)] {
        let characters = Array(segment)
        var result: [(Int, String)] = []
        var index = 0
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 1 } else if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                index += 1
                continue
            }
            let previous = index > 0 ? characters[index - 1] : " "
            if character.isNumber, !(previous.isLetter || previous.isNumber || previous == "_" || previous == ".") {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_" {
                    end += 1
                }
                let next = end < characters.count ? characters[end] : " "
                if !(next.isLetter || next == "_") {
                    result.append((index, String(characters[index..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "."))))
                }
                index = end
                continue
            }
            index += 1
        }
        return result
    }

    /// The file's lines with comments taken out: a line that is only a
    /// comment is empty, and a trailing comment is cut, outside strings.
    static func code(of file: PackageSourceFile) -> [String] {
        file.lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return "" }
            var inString = false
            var previous: Character = " "
            var kept = ""
            for character in line {
                if character == "\"", previous != "\\" { inString.toggle() }
                if !inString, character == "/", previous == "/" {
                    kept.removeLast()
                    return kept
                }
                kept.append(character)
                previous = character
            }
            return kept
        }
    }

    /// "path:line" for each line of code in `files` that `matches`.
    private static func lines(in files: [PackageSourceFile], where matches: (String) -> Bool) throws -> [String] {
        files.flatMap { file in
            code(of: file).enumerated().compactMap { index, line in matches(line) ? "\(file.path):\(index + 1)" : nil }
        }
    }
}
