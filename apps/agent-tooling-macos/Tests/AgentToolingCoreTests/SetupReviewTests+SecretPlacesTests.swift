import Foundation
import Testing

@testable import AgentToolingCore

/// What the review is never given besides conversation history: the apps'
/// sign-in files, keys and other secrets, the copies of their settings, the
/// shell captures and the logs inside the folders it may read, denied in both
/// shapes; no search tool that reaches past those folders; and, for the
/// one-app review, the web read only from the apps' own documentation, so
/// nothing it reads can be sent anywhere else.
@Suite("Setup review · sign-in and secret files")
struct SetupReviewSecretPlacesTests {
    private let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    private var policy: OperationCommandPolicy {
        OperationCommandPolicy(
            libraryURL: home.appending(path: "library"), gitBackupRoot: home.appending(path: "backup"), homeURL: home)
    }

    private func allowed(_ shape: [String]) throws -> [String] {
        let start = try #require(shape.firstIndex(of: "--allowedTools"))
        let end = try #require(shape.firstIndex(of: "--disallowedTools"))
        return Array(shape[(start + 1)..<end])
    }

    private func disallowed(_ shape: [String]) throws -> [String] {
        Array(shape[(try #require(shape.firstIndex(of: "--disallowedTools")) + 1)...])
    }

    @Test func everySignInAndSecretPlaceIsDeniedInBothShapes() throws {
        for web in [false, true] {
            let denied = try disallowed(SetupReviewCommandShapes.claude(homeURL: home, web: web))
            for rule in [
                "Read(//Users/example/.codex/auth.json*)", "Read(//Users/example/.codex/.credentials.json*)",
                "Read(//Users/example/.claude/.credentials.json*)", "Read(//Users/example/.gemini/oauth_creds.json*)",
                "Read(//Users/example/.gemini/google_accounts.json*)", "Read(//Users/example/.gemini/mcp-oauth-tokens*)",
                "Read(//Users/example/.gemini/.env*)", "Read(//Users/example/.codex/logs_*)",
                "Read(//Users/example/.kiro/.cli_bash_history*)", "Read(//Users/example/.claude/backups/**)",
                "Read(//Users/example/.claude/shell-snapshots/**)", "Read(//Users/example/.claude/session-env/**)",
                "Read(//Users/example/.claude/ide/**)", "Read(//Users/example/.claude/debug/**)",
                "Read(//Users/example/.codex/shell_snapshots/**)", "Read(//Users/example/.codex/log/**)",
                "Read(//Users/example/.kiro/crew/**)", "Read(//Users/example/.kiro/crew-auth-staging/**)",
                "Read(//Users/example/.kiro/logs/**)",
            ] {
                #expect(denied.contains(rule), "\(rule) is not denied when web is \(web)")
            }
            // Wherever a secret sits inside a readable folder, its name
            // gives it away.
            for folder in SetupReviewCommandShapes.readableFolders {
                for pattern in ["**/.env*", "**/*.key", "**/*.pem", "**/*.p12", "**/*secret*", "**/*credential*", "**/.vault/**"] {
                    #expect(denied.contains("Read(//Users/example/\(folder)/\(pattern))"), "\(folder)/\(pattern), web \(web)")
                }
            }
        }
    }

    /// Every secret place is inside a folder the review may read: a rule for
    /// anywhere else would deny nothing that was allowed.
    @Test func everySecretPlaceIsInsideAReadableFolder() {
        let readable = Set(SetupReviewCommandShapes.readableFolders)
        for place in SetupReviewCommandShapes.secretFolders + SetupReviewCommandShapes.secretFiles {
            #expect(place.split(separator: "/").first.map { readable.contains(String($0)) } == true, "\(place)")
        }
        #expect(Set(SetupReviewCommandShapes.secretFolders).isDisjoint(with: SetupReviewCommandShapes.withheldFolders))
    }

    /// No search tool is allowed bare: Glob and Grep reach the folders through
    /// the Read rules, and a fetch reaches only the apps' documentation.
    @Test func noToolIsAllowedBareThatReachesPastTheFolders() throws {
        let local = try allowed(SetupReviewCommandShapes.claude(homeURL: home, web: false))
        let web = try allowed(SetupReviewCommandShapes.claude(homeURL: home, web: true))
        for shape in [local, web] {
            #expect(!shape.contains("Glob") && !shape.contains("Grep") && !shape.contains("WebFetch"), "\(shape)")
        }
        #expect(!local.contains { $0.hasPrefix("Web") })
        #expect(web.contains("WebSearch"))
        #expect(web.filter { $0.hasPrefix("WebFetch(") } == SetupReviewCommandShapes.documentationHosts.map { "WebFetch(domain:\($0))" })
        #expect(
            Set(SetupReviewCommandShapes.documentationHosts).isSuperset(of: [
                "developers.openai.com", "docs.claude.com", "geminicli.com", "kiro.dev",
            ]),
            "each app's own documentation")
        #expect(!SetupReviewCommandShapes.documentationHosts.contains { $0.hasSuffix("github.com") })
    }

    @Test func thePolicyRefusesAShapeMissingASecretRuleOrReachingFurther() throws {
        for web in [false, true] {
            let shape = SetupReviewCommandShapes.claude(homeURL: home, web: web)
            #expect(throws: Never.self) { try policy.validate(executable: "claude", arguments: shape) }

            var missing = shape
            missing.removeAll { $0 == "Read(//Users/example/.codex/auth.json*)" }
            #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: missing) }

            for widened in ["Grep", "Glob", "WebFetch"] {
                var wide = shape
                wide.insert(widened, at: try #require(wide.firstIndex(of: "--disallowedTools")))
                #expect(throws: OperationEngineError.self, "\(widened), web \(web)") {
                    try policy.validate(executable: "claude", arguments: wide)
                }
            }
        }
    }

    /// The prompt names the secret places too: for Codex, whose read-only
    /// sandbox reaches the whole disk, it is the only guard.
    @Test func thePromptTellsTheAssistantToLeaveSecretsAlone() {
        let audit = SetupAuditReport(clients: [.claude, .codex], findings: [], counts: [:])
        let checkup = SetupReviewPrompt.render(purpose: .checkup, audit: audit, digests: [], focus: nil, clientVersions: [:])
        for place in [".codex/auth.json", ".gemini/oauth_creds.json", ".kiro/crew", ".claude/ide", "*.key", ".env*"] {
            #expect(checkup.contains(place), "\(place)")
        }
        #expect(checkup.contains("never repeat a token, key or password"))

        let review = SetupReviewPrompt.render(purpose: .clientReview, audit: audit, digests: [], focus: .codex, clientVersions: [:])
        #expect(review.contains("fetch pages only from developers.openai.com"))
    }
}
