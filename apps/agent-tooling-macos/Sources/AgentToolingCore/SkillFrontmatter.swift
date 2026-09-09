import Foundation
import Yams

/// Validated skill metadata. Parsing never rewrites the Markdown or interprets its body as YAML.
public struct SkillFrontmatter: Equatable, Sendable {
    public let name: String
    public let description: String

    static let maximumHeaderBytes = 64 * 1_024

    public enum ParseError: Error, LocalizedError, Equatable, Sendable {
        case missingHeader
        case unterminatedHeader
        case headerTooLarge
        case malformedYAML
        case invalidRoot
        case missingField(String)
        case invalidFieldType(String)
        case emptyField(String)
        case duplicateField(String)

        public var errorDescription: String? {
            switch self {
            case .missingHeader:
                "Start SKILL.md with a YAML frontmatter header delimited by --- lines."
            case .unterminatedHeader:
                "Close the YAML frontmatter header with a --- line before the skill instructions."
            case .headerTooLarge:
                "Keep the YAML frontmatter header within 64 KB; move long instructions into the Markdown body."
            case .malformedYAML:
                "The skill frontmatter is not valid YAML. Check indentation, quoting, and duplicate keys."
            case .invalidRoot:
                "Use a YAML mapping in the skill frontmatter, with name and description fields."
            case .missingField(let field):
                "Add a \(field) field to the skill frontmatter."
            case .invalidFieldType(let field):
                "The skill frontmatter \(field) must be text. Quote values that YAML interprets as numbers, booleans, or null."
            case .emptyField(let field):
                "Enter non-empty text for the skill frontmatter \(field)."
            case .duplicateField(let field):
                "Keep only one \(field) field in the skill frontmatter."
            }
        }
    }

    public static func parse(_ markdown: String) throws -> SkillFrontmatter {
        let header = try header(in: markdown)
        let root: Node?
        do {
            // Inspect the representation tree without constructing arbitrary optional metadata.
            // Yams errors contain source snippets, so only our safe errors cross this boundary.
            root = try Yams.compose(yaml: header, .default, .default, .utf8)
        } catch YamlError.duplicatedKeysInMapping(let duplicates, _) {
            if let field = ["name", "description"].first(where: duplicates.contains) {
                throw ParseError.duplicateField(field)
            }
            throw ParseError.malformedYAML
        } catch {
            throw ParseError.malformedYAML
        }

        guard let root, case .mapping = root else { throw ParseError.invalidRoot }
        return try SkillFrontmatter(
            name: requiredString("name", in: root),
            description: requiredString("description", in: root)
        )
    }

    private static func requiredString(_ field: String, in root: Node) throws -> String {
        guard let node = root[field] else { throw ParseError.missingField(field) }
        guard case .scalar(let scalar) = node, node.tag == Tag(.str) else {
            throw ParseError.invalidFieldType(field)
        }
        guard !scalar.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyField(field)
        }
        // Preserve YAML folding, literal line breaks, quoting, and chomping exactly as decoded.
        return scalar.string
    }

    private static func header(in markdown: String) throws -> String {
        // Bound both scanning and the parser input independently of the Markdown body's size.
        let bytes = Array(markdown.utf8.prefix(maximumHeaderBytes + 1))
        var lineStart = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var headerStart: Int?

        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            while contentEnd > lineStart, [0x20, 0x09].contains(bytes[contentEnd - 1]) { contentEnd -= 1 }
            let isDelimiter = bytes[lineStart..<contentEnd].elementsEqual([0x2D, 0x2D, 0x2D])

            if let headerStart {
                if isDelimiter {
                    guard lineEnd <= maximumHeaderBytes else { throw ParseError.headerTooLarge }
                    return String(decoding: bytes[headerStart..<lineStart], as: UTF8.self)
                }
            } else {
                guard isDelimiter else { throw ParseError.missingHeader }
                headerStart = min(lineEnd + 1, bytes.count)
            }
            lineStart = lineEnd + 1
        }

        guard headerStart != nil else { throw ParseError.missingHeader }
        if bytes.count > maximumHeaderBytes { throw ParseError.headerTooLarge }
        throw ParseError.unterminatedHeader
    }
}
