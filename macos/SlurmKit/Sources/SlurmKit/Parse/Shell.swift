import Foundation

/// Safe-charset passthrough, everything else single-quoted. Port of `src/lib/shell.ts`.
///
/// Used for every user-derived value (username, job id, node name, partition, file path) that
/// ends up inside a remote command string — never interpolate a raw string instead.
///
/// The empty string becomes `''` rather than vanishing, and an embedded `'` is closed, escaped
/// and reopened (`'\''`), which is what makes the captured fixture commands byte-identical.
public func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    if safeCharset.test(s) { return s }
    return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
}

// `/^[A-Za-z0-9_./%:=,@+-]+$/` — `$` is JS end-of-input, hence `\z`.
private let safeCharset = Pattern(#"^[A-Za-z0-9_./%:=,@+-]+\z"#)
