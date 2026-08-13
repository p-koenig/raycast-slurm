import Foundation

@testable import SlurmKit

// Loading and shaping of the golden fixtures in `<repo>/fixtures`.
//
// The fixtures are the cross-language contract: `scripts/export-fixtures.ts` runs the *actual*
// TypeScript parsers over the demo corpus and records the raw wire input, the exact remote
// command the lib issued, and the TS-parsed result. Comparison here is always on decoded values,
// never on JSON bytes, so `Double` formatting noise cannot cause a false failure.

/// One fixture document, `fixtures/<kind>.json`.
struct FixtureFile<Expected: Decodable & Sendable>: Decodable, Sendable {
    let version: Int
    let kind: String
    let cases: [FixtureCase<Expected>]
}

/// One case. `input` is the raw stdout for the parser kinds; `cmd`/`host` are present for the
/// kinds captured through a real lib call. `note` is documentation the exporter attaches to
/// cases with a surprising expectation — decode it so it never causes a decode failure, ignore
/// it otherwise.
struct FixtureCase<Expected: Decodable & Sendable>: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let host: String?
    let cmd: String?
    let input: String?
    let expected: Expected
    let note: String?

    var description: String { name }
}

enum Fixtures {

    /// Every kind the exporter writes, with the number of cases currently recorded.
    ///
    /// Asserted exactly by `FixtureInventoryTests`. This is the anti-skip guard the phase gate
    /// asks for: a fixture file that fails to load, loses cases, or silently stops being
    /// exercised shows up as a failure rather than as a quietly shrinking test run. Update the
    /// counts deliberately when the exporter grows new cases.
    static let expectedCaseCounts: [(kind: String, count: Int)] = [
        ("jobs-user", 4),
        ("jobs-all", 2),
        ("node-jobs", 6),
        ("partition-activity", 7),
        ("nodes", 2),
        ("job-detail", 9),
        ("format-scalars", 578),
        ("metric-stream", 4),
        ("metrics-script", 1),
    ]

    static func load<Expected: Decodable & Sendable>(
        _ kind: String,
        as: Expected.Type = Expected.self
    ) -> FixtureFile<Expected> {
        let url = TestPaths.fixtureURL(kind: kind)
        guard let data = try? Data(contentsOf: url) else {
            fatalError("fixture not found: \(url.path(percentEncoded: false)) — run `npm run export-fixtures`")
        }
        do {
            let file = try JSONDecoder().decode(FixtureFile<Expected>.self, from: data)
            precondition(file.kind == kind, "fixture \(kind).json declares kind \(file.kind)")
            return file
        } catch {
            fatalError("fixture \(kind).json failed to decode as \(Expected.self): \(error)")
        }
    }

    static func cases<Expected: Decodable & Sendable>(
        _ kind: String,
        as: Expected.Type = Expected.self
    ) -> [FixtureCase<Expected>] {
        load(kind, as: Expected.self).cases
    }

    /// The raw JSON of a case's `input`, for the kinds whose input is not a plain string.
    static func rawCases(_ kind: String) -> [JSONValue] {
        let url = TestPaths.fixtureURL(kind: kind)
        guard let data = try? Data(contentsOf: url),
            let doc = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let root) = doc,
            case .array(let cases)? = root["cases"]
        else {
            fatalError("fixture \(kind).json could not be read as raw JSON")
        }
        return cases
    }
}

/// A minimal JSON tree, used where a fixture's `input`/`expected` is polymorphic
/// (`format-scalars` dispatches on a per-case function name).
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var numberValue: Double? { if case .number(let d) = self { return d } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    var isNull: Bool { self == .null }
}
