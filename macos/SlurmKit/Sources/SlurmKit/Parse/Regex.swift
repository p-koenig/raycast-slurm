import Foundation

/// A precompiled `NSRegularExpression` with JS-`RegExp.prototype.exec` ergonomics.
///
/// `NSRegularExpression` is used rather than Swift's `Regex` because it matches over UTF-16
/// offsets, which is exactly what the JS originals do, and because a `static let` compiles the
/// pattern once. One porting note that matters: an unanchored JS `$` means *end of input*,
/// while ICU also lets `$` match before a final line terminator — so every `$` from the TS is
/// written `\z` here.
struct Pattern: Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // The patterns are compile-time constants ported from src/lib; a failure here is a typo,
        // not a runtime condition.
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    /// The first match's capture groups, `nil` when there is no match. Index 0 is the whole
    /// match; a group that did not participate is `nil`, mirroring `exec`'s `undefined`.
    func exec(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// Whether the pattern matches anywhere in `s` (`RegExp.prototype.test`).
    func test(_ s: String) -> Bool {
        let ns = s as NSString
        return regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// `String.prototype.replace(regexp, replacement)` for a non-global pattern: replaces the
    /// first match only.
    func replaceFirst(in s: String, with replacement: String) -> String {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return s
        }
        return ns.replacingCharacters(in: m.range, with: replacement)
    }
}
