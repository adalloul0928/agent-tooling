import Foundation
import Testing

@testable import AgentToolingCore

struct SkillFrontmatterTests {
    @Test(arguments: [
        ("description: A wrapped description\n  continues on the next line.", "A wrapped description continues on the next line."),
        ("description: >-\n  A folded description\n  continues on the next line.", "A folded description continues on the next line."),
        ("description: >\n  A folded description\n  continues on the next line.", "A folded description continues on the next line.\n"),
        ("description: |\n  First line.\n  Second line.", "First line.\nSecond line.\n"),
        ("description: |-\n  First line.\n  Second line.", "First line.\nSecond line."),
        ("description: 'A quote: it''s useful # literally.'", "A quote: it's useful # literally."),
        (#"description: "A quote: \"use this\"\nThen continue.""#, "A quote: \"use this\"\nThen continue."),
    ])
    func decodesYAMLTextSemantics(field: String, expected: String) throws {
        let markdown = "---\nname: \"quoted-skill\" # A comment\n\(field)\n---\n# Instructions\n"
        let frontmatter = try SkillFrontmatter.parse(markdown)
        #expect(frontmatter.name == "quoted-skill")
        #expect(frontmatter.description == expected)
    }

    @Test func supportsBOMAndCRLFWithoutChangingSource() throws {
        let markdown =
            "\u{FEFF}---\r\nname: 'portable-skill'\r\ndescription: >-\r\n  A portable skill\r\n  with Windows line endings.\r\n---\r\n# Body\r\n"
        let originalBytes = Array(markdown.utf8)
        let frontmatter = try SkillFrontmatter.parse(markdown)
        #expect(frontmatter.name == "portable-skill")
        #expect(frontmatter.description == "A portable skill with Windows line endings.")
        #expect(Array(markdown.utf8) == originalBytes)
    }

    @Test func ignoresOptionalMetadataAndMarkdownBody() throws {
        let markdown = """
            ---
            name: nested-metadata
            description: |-
              Includes a separator line:
              ---
              and more text.
            metadata:
              author: Example
              tags: [one, two]
              enabled: true
            allowed-tools: [Read, "Bash(git:*)"]
            ---
            This body is not YAML: [
            ---
            description: Must not replace frontmatter.
            """
        let frontmatter = try SkillFrontmatter.parse(markdown)
        #expect(frontmatter.description == "Includes a separator line:\n---\nand more text.")
    }

    @Test func supportsQuotedRequiredKeysAndScalarAliases() throws {
        let frontmatter = try SkillFrontmatter.parse(
            """
            ---
            metadata:
              purpose: &purpose A reusable description.
            'name': aliased-skill
            "description": *purpose
            ---
            """)
        #expect(frontmatter.description == "A reusable description.")
    }

    @Test(arguments: [
        ("# No header", SkillFrontmatter.ParseError.missingHeader),
        ("---\nname: missing-end\ndescription: A skill", .unterminatedHeader),
        ("---\nname: missing-description\n---", .missingField("description")),
        ("---\ndescription: Missing name\n---", .missingField("name")),
        ("---\nname: invalid\ndescription: [broken\n---", .malformedYAML),
        ("---\n- name: invalid-root\n- description: Wrong shape\n---", .invalidRoot),
        ("---\nname: blank\ndescription: '  '\n---", .emptyField("description")),
        ("---\nname: ''\ndescription: Blank name\n---", .emptyField("name")),
        ("---\nname: same\nname: other\ndescription: Duplicate name\n---", .duplicateField("name")),
        ("---\nname: same\ndescription: One\n'description': Two\n---", .duplicateField("description")),
    ])
    func returnsActionableErrors(markdown: String, expected: SkillFrontmatter.ParseError) {
        #expect(throws: expected) { try SkillFrontmatter.parse(markdown) }
    }

    @Test(arguments: ["false", "123", "null", "[one, two]", "{nested: value}", "!!int 4"])
    func requiresStringFields(value: String) {
        #expect(throws: SkillFrontmatter.ParseError.invalidFieldType("description")) {
            try SkillFrontmatter.parse("---\nname: typed-skill\ndescription: \(value)\n---")
        }
        #expect(throws: SkillFrontmatter.ParseError.invalidFieldType("name")) {
            try SkillFrontmatter.parse("---\nname: \(value)\ndescription: A valid description\n---")
        }
    }

    @Test func boundsHeaderWithoutBoundingOrParsingBody() throws {
        let largeText = String(repeating: "x", count: SkillFrontmatter.maximumHeaderBytes)
        #expect(throws: SkillFrontmatter.ParseError.headerTooLarge) {
            try SkillFrontmatter.parse("---\nname: oversized\ndescription: \(largeText)\n---")
        }
        let frontmatter = try SkillFrontmatter.parse("---\nname: bounded\ndescription: Small header\n---\n\(largeText)")
        #expect(frontmatter.description == "Small header")
    }

    @Test func malformedYAMLErrorsDoNotExposeSource() {
        let privateText = "private-metadata-not-for-error-display"
        do {
            _ = try SkillFrontmatter.parse("---\nname: safe-errors\ndescription: [\(privateText)\n---")
            Issue.record("Malformed YAML unexpectedly parsed")
        } catch {
            #expect(error as? SkillFrontmatter.ParseError == .malformedYAML)
            #expect(!error.localizedDescription.contains(privateText))
            #expect(!String(describing: error).contains(privateText))
        }
    }
}
