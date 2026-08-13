import Foundation
import Testing

@testable import SlurmKit

/// Golden tests for the 16 scalar helpers in `fixtures/format-scalars.json`.
///
/// The fixture's cases are `{ "name", "input": { "fn": <name>, "input": <value> }, "expected" }` —
/// the function discriminator is nested *inside* `input` — and the value/result types vary per
/// function, so each case is dispatched to a typed comparison rather than compared as raw JSON.
@Suite("Golden: format scalars")
struct FormatScalarGoldenTests {

    struct ScalarCase: Sendable, CustomStringConvertible {
        let name: String
        let fn: String
        let input: JSONValue
        let expected: JSONValue

        var description: String { name }
    }

    static let cases: [ScalarCase] = Fixtures.rawCases("format-scalars").map { raw in
        guard let o = raw.objectValue,
            let name = o["name"]?.stringValue,
            let wrapper = o["input"]?.objectValue,
            let fn = wrapper["fn"]?.stringValue,
            let input = wrapper["input"],
            let expected = o["expected"]
        else {
            fatalError("format-scalars case has an unexpected shape: \(raw)")
        }
        return ScalarCase(name: name, fn: fn, input: input, expected: expected)
    }

    /// Every function name the fixture exercises. A new name failing this test means the port is
    /// missing a function, not that the dispatcher needs a default branch.
    static let knownFunctions: Set<String> = [
        "parseSlurmDurationSeconds", "formatSlurmDuration", "formatDurationSeconds", "gpuCountFromGres",
        "gpuCountFromTres", "memFromTres", "gpuLabelFromTres", "gpuInfoFromTres", "prettifyGpuModel",
        "shortNodeState", "shortReason", "formatBytesMB", "formatPercent", "expandHostlist",
        "scontrolJobId", "shellQuote",
    ]

    @Test("the fixture exercises exactly the ported function set")
    func functionCoverage() {
        #expect(Set(Self.cases.map(\.fn)) == Self.knownFunctions)
    }

    @Test("scalar helpers match the TypeScript", arguments: cases)
    func scalar(c: ScalarCase) throws {
        let label: Comment = "format-scalars/\(c.name)"
        switch c.fn {
        case "parseSlurmDurationSeconds":
            let out = SlurmFormat.parseSlurmDurationSeconds(try string(c))
            #expect(out == c.expected.numberValue, label)
            #expect((out == nil) == c.expected.isNull, label)

        case "formatSlurmDuration":
            #expect(SlurmFormat.formatSlurmDuration(try string(c)) == c.expected.stringValue, label)

        case "formatDurationSeconds":
            #expect(SlurmFormat.formatDurationSeconds(try number(c)) == c.expected.stringValue, label)

        case "formatBytesMB":
            #expect(SlurmFormat.formatBytesMB(try number(c)) == c.expected.stringValue, label)

        case "formatPercent":
            let pair = try #require(c.input.arrayValue, label)
            let nums = pair.compactMap(\.numberValue)
            try #require(nums.count == 2, "\(c.name): formatPercent takes a [num, den] pair")
            #expect(SlurmFormat.formatPercent(nums[0], nums[1]) == c.expected.stringValue, label)

        case "gpuCountFromGres":
            #expect(Double(SlurmFormat.gpuCountFromGres(try string(c))) == c.expected.numberValue, label)

        case "gpuCountFromTres":
            #expect(Double(SlurmFormat.gpuCountFromTres(try string(c))) == c.expected.numberValue, label)

        case "memFromTres":
            #expect(SlurmFormat.memFromTres(try string(c)) == c.expected.stringValue, label)
            #expect((SlurmFormat.memFromTres(try string(c)) == nil) == c.expected.isNull, label)

        case "gpuLabelFromTres":
            #expect(SlurmFormat.gpuLabelFromTres(try string(c)) == c.expected.stringValue, label)
            #expect((SlurmFormat.gpuLabelFromTres(try string(c)) == nil) == c.expected.isNull, label)

        case "gpuInfoFromTres":
            let out = SlurmFormat.gpuInfoFromTres(try string(c))
            if c.expected.isNull {
                #expect(out == nil, label)
            } else {
                let o = try #require(c.expected.objectValue, label)
                let want = GpuInfo(count: Int(try #require(o["count"]?.numberValue, label)), type: o["type"]?.stringValue)
                #expect(out == want, label)
            }

        case "prettifyGpuModel":
            #expect(SlurmFormat.prettifyGpuModel(try string(c)) == c.expected.stringValue, label)

        case "shortNodeState":
            #expect(SlurmFormat.shortNodeState(try string(c)) == c.expected.stringValue, label)

        case "shortReason":
            // The only fn whose fixture input is nullable: the exporter feeds it `null` to cover
            // the `undefined` reason a node without one produces.
            #expect(SlurmFormat.shortReason(c.input.stringValue) == c.expected.stringValue, label)

        case "expandHostlist":
            let want = try #require(c.expected.arrayValue, label).compactMap(\.stringValue)
            #expect(Hostlist.expand(try string(c)) == want, label)

        case "scontrolJobId":
            #expect(ScontrolParse.jobId(try string(c)) == c.expected.stringValue, label)

        case "shellQuote":
            #expect(shellQuote(try string(c)) == c.expected.stringValue, label)

        default:
            Issue.record("format-scalars: no port wired up for \(c.fn) (case \(c.name))")
        }
    }

    private func string(_ c: ScalarCase) throws -> String {
        try #require(c.input.stringValue, "\(c.name): input is not a string")
    }

    private func number(_ c: ScalarCase) throws -> Double {
        try #require(c.input.numberValue, "\(c.name): input is not a number")
    }
}
