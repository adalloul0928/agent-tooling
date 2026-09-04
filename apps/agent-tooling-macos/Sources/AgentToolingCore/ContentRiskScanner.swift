import Foundation

/// How seriously a finding undermines the promise that a human reviewed the
/// package. `risky` content is legitimate in many packages and only deserves a
/// second look. `malicious` content has no honest explanation in a skill or
/// plugin and should normally stop an install.
public enum ContentRiskSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case risky
    case malicious

    public var displayName: String {
        switch self {
        case .risky: "Risky"
        case .malicious: "Malicious"
        }
    }

    private var rank: Int {
        switch self {
        case .risky: 0
        case .malicious: 1
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// The threat families Agent Tooling looks for before a package is installed.
public enum ContentRiskCategory: String, Codable, CaseIterable, Sendable {
    /// Characters a person cannot see. The reviewed text and the executed text
    /// stop being the same thing, which defeats human review outright.
    case hiddenUnicode
    /// Instructions aimed at the agent rather than the user: role overrides,
    /// "ignore previous instructions", and requests to hide work or move
    /// credentials somewhere the operator cannot see.
    case promptInjection
    /// Content that reaches for code or data over the network at run time, so
    /// what actually executes was never part of the reviewed package.
    case remoteDependency
    /// Content that runs as a program rather than being read as instructions.
    case executableContent

    public var displayName: String {
        switch self {
        case .hiddenUnicode: "Hidden characters"
        case .promptInjection: "Prompt injection"
        case .remoteDependency: "Remote dependency"
        case .executableContent: "Executable content"
        }
    }

    public var symbolName: String {
        switch self {
        case .hiddenUnicode: "eye.trianglebadge.exclamationmark"
        case .promptInjection: "text.badge.xmark"
        case .remoteDependency: "network.badge.shield.half.filled"
        case .executableContent: "terminal"
        }
    }
}

/// One reviewable observation about package content. A finding is never a
/// verdict: it is shown next to the approve button so the operator decides.
public struct ContentRiskFinding: Identifiable, Codable, Hashable, Sendable {
    public var category: ContentRiskCategory
    public var severity: ContentRiskSeverity
    public var relativePath: String
    /// 1-based line number when the finding came from readable text.
    public var line: Int?
    public var headline: String
    /// A bounded, redacted excerpt with invisible characters spelled out.
    public var evidence: String
    public var guidance: String

    public init(
        category: ContentRiskCategory,
        severity: ContentRiskSeverity,
        relativePath: String,
        line: Int? = nil,
        headline: String,
        evidence: String,
        guidance: String
    ) {
        self.category = category
        self.severity = severity
        self.relativePath = relativePath
        self.line = line
        self.headline = headline
        self.evidence = evidence
        self.guidance = guidance
    }

    public var id: String { "\(category.rawValue)|\(relativePath)|\(line ?? 0)|\(headline)" }

    public var location: String { line.map { "\(relativePath):\($0)" } ?? relativePath }
}

/// The complete result of scanning one package tree.
public struct ContentRiskReport: Codable, Hashable, Sendable {
    public var findings: [ContentRiskFinding]
    public var filesScanned: Int
    /// Bounded, package-relative explanations for content that was not fully
    /// inspected. These are safe to show beside the disabled Run button.
    public var coverageNotes: [String]
    /// True when the scan stopped early at a bound. The report is then a
    /// partial answer and says so rather than implying the package is clean.
    public var reachedScanLimit: Bool

    public init(
        findings: [ContentRiskFinding] = [],
        filesScanned: Int = 0,
        coverageNotes: [String] = [],
        reachedScanLimit: Bool = false
    ) {
        self.findings = findings
        self.filesScanned = filesScanned
        self.coverageNotes = coverageNotes
        self.reachedScanLimit = reachedScanLimit
    }

    /// A report is complete only when every candidate file fit within the
    /// scanner's file, byte, line, and finding bounds. A partial report must
    /// never borrow the reassuring semantics of a clean one.
    public var isComplete: Bool { !reachedScanLimit }

    public var isClean: Bool { findings.isEmpty && isComplete }

    public var requiresAttention: Bool { !isClean }

    public var maliciousCount: Int { findings.count { $0.severity == .malicious } }

    public var riskyCount: Int { findings.count { $0.severity == .risky } }

    public var highestSeverity: ContentRiskSeverity? { findings.map(\.severity).max() }

    public var headline: String {
        guard !findings.isEmpty else {
            let scanned = "\(filesScanned) file\(filesScanned == 1 ? "" : "s")"
            return reachedScanLimit
                ? "No content risks in the \(scanned) that could be read. Some of this package was too large, too long, or not readable as text, so this is a partial answer rather than a clean bill."
                : "No content risks found in \(scanned)."
        }
        var parts: [String] = []
        if maliciousCount > 0 { parts.append("\(maliciousCount) malicious") }
        if riskyCount > 0 { parts.append("\(riskyCount) risky") }
        let total = findings.count
        return
            "\(parts.joined(separator: " · ")) finding\(total == 1 ? "" : "s") in \(filesScanned) scanned file\(filesScanned == 1 ? "" : "s")."
    }
}

/// Inspects package content for the risk taxonomy above.
///
/// The scanner never removes, rewrites, or quietly filters anything. A
/// review-first app that silently dropped a suspicious file would be lying
/// about what the operator approved, so every observation is surfaced instead.
public enum ContentRiskScanner {
    public struct Limits: Hashable, Sendable {
        public var maximumFiles: Int
        public var maximumFileBytes: Int
        public var maximumTotalBytes: Int
        public var maximumLines: Int
        public var maximumFindings: Int

        public init(
            maximumFiles: Int = 2_000,
            maximumFileBytes: Int = 1_024 * 1_024,
            maximumTotalBytes: Int = 32 * 1_024 * 1_024,
            maximumLines: Int = 20_000,
            maximumFindings: Int = 200
        ) {
            self.maximumFiles = maximumFiles
            self.maximumFileBytes = maximumFileBytes
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumLines = maximumLines
            self.maximumFindings = maximumFindings
        }
    }

    /// Scans a package tree. Never throws: an unreadable package still has to
    /// produce a reviewable answer rather than an empty, falsely clean one.
    public static func scan(
        directory root: URL,
        fileManager: FileManager = .default,
        limits: Limits = Limits()
    ) -> ContentRiskReport {
        let normalizedRoot = root.standardizedFileURL
        var enumerationNotes: [String] = []
        guard
            let enumerator = fileManager.enumerator(
                at: normalizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [],
                errorHandler: { item, _ in
                    let relative = relativePath(of: item, under: normalizedRoot) ?? item.lastPathComponent
                    appendCoverageNote("\(relative) could not be enumerated completely.", to: &enumerationNotes)
                    return true
                }
            )
        else {
            return ContentRiskReport(
                findings: [
                    ContentRiskFinding(
                        category: .executableContent,
                        severity: .risky,
                        relativePath: normalizedRoot.lastPathComponent,
                        headline: "This location could not be read for review",
                        evidence: normalizedRoot.path(percentEncoded: false),
                        guidance: "Agent Tooling could not list the contents, so nothing here has been reviewed."
                    )
                ],
                filesScanned: 0,
                reachedScanLimit: true
            )
        }

        var findings: [ContentRiskFinding] = []
        var filesScanned = 0
        var bytesScanned = 0
        var reachedLimit = false
        var coverageNotes: [String] = []
        while let item = enumerator.nextObject() as? URL {
            guard filesScanned < limits.maximumFiles, findings.count < limits.maximumFindings else {
                reachedLimit = true
                appendCoverageNote(
                    findings.count >= limits.maximumFindings
                        ? "The finding limit was reached; remaining package entries were not inspected."
                        : "The file limit was reached before \(relativePath(of: item, under: normalizedRoot) ?? item.lastPathComponent).",
                    to: &coverageNotes
                )
                break
            }
            guard
                let values = try? item.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                let relativePath = Self.relativePath(of: item, under: normalizedRoot)
            else {
                reachedLimit = true
                appendCoverageNote("An entry named \(item.lastPathComponent) could not be inspected.", to: &coverageNotes)
                continue
            }
            if values.isDirectory == true, Self.skippedDirectoryNames.contains(item.lastPathComponent) {
                // The installer copies these subtrees even though scanning them
                // would be prohibitively noisy. Do not silently turn that
                // performance exclusion into a clean review: any copied byte
                // that was not inspected must block execution.
                reachedLimit = true
                appendCoverageNote(
                    "\(relativePath) was not inspected because that generated or dependency subtree is excluded from content review.",
                    to: &coverageNotes
                )
                enumerator.skipDescendants()
                continue
            }
            if values.isSymbolicLink == true {
                // A link points outside whatever the reviewer just read.
                findings.append(
                    ContentRiskFinding(
                        category: .remoteDependency,
                        severity: .risky,
                        relativePath: relativePath,
                        headline: "Symbolic link leaves the reviewed package",
                        evidence: relativePath,
                        guidance: "What this resolves to is not part of the content you reviewed."
                    ))
                continue
            }
            guard values.isRegularFile == true else { continue }
            filesScanned += 1
            findings.append(contentsOf: executableFindings(for: item, relativePath: relativePath, fileManager: fileManager))
            guard let size = values.fileSize, size >= 0, size <= limits.maximumFileBytes else {
                reachedLimit = true
                appendCoverageNote("\(relativePath) exceeded the per-file review limit.", to: &coverageNotes)
                continue
            }
            guard size <= limits.maximumTotalBytes - min(bytesScanned, limits.maximumTotalBytes) else {
                reachedLimit = true
                appendCoverageNote("The package exceeded the total content review limit before \(relativePath).", to: &coverageNotes)
                break
            }
            bytesScanned += size
            // A file the scanner cannot decode has not been checked. Counting it
            // as scanned and saying nothing would let one invalid byte in a
            // SKILL.md buy a "no content risks found" verdict.
            guard let data = try? Data(contentsOf: item), let text = String(data: data, encoding: .utf8) else {
                reachedLimit = true
                appendCoverageNote("\(relativePath) was unreadable or was not valid UTF-8 text.", to: &coverageNotes)
                continue
            }
            let inspection = Self.inspect(text: text, relativePath: relativePath, limits: limits)
            findings.append(contentsOf: inspection.findings)
            if inspection.wasTruncated {
                reachedLimit = true
                appendCoverageNote("\(relativePath) exceeded a line or line-length review limit.", to: &coverageNotes)
            }
        }

        if !enumerationNotes.isEmpty {
            reachedLimit = true
            for note in enumerationNotes { appendCoverageNote(note, to: &coverageNotes) }
        }
        let bounded = Array(findings.prefix(limits.maximumFindings))
        return ContentRiskReport(
            findings: bounded,
            filesScanned: filesScanned,
            coverageNotes: coverageNotes,
            reachedScanLimit: reachedLimit || bounded.count < findings.count
        )
    }

    private static func appendCoverageNote(_ note: String, to notes: inout [String]) {
        guard notes.count < 32, !notes.contains(note) else { return }
        notes.append(note)
    }

    /// Scans one piece of text. Exposed separately so the taxonomy can be
    /// exercised without touching the file system.
    public static func findings(
        inText text: String,
        relativePath: String,
        limits: Limits = Limits()
    ) -> [ContentRiskFinding] {
        inspect(text: text, relativePath: relativePath, limits: limits).findings
    }

    /// One text's findings, plus whether a bound stopped the scan short of the
    /// whole text. `scan` needs that second half: pattern rules see only the
    /// first `maximumScannedLineCharacters` of a line and the first
    /// `maximumLines` lines, so padding is enough to push an instruction out of
    /// range. A report that then says "no content risks found" is wrong, not
    /// merely incomplete.
    static func inspect(
        text: String,
        relativePath: String,
        limits: Limits = Limits()
    ) -> (findings: [ContentRiskFinding], wasTruncated: Bool) {
        var findings: [ContentRiskFinding] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var wasTruncated = lines.count > limits.maximumLines
        for (index, rawLine) in lines.prefix(limits.maximumLines).enumerated() {
            let number = index + 1
            let line = String(rawLine)
            // A byte-order mark at the very start of a file is ordinary.
            let inspected = number == 1 ? Self.strippingLeadingByteOrderMark(line) : line
            if inspected.count > Self.maximumScannedLineCharacters { wasTruncated = true }
            findings.append(contentsOf: hiddenCharacterFindings(in: inspected, relativePath: relativePath, line: number))
            findings.append(contentsOf: patternFindings(in: inspected, relativePath: relativePath, line: number))
            if number == 1, inspected.hasPrefix("#!") {
                findings.append(
                    ContentRiskFinding(
                        category: .executableContent,
                        severity: .risky,
                        relativePath: relativePath,
                        line: 1,
                        headline: "Runs as a program, not as instructions",
                        evidence: Self.excerpt(inspected),
                        guidance: "A shebang means this file is executed. Read it as code before approving the install."
                    ))
            }
            guard findings.count < limits.maximumFindings else { break }
        }
        return (Array(findings.prefix(limits.maximumFindings)), wasTruncated)
    }

    // MARK: - Hidden Unicode

    /// Characters that occupy no visual space. Text a reviewer reads and text
    /// an agent receives stop matching, which is the whole attack.
    private static let zeroWidthScalars: Set<Unicode.Scalar> = [
        "\u{00AD}", "\u{034F}", "\u{061C}", "\u{115F}", "\u{1160}", "\u{180E}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}",
        "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}", "\u{2800}", "\u{3164}", "\u{FEFF}", "\u{FFA0}",
    ]

    /// Bidirectional overrides reorder rendered text without changing bytes,
    /// so a line can read as a comment and execute as a command.
    private static let bidirectionalScalars: Set<Unicode.Scalar> = [
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    private static let tagBlockRange: ClosedRange<UInt32> = 0xE0000...0xE007F

    /// Variation Selectors Supplement. 240 invisible code points with no use in
    /// a skill or plugin, which is exactly what makes them the other standard
    /// carrier for smuggled text alongside the Tags block.
    private static let variationSelectorSupplementRange: ClosedRange<UInt32> = 0xE0100...0xE01EF

    /// The original variation selectors. Unlike the supplement these are
    /// everyday characters — U+FE0F is what makes an emoji render in colour —
    /// so a single one proves nothing and only a run is worth reporting.
    private static let variationSelectorRange: ClosedRange<UInt32> = 0xFE00...0xFE0F

    /// A run this long is a payload rather than text presentation.
    private static let variationSelectorRunThreshold = 4

    private static func hiddenCharacterFindings(in line: String, relativePath: String, line number: Int) -> [ContentRiskFinding] {
        var zeroWidth: [Unicode.Scalar] = []
        var bidirectional: [Unicode.Scalar] = []
        var tagScalars: [Unicode.Scalar] = []
        var variationSelectors: [Unicode.Scalar] = []
        var currentRun = 0
        var longestVariationSelectorRun = 0
        for scalar in line.unicodeScalars {
            if variationSelectorRange.contains(scalar.value) || variationSelectorSupplementRange.contains(scalar.value) {
                currentRun += 1
                longestVariationSelectorRun = max(longestVariationSelectorRun, currentRun)
                if variationSelectorSupplementRange.contains(scalar.value) { variationSelectors.append(scalar) }
                continue
            }
            currentRun = 0
            if tagBlockRange.contains(scalar.value) {
                tagScalars.append(scalar)
            } else if bidirectionalScalars.contains(scalar) {
                bidirectional.append(scalar)
            } else if zeroWidthScalars.contains(scalar) {
                zeroWidth.append(scalar)
            }
        }
        let smuggledVariationSelectors =
            !variationSelectors.isEmpty || longestVariationSelectorRun >= variationSelectorRunThreshold
        guard !zeroWidth.isEmpty || !bidirectional.isEmpty || !tagScalars.isEmpty || smuggledVariationSelectors else {
            return []
        }

        var findings: [ContentRiskFinding] = []
        if smuggledVariationSelectors {
            let count = max(variationSelectors.count, longestVariationSelectorRun)
            findings.append(
                ContentRiskFinding(
                    category: .hiddenUnicode,
                    severity: .malicious,
                    relativePath: relativePath,
                    line: number,
                    headline: "\(count) invisible variation selector\(count == 1 ? "" : "s") carry hidden text",
                    evidence: Self.visibleExcerpt(line),
                    guidance:
                        "Variation selectors take no space on screen but encode a byte each. An agent reads them; you did not."
                ))
        }
        if !tagScalars.isEmpty {
            let decoded = Self.decodedTagText(tagScalars)
            findings.append(
                ContentRiskFinding(
                    category: .hiddenUnicode,
                    severity: .malicious,
                    relativePath: relativePath,
                    line: number,
                    headline: "\(tagScalars.count) invisible Unicode Tag character\(tagScalars.count == 1 ? "" : "s") smuggle hidden text",
                    evidence: decoded.isEmpty
                        ? Self.visibleExcerpt(line)
                        : "Decodes to: \(Self.excerpt(SensitiveValueRedactor.redact(decoded)))",
                    guidance:
                        "Tag-block characters render as nothing. An agent still reads them, so this text was never part of what you reviewed."
                ))
        }
        if !bidirectional.isEmpty {
            findings.append(
                ContentRiskFinding(
                    category: .hiddenUnicode,
                    severity: .malicious,
                    relativePath: relativePath,
                    line: number,
                    headline: "Bidirectional override characters reorder this line",
                    evidence: Self.visibleExcerpt(line),
                    guidance: "What this line displays and what it actually contains are different. Read the raw bytes before approving."
                ))
        }
        if !zeroWidth.isEmpty {
            findings.append(
                ContentRiskFinding(
                    category: .hiddenUnicode,
                    severity: .risky,
                    relativePath: relativePath,
                    line: number,
                    headline: "\(zeroWidth.count) zero-width character\(zeroWidth.count == 1 ? "" : "s") in this line",
                    evidence: Self.visibleExcerpt(line),
                    guidance:
                        "Zero-width characters are invisible on screen. They are sometimes accidental and sometimes a way to hide text."
                ))
        }
        return findings
    }

    private static func decodedTagText(_ scalars: [Unicode.Scalar]) -> String {
        var decoded = ""
        for scalar in scalars {
            let offset = scalar.value - 0xE0000
            guard (0x20...0x7E).contains(offset), let ascii = Unicode.Scalar(offset) else { continue }
            decoded.unicodeScalars.append(ascii)
        }
        return decoded
    }

    // MARK: - Pattern rules

    private struct PatternRule: Sendable {
        var category: ContentRiskCategory
        var severity: ContentRiskSeverity
        var pattern: String
        var headline: String
        var guidance: String
        /// Optional second pattern that must also match on the same line. It
        /// keeps ordinary prose that merely mentions a URL from being flagged.
        var requiresCompanion: String?
        /// Optional pattern that clears the finding, such as a pinned checksum.
        var clearedBy: String?
    }

    private static let patternRules: [PatternRule] = [
        PatternRule(
            category: .promptInjection,
            severity: .risky,
            pattern: "(?i)\\b(ignore|disregard|forget)\\b[^\\n]{0,32}\\b(previous|prior|above|preceding|earlier|all)\\b[^\\n]{0,32}"
                + "\\b(instruction|instructions|prompt|prompts|rule|rules|direction|directions|message|messages|context)\\b",
            headline: "Attempts to override earlier instructions",
            guidance: "Skill text that tells an agent to discard its instructions is aimed at the agent, not at you.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .promptInjection,
            severity: .risky,
            pattern: "(?i)\\b(you are now|act as|pretend to be|from now on you)\\b[^\\n]{0,48}"
                + "\\b(developer mode|dan|jailbreak|unrestricted|no restrictions|without restrictions|god mode|admin)\\b",
            headline: "Role-override attempt",
            guidance: "This tries to change what the agent believes it is allowed to do.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .promptInjection,
            severity: .risky,
            pattern: "(?i)(<\\|(im_start|im_end|system)\\|>|\\bnew\\s+system\\s+(prompt|instructions|message)\\b"
                + "|\\boverride\\s+(the\\s+)?(system|developer)\\s+(prompt|instructions|message)\\b)",
            headline: "Forged system-prompt markers",
            guidance: "Chat-protocol markers inside package text try to impersonate the client's own system message.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .promptInjection,
            severity: .malicious,
            pattern: "(?i)\\b(do not|don't|never)\\b[^\\n]{0,32}\\b(tell|inform|mention|show|reveal|report|notify|ask)\\b"
                + "[^\\n]{0,24}\\b(the\\s+)?(user|human|operator|owner)\\b",
            headline: "Instructs the agent to hide work from you",
            guidance: "Concealment from the person reviewing has no legitimate purpose in a skill.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .promptInjection,
            severity: .malicious,
            pattern: "(?i)\\b(without|before)\\b[^\\n]{0,24}\\b(asking|telling|informing|notifying|confirming with)\\b"
                + "[^\\n]{0,24}\\b(the\\s+)?(user|human|operator|owner)\\b",
            headline: "Instructs the agent to act without asking you",
            guidance: "This removes the approval step this app exists to provide.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .promptInjection,
            severity: .malicious,
            pattern: "(?i)(\\.env\\b|\\.ssh/|id_rsa|\\.aws/credentials|keychain|\\bcookies?\\b"
                + "|\\b[A-Z0-9_]*(API_KEY|ACCESS_TOKEN|AUTH_TOKEN|CLIENT_SECRET|SECRET_KEY)\\b)",
            headline: "Moves credentials off this Mac",
            guidance: "The line reads a secret location and sends it somewhere. Treat this as an exfiltration attempt.",
            requiresCompanion: "(?i)(\\bcurl\\b|\\bwget\\b|\\bnc\\b|\\bfetch\\s*\\(|requests\\.(post|put)|https?://"
                + "|\\bwebhook\\b|\\bmail\\b|\\bupload\\b|\\bexfiltrat)",
            clearedBy: nil
        ),
        PatternRule(
            category: .remoteDependency,
            severity: .malicious,
            pattern: "(?i)\\b(curl|wget)\\b[^\\n|]{0,200}\\|\\s*(sudo\\s+)?(ba|z|k|c|d)?sh\\b",
            headline: "Downloads and runs a remote script",
            guidance: "Whatever that server returns runs with your permissions and was never part of this review.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .remoteDependency,
            severity: .risky,
            pattern: "(?i)\\b(curl|wget|iwr|Invoke-WebRequest)\\b[^\\n]{0,200}http://",
            headline: "Fetches content over plain HTTP",
            guidance: "An unencrypted download can be replaced in transit by anyone on the network path.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .remoteDependency,
            severity: .risky,
            pattern: "https?://(\\d{1,3}\\.){3}\\d{1,3}(:\\d+)?(/|\\b)",
            headline: "Downloads from a bare IP address",
            guidance: "A raw address has no certificate identity and no owner you can check.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .remoteDependency,
            severity: .risky,
            pattern: "(?i)https?://(bit\\.ly|tinyurl\\.com|t\\.co|goo\\.gl|is\\.gd|rebrand\\.ly|cutt\\.ly|shorturl\\.at|rb\\.gy)/",
            headline: "Shortened link hides its real destination",
            guidance: "You cannot tell what this resolves to without following it.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
        PatternRule(
            category: .remoteDependency,
            severity: .risky,
            pattern: "(?i)\\b(curl|wget|iwr|Invoke-WebRequest)\\b[^\\n]{0,200}https://",
            headline: "Unverifiable remote dependency",
            guidance: "Nothing pins what this download returns, so the reviewed package and the installed behaviour can diverge.",
            requiresCompanion: nil,
            clearedBy: "(?i)(sha256|sha512|--checksum|integrity=|gpg\\s+--verify|\\bsigstore\\b|\\bcosign\\b)"
        ),
        PatternRule(
            category: .remoteDependency,
            severity: .risky,
            pattern: "(?i)\\b(pip|pip3|uv)\\s+install\\s+(git\\+)?https?://|\\bnpm\\s+(install|i)\\s+(git\\+)?https?://"
                + "|\\bgem\\s+install\\s+--source\\s+https?://",
            headline: "Installs a package straight from a URL",
            guidance: "This bypasses the registry checks a named dependency would get.",
            requiresCompanion: nil,
            clearedBy: nil
        ),
    ]

    /// How much of a single line the pattern rules read. Regex cost grows with
    /// line length, so a bound is necessary — but `inspect` reports when one is
    /// hit, because everything past it is unexamined rather than clean.
    static let maximumScannedLineCharacters = 8_000

    private static func patternFindings(in line: String, relativePath: String, line number: Int) -> [ContentRiskFinding] {
        let bounded =
            line.count > Self.maximumScannedLineCharacters
            ? String(line.prefix(Self.maximumScannedLineCharacters)) : line
        guard !bounded.isEmpty else { return [] }
        var findings: [ContentRiskFinding] = []
        for rule in patternRules {
            guard matches(rule.pattern, in: bounded) else { continue }
            if let companion = rule.requiresCompanion, !matches(companion, in: bounded) { continue }
            if let cleared = rule.clearedBy, matches(cleared, in: bounded) { continue }
            findings.append(
                ContentRiskFinding(
                    category: rule.category,
                    severity: rule.severity,
                    relativePath: relativePath,
                    line: number,
                    headline: rule.headline,
                    evidence: Self.excerpt(SensitiveValueRedactor.redact(bounded)),
                    guidance: rule.guidance
                ))
        }
        return findings
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Executable content

    private static func executableFindings(
        for url: URL,
        relativePath: String,
        fileManager: FileManager
    ) -> [ContentRiskFinding] {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)),
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
            permissions & 0o111 != 0
        else { return [] }
        return [
            ContentRiskFinding(
                category: .executableContent,
                severity: .risky,
                relativePath: relativePath,
                headline: "Marked executable",
                evidence: String(format: "mode %o", permissions & 0o777),
                guidance: "This file can be run directly. Read it as code, not as documentation."
            )
        ]
    }

    // MARK: - Helpers

    private static let skippedDirectoryNames: Set<String> = [".git", ".build", "node_modules", ".venv"]

    private static func strippingLeadingByteOrderMark(_ line: String) -> String {
        guard line.unicodeScalars.first == "\u{FEFF}" else { return line }
        var scalars = line.unicodeScalars
        scalars.removeFirst()
        return String(scalars)
    }

    private static func excerpt(_ text: String, limit: Int = 160) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// Rewrites invisible characters as their code points so the excerpt shows
    /// the reviewer exactly what the rendered line was hiding.
    private static func visibleExcerpt(_ text: String, limit: Int = 160) -> String {
        var rendered = ""
        for scalar in text.unicodeScalars {
            if tagBlockRange.contains(scalar.value) || variationSelectorSupplementRange.contains(scalar.value)
                || variationSelectorRange.contains(scalar.value) || bidirectionalScalars.contains(scalar)
                || zeroWidthScalars.contains(scalar)
            {
                rendered += String(format: "<U+%04X>", scalar.value)
            } else {
                rendered.unicodeScalars.append(scalar)
            }
        }
        return excerpt(SensitiveValueRedactor.redact(rendered), limit: limit)
    }

    private static func relativePath(of child: URL, under root: URL) -> String? {
        let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = child.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard childPath.hasPrefix(rootPath + "/") else { return nil }
        return String(childPath.dropFirst(rootPath.count + 1))
    }
}
