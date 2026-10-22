import Foundation

enum BoundedInputReaderError: LocalizedError, Sendable {
    case invalidMaximum
    case inputTooLarge(Int)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidMaximum: "The maximum input size must be greater than zero."
        case .inputTooLarge(let maximum): "Standard input exceeded the \(maximum)-byte limit."
        case .invalidUTF8: "Standard input is not valid UTF-8."
        }
    }
}

/// Reads until EOF instead of assuming a pipe returns its complete payload in
/// one call. The extra byte distinguishes an exact-boundary input from one
/// that merely begins with an acceptable prefix.
public enum BoundedInputReader {
    public static func readUTF8(from handle: FileHandle, maximumBytes: Int) throws -> String {
        guard maximumBytes > 0 else { throw BoundedInputReaderError.invalidMaximum }
        var data = Data()
        let chunkBytes = 8 * 1_024

        while true {
            let remainingThroughOverflowByte = maximumBytes + 1 - data.count
            guard remainingThroughOverflowByte > 0 else {
                throw BoundedInputReaderError.inputTooLarge(maximumBytes)
            }
            guard
                let chunk = try handle.read(
                    upToCount: min(chunkBytes, remainingThroughOverflowByte)
                ),
                !chunk.isEmpty
            else { break }
            data.append(chunk)
            if data.count > maximumBytes {
                throw BoundedInputReaderError.inputTooLarge(maximumBytes)
            }
        }

        guard let value = String(data: data, encoding: .utf8) else {
            throw BoundedInputReaderError.invalidUTF8
        }
        return value
    }
}
