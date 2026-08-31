import Foundation

/// A deliberately narrow fallback used only when a client does not expose
/// machine-readable inventory. It recognizes TOML table headers without
/// interpreting values, arrays, or executable configuration.
enum TOMLTableScanner {
    static func tablePaths(in document: String) -> [[String]] {
        document.split(separator: "\n").compactMap { line in
            guard let header = tableHeader(String(line)) else { return nil }
            return keyPath(header)
        }
    }

    private static func tableHeader(_ line: String) -> String? {
        var quote: Character?
        var escaping = false
        var content = ""
        for character in line {
            if escaping {
                content.append(character)
                escaping = false
                continue
            }
            if character == "\\", quote == "\"" {
                content.append(character)
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil { quote = character } else if quote == character { quote = nil }
                content.append(character)
                continue
            }
            if character == "#", quote == nil { break }
            content.append(character)
        }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard quote == nil,
            trimmed.hasPrefix("["),
            !trimmed.hasPrefix("[["),
            trimmed.hasSuffix("]")
        else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func keyPath(_ rawValue: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in rawValue {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil { quote = character } else if quote == character { quote = nil } else { current.append(character) }
                continue
            }
            if character == ".", quote == nil {
                let component = current.trimmingCharacters(in: .whitespaces)
                guard !component.isEmpty else { return nil }
                result.append(component)
                current = ""
                continue
            }
            current.append(character)
        }
        guard quote == nil, !escaping else { return nil }
        let final = current.trimmingCharacters(in: .whitespaces)
        guard !final.isEmpty else { return nil }
        result.append(final)
        return result
    }
}
