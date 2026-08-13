import Foundation

/// The handful of JavaScript semantics the ported parsers actually depend on.
///
/// The TypeScript in `src/lib/*.ts` is the reference implementation, and several of its
/// behaviours fall out of JS coercion rules rather than from anything the author wrote
/// deliberately (`Number("") === 0`, `Number("N/A")` being `NaN` rather than an error,
/// `String.prototype.split` keeping empty fields, `Math.round` breaking ties upwards). Those
/// are reproduced here once, explicitly, so the parsers themselves stay readable and every
/// call site can point at the constraint it is honouring.
enum JS {

    // MARK: - Whitespace

    /// The set matched by JS `\s` and trimmed by `String.prototype.trim`: `WhiteSpace` ∪
    /// `LineTerminator`. It differs from Swift's `Character.isWhitespace` at U+FEFF, which JS
    /// treats as whitespace and Unicode does not.
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F,
            0x3000, 0xFEFF:
            return true
        case 0x2000...0x200A:
            return true
        default:
            return false
        }
    }

    static func isSpace(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return isSpace(u)
    }

    /// `String.prototype.trim`.
    static func trim(_ s: String) -> String {
        var scalars = Substring(s)
        while let f = scalars.first, isSpace(f) { scalars = scalars.dropFirst() }
        while let l = scalars.last, isSpace(l) { scalars = scalars.dropLast() }
        return String(scalars)
    }

    // MARK: - Splitting

    /// `String.prototype.split(separator)` — keeps empty fields, including leading and trailing
    /// ones. Swift's `split` drops them by default, which would silently change every
    /// pipe-delimited row parser.
    static func split(_ s: String, _ separator: Character) -> [String] {
        s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }

    /// `String.prototype.split(/\s+/)` — runs of whitespace. A leading run yields an empty first
    /// field, exactly as in JS.
    static func splitWhitespaceRuns(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var index = s.startIndex
        var sawSpace = false
        while index < s.endIndex {
            let c = s[index]
            if isSpace(c) {
                if !sawSpace {
                    out.append(current)
                    current = ""
                    sawSpace = true
                }
            } else {
                current.append(c)
                sawSpace = false
            }
            index = s.index(after: index)
        }
        out.append(current)
        return out
    }

    // MARK: - Number coercion

    /// `Number(string)`, returning `NaN` where JS would.
    ///
    /// Notably: `Number("")` and `Number("   ")` are `0` (every call site that cares guards on
    /// the empty string *first*), `Number("N/A")` is `NaN`, and hex/octal/binary literals and
    /// `Infinity` are recognised while `"inf"`/`"nan"` — which Swift's `Double(String)` accepts —
    /// are not.
    static func number(_ raw: String) -> Double {
        let s = trim(raw)
        if s.isEmpty { return 0 }
        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }

        let scalars = Array(s.unicodeScalars)
        if scalars.count > 2, scalars[0] == "0" {
            switch scalars[1] {
            case "x", "X": return radixValue(scalars[2...], radix: 16)
            case "o", "O": return radixValue(scalars[2...], radix: 8)
            case "b", "B": return radixValue(scalars[2...], radix: 2)
            default: break
            }
        }
        guard isDecimalLiteral(scalars) else { return .nan }
        return Double(s) ?? .nan
    }

    private static func radixValue(_ digits: ArraySlice<Unicode.Scalar>, radix: Int) -> Double {
        if digits.isEmpty { return .nan }
        var value = 0.0
        for d in digits {
            guard let v = hexValue(d), v < radix else { return .nan }
            value = value * Double(radix) + Double(v)
        }
        return value
    }

    private static func hexValue(_ u: Unicode.Scalar) -> Int? {
        switch u {
        case "0"..."9": return Int(u.value - 0x30)
        case "a"..."f": return Int(u.value - 0x61) + 10
        case "A"..."F": return Int(u.value - 0x41) + 10
        default: return nil
        }
    }

    /// `StrDecimalLiteral`: `[+-]? ( digits ("." digits?)? | "." digits ) ( [eE] [+-]? digits )?`
    private static func isDecimalLiteral(_ scalars: [Unicode.Scalar]) -> Bool {
        var i = 0
        let n = scalars.count
        func isDigit(_ j: Int) -> Bool { j < n && scalars[j] >= "0" && scalars[j] <= "9" }
        func consumeDigits() -> Int {
            let start = i
            while isDigit(i) { i += 1 }
            return i - start
        }

        if i < n, scalars[i] == "+" || scalars[i] == "-" { i += 1 }
        let intDigits = consumeDigits()
        var fracDigits = 0
        if i < n, scalars[i] == "." {
            i += 1
            fracDigits = consumeDigits()
        }
        if intDigits == 0 && fracDigits == 0 { return false }
        if i < n, scalars[i] == "e" || scalars[i] == "E" {
            i += 1
            if i < n, scalars[i] == "+" || scalars[i] == "-" { i += 1 }
            if consumeDigits() == 0 { return false }
        }
        return i == n
    }

    /// `Math.round` — half-way cases go towards `+∞`, unlike Swift's `rounded()`, which goes
    /// away from zero.
    static func round(_ x: Double) -> Double {
        (x + 0.5).rounded(.down)
    }

    /// A finite `Double` narrowed to `Int` without trapping. Slurm's counts are integral, so
    /// this only ever truncates on input the wire format cannot produce.
    static func int(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        if x >= 9.007199254740991e15 { return Int(9_007_199_254_740_991) }
        if x <= -9.007199254740991e15 { return Int(-9_007_199_254_740_991) }
        return Int(x.rounded(.towardZero))
    }

    // MARK: - Number formatting

    /// `Number.prototype.toFixed(digits)`.
    ///
    /// Differs from `String(format: "%.1f", …)`: JS picks the representable decimal closest to
    /// the value and breaks exact ties towards the *larger* number, while `printf` rounds ties
    /// to even (`(1.25).toFixed(1)` is `"1.3"`, `%.1f` prints `1.2`). Both `formatBytesMB` and
    /// `memFromTres` divide by powers of two, so exact ties are reachable.
    static func toFixed(_ x: Double, _ digits: Int) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }

        let negative = x < 0
        let magnitude = abs(x)
        // A double is a dyadic rational, so 18 guard digits are far beyond the point where a
        // non-tie could masquerade as a tie; `%f` on Darwin is correctly rounded.
        let expanded = String(format: "%.\(digits + 18)f", magnitude)
        let pieces = expanded.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integerDigits = Array(pieces[0])
        var fractionDigits = pieces.count > 1 ? Array(pieces[1]) : []
        while fractionDigits.count < digits { fractionDigits.append("0") }

        let roundUp = fractionDigits.count > digits && fractionDigits[digits] >= "5"
        fractionDigits = Array(fractionDigits.prefix(digits))
        if roundUp {
            var carry = true
            var i = fractionDigits.count - 1
            while carry && i >= 0 {
                if fractionDigits[i] == "9" {
                    fractionDigits[i] = "0"
                } else {
                    fractionDigits[i] = Character(UnicodeScalar(fractionDigits[i].asciiValue! + 1))
                    carry = false
                }
                i -= 1
            }
            var j = integerDigits.count - 1
            while carry && j >= 0 {
                if integerDigits[j] == "9" {
                    integerDigits[j] = "0"
                } else {
                    integerDigits[j] = Character(UnicodeScalar(integerDigits[j].asciiValue! + 1))
                    carry = false
                }
                j -= 1
            }
            if carry { integerDigits.insert("1", at: 0) }
        }

        let body =
            digits > 0
            ? "\(String(integerDigits)).\(String(fractionDigits))"
            : String(integerDigits)
        // toFixed splits the sign off before rounding, so "-0.0" is a legal result.
        return negative ? "-\(body)" : body
    }
}

extension Array {
    /// A stable sort. `Array.prototype.sort` has been required to be stable since ES2019 and the
    /// partition-activity ordering depends on it (every `UNLIMITED` / unparsable time-left row
    /// compares equal and must keep its `squeue` order); Swift's `sorted(by:)` guarantees
    /// nothing.
    func stableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
        try enumerated()
            .sorted { lhs, rhs in
                if try areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if try areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
