import Foundation

/// Accumulates bytes from a stream socket and emits complete newline-delimited
/// frames. A single socket read may contain a partial line, several lines, or
/// a line split across reads — this buffers across calls and only returns
/// whole lines (empty lines are dropped, matching the daemon's reader).
public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Append freshly-read bytes and return any complete lines now available.
    /// The trailing newline is stripped from each returned line.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        let newline = UInt8(ascii: "\n")

        while let nl = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            // Advance past the newline.
            let next = buffer.index(after: nl)
            buffer = Data(buffer[next...])
        }
        return lines
    }
}
