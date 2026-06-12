import Testing
import Foundation
@testable import StenoCore

struct LineFramerTests {
    private func strings(_ data: [Data]) -> [String] {
        data.map { String(data: $0, encoding: .utf8)! }
    }

    @Test func splitsMultipleLinesInOneRead() {
        var f = LineFramer()
        let out = f.append(Data("a\nb\nc\n".utf8))
        #expect(strings(out) == ["a", "b", "c"])
    }

    @Test func buffersPartialLineAcrossReads() {
        var f = LineFramer()
        #expect(f.append(Data("hel".utf8)).isEmpty)
        let out = f.append(Data("lo\n".utf8))
        #expect(strings(out) == ["hello"])
    }

    @Test func dropsEmptyLines() {
        var f = LineFramer()
        let out = f.append(Data("\n\nx\n\n".utf8))
        #expect(strings(out) == ["x"])
    }

    @Test func holdsLineWithoutTrailingNewline() {
        var f = LineFramer()
        let out = f.append(Data("nofinalnewline".utf8))
        #expect(out.isEmpty)
        let out2 = f.append(Data("\n".utf8))
        #expect(strings(out2) == ["nofinalnewline"])
    }
}
