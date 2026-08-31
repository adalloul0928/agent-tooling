import Foundation

public enum AgentToolingCoding {
    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static func agentTooling() -> JSONEncoder {
        AgentToolingCoding.encoder()
    }
}

extension JSONDecoder {
    static func agentTooling() -> JSONDecoder {
        AgentToolingCoding.decoder()
    }
}
