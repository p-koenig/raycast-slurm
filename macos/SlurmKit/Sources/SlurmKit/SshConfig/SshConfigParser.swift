import Foundation

/// A minimal `ssh_config` parser — the replacement for the npm `ssh-config` dependency.
///
/// It covers exactly what `src/lib/ssh-config.ts` asks of the JS parser and nothing more:
/// `Host` blocks with (optionally quoted) space-separated patterns, `Keyword Value` and
/// `Keyword=Value` directive lines, comments and blank lines, and `compute(alias)` with OpenSSH's
/// first-value-wins semantics.
///
/// Deliberate limits, all documented because they are the places a future cluster could surprise
/// us:
/// * `Match` blocks are parsed but never apply. The npm parser evaluates a subset of the match
///   criteria; SlurmBar only ever needs `HostName`/`User`/`Port`/`IdentityFile` for an alias the
///   user picked, and silently guessing at `Match exec` would be worse than ignoring it.
/// * only whole-line comments (`#` as the first non-blank character) are stripped — a `#` inside a
///   value stays part of the value, which is what OpenSSH does.
/// * host patterns support `*` and `?` (OpenSSH's `match_pattern`); `[` is a literal.
public struct ParsedSshConfig: Equatable, Sendable {

    /// One `Host`/`Match` section, or the implicit leading section holding directives that appear
    /// before the first `Host` line (OpenSSH applies those to every alias).
    public struct Block: Equatable, Sendable {

        /// Patterns as written after `Host`, negations included (`!bastion`). Empty for the
        /// implicit global block.
        public var patterns: [String]

        /// `true` for a `Match` block, which this parser never applies. See the type doc.
        public var isMatch: Bool

        public var directives: [Directive]

        public init(patterns: [String], isMatch: Bool = false, directives: [Directive] = []) {
            self.patterns = patterns
            self.isMatch = isMatch
            self.directives = directives
        }

        /// OpenSSH's rule: a block applies when at least one positive pattern matches the alias and
        /// no negated pattern does. The implicit global block always applies.
        public func applies(to alias: String) -> Bool {
            if isMatch { return false }
            if patterns.isEmpty { return true }
            var matchedPositive = false
            for pattern in patterns {
                if pattern.hasPrefix("!") {
                    if SshPattern.matches(String(pattern.dropFirst()), alias) { return false }
                } else if SshPattern.matches(pattern, alias) {
                    matchedPositive = true
                }
            }
            return matchedPositive
        }
    }

    public struct Directive: Equatable, Sendable {
        /// The keyword exactly as written, for round-tripping and diagnostics.
        public var keyword: String
        public var value: String

        public init(keyword: String, value: String) {
            self.keyword = keyword
            self.value = value
        }
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// What the npm parser throws on a line it cannot make sense of. This is the only route to
    /// `ConfigState.unreadable` (the TS also reached it from a `fast-glob` throw, which `glob(3)`
    /// does not reproduce).
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var text: String
        public var description: String { "Unexpected line \(line): \(text)" }
    }

    // MARK: - Parsing

    public static func parse(_ text: String) throws -> ParsedSshConfig {
        var blocks: [Block] = []
        var current = Block(patterns: [])
        var lineNumber = 0

        for rawLine in splitLines(text) {
            lineNumber += 1
            let line = JS.trim(rawLine)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let (keyword, value) = try splitDirective(line, lineNumber: lineNumber)
            switch keyword.lowercased() {
            case "host":
                blocks.append(current)
                current = Block(patterns: tokenize(value))
            case "match":
                blocks.append(current)
                current = Block(patterns: [], isMatch: true)
            default:
                current.directives.append(Directive(keyword: keyword, value: value))
            }
        }
        blocks.append(current)
        // Drop the implicit global block when it carries nothing, so `blocks` reads like the file.
        return ParsedSshConfig(blocks: blocks.filter { !$0.patterns.isEmpty || $0.isMatch || !$0.directives.isEmpty })
    }

    /// `Key Value`, `Key=Value` and `Key = Value` all reach here. A keyword with no value is the
    /// malformed case that makes the whole config `unreadable`.
    private static func splitDirective(_ line: String, lineNumber: Int) throws -> (String, String) {
        let scalars = Array(line)
        var index = 0
        while index < scalars.count, !JS.isSpace(scalars[index]), scalars[index] != "=" { index += 1 }
        let keyword = String(scalars[0..<index])
        // Skip the separator: whitespace, an optional `=`, then whitespace again.
        while index < scalars.count, JS.isSpace(scalars[index]) { index += 1 }
        if index < scalars.count, scalars[index] == "=" {
            index += 1
            while index < scalars.count, JS.isSpace(scalars[index]) { index += 1 }
        }
        let value = JS.trim(String(scalars[index...]))
        guard !keyword.isEmpty, !value.isEmpty else {
            throw ParseError(line: lineNumber, text: line)
        }
        return (keyword, value)
    }

    /// Split a directive value into space-separated tokens, honouring double quotes so
    /// `Host "my box" other` yields two aliases.
    static func tokenize(_ value: String) -> [String] {
        var out: [String] = []
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            while i < chars.count, JS.isSpace(chars[i]) { i += 1 }
            if i >= chars.count { break }
            if chars[i] == "\"" {
                let start = i + 1
                var end = start
                while end < chars.count, chars[end] != "\"" { end += 1 }
                if end < chars.count {
                    out.append(String(chars[start..<end]))
                    i = end + 1
                    continue
                }
                // Unterminated quote: fall through and take it as a bare token, quote included,
                // which is what the TS `/"[^"]+"|\S+/` alternation does.
            }
            let start = i
            while i < chars.count, !JS.isSpace(chars[i]) { i += 1 }
            out.append(String(chars[start..<i]))
        }
        return out
    }

    /// `text.split(/\r?\n/)`.
    static func splitLines(_ text: String) -> [String] {
        JS.split(text.replacingOccurrences(of: "\r\n", with: "\n"), "\n")
    }

    // MARK: - compute

    /// OpenSSH's option resolution for one alias: walk the blocks in file order, and for each
    /// keyword keep the **first** value obtained. Multi-value keywords (`IdentityFile` and
    /// friends) accumulate instead, in the order they were seen.
    public func compute(_ alias: String) -> ComputedHostConfig {
        var values: [String: [String]] = [:]
        for block in blocks where block.applies(to: alias) {
            for directive in block.directives {
                let key = directive.keyword.lowercased()
                if ComputedHostConfig.multiValueKeywords.contains(key) {
                    values[key, default: []].append(directive.value)
                } else if values[key] == nil {
                    values[key] = [directive.value]
                }
            }
        }
        return ComputedHostConfig(values: values)
    }

    /// Every alias written on a `Host` line, in file order, negations and wildcards included.
    /// `listHosts` is what filters those out.
    public var declaredAliases: [String] {
        blocks.flatMap(\.patterns)
    }
}

/// The result of `ParsedSshConfig.compute` — the resolved options for one alias.
///
/// Keys are stored lowercased and read case-insensitively, because `ssh_config` keywords are
/// case-insensitive while the TS reads them by their canonical spelling (`resolved.HostName`).
public struct ComputedHostConfig: Equatable, Sendable {

    /// Keywords whose values accumulate rather than being overwritten (OpenSSH semantics).
    static let multiValueKeywords: Set<String> = [
        "identityfile", "certificatefile", "localforward", "remoteforward", "dynamicforward",
        "sendenv", "setenv",
    ]

    /// Lowercased keyword → values, first-obtained first.
    public let values: [String: [String]]

    public init(values: [String: [String]]) {
        self.values = values
    }

    public func first(_ keyword: String) -> String? {
        values[keyword.lowercased()]?.first
    }

    public func all(_ keyword: String) -> [String] {
        values[keyword.lowercased()] ?? []
    }

    public var isEmpty: Bool { values.isEmpty }

    public var hostName: String? { first("HostName") }
    public var user: String? { first("User") }
    public var port: String? { first("Port") }

    /// `nil` rather than `[]` when nothing applies, mirroring the TS `undefined`.
    public var identityFile: [String]? {
        let files = all("IdentityFile")
        return files.isEmpty ? nil : files
    }
}

/// OpenSSH `match_pattern`: `*` matches any run (including empty), `?` matches exactly one
/// character, everything else is literal. Case-sensitive, like the config file.
enum SshPattern {

    static func matches(_ pattern: String, _ candidate: String) -> Bool {
        let p = Array(pattern)
        let s = Array(candidate)
        var pi = 0, si = 0
        var starPi = -1, starSi = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starSi = si
                pi += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starSi += 1
                si = starSi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
