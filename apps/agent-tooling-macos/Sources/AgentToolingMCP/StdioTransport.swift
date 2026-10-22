import Foundation

/// The MCP specification recommends stdio precisely because it "limits access
/// to just the MCP client". A localhost HTTP port is reachable by every other
/// local process and by DNS rebinding from a page the person happens to have
/// open, so this server has no listening socket at all: it reads the pipe its
/// parent handed it and writes back on the same pair of descriptors.
protocol MessageTransport: AnyObject {
    /// Returns the next complete frame, or `nil` at end of input.
    func readMessage() throws -> Data?
    func write(_ data: Data)
}

enum StdioTransportError: LocalizedError {
    case frameTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let maximum): "An incoming message exceeded the \(maximum)-byte frame limit."
        }
    }
}

/// Line-delimited JSON over a pair of file handles, with a hard cap on any one
/// frame so a caller cannot exhaust memory by never sending a newline. An
/// oversized frame is reported once and then skipped to the next newline, so a
/// single bad message cannot desynchronize the rest of the session.
final class StdioTransport: MessageTransport {
    private let input: FileHandle
    private let output: FileHandle
    private let maximumFrameBytes: Int
    private let chunkBytes = 32 * 1_024
    private var buffer = Data()
    private var reachedEndOfInput = false
    private var isSkippingOversizedFrame = false

    init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        maximumFrameBytes: Int = JSONRPCDecoding.maximumMessageBytes
    ) {
        self.input = input
        self.output = output
        self.maximumFrameBytes = maximumFrameBytes
    }

    func readMessage() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let frame = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if isSkippingOversizedFrame {
                    isSkippingOversizedFrame = false
                    continue
                }
                // The buffer is already past this frame's newline, so refusing
                // it here costs no synchronization.
                guard frame.count <= maximumFrameBytes else {
                    throw StdioTransportError.frameTooLarge(maximumFrameBytes)
                }
                let trimmed = Self.trimmingInsignificantBytes(frame)
                if trimmed.isEmpty { continue }
                return trimmed
            }
            if isSkippingOversizedFrame { buffer = Data() }
            if reachedEndOfInput {
                guard !isSkippingOversizedFrame, !buffer.isEmpty else { return nil }
                let frame = Self.trimmingInsignificantBytes(buffer)
                buffer = Data()
                return frame.isEmpty ? nil : frame
            }
            if buffer.count > maximumFrameBytes {
                buffer = Data()
                isSkippingOversizedFrame = true
                throw StdioTransportError.frameTooLarge(maximumFrameBytes)
            }
            guard let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty else {
                reachedEndOfInput = true
                continue
            }
            buffer.append(chunk)
        }
    }

    /// A closed pipe is a normal way for a session to end, not an error worth
    /// crashing over. SIGPIPE is ignored at startup and the failed write is
    /// dropped; the read side will report end of input on the next turn.
    func write(_ data: Data) {
        try? output.write(contentsOf: data)
    }

    private static func trimmingInsignificantBytes(_ data: Data) -> Data {
        var slice = data[...]
        while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0D {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == 0x20 || last == 0x09 || last == 0x0D {
            slice = slice.dropLast()
        }
        return Data(slice)
    }
}
