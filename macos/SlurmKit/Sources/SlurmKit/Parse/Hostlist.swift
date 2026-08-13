import Foundation

/// Slurm hostlist expansion: `gpu[01-02,05],cpu7` → `["gpu01", "gpu02", "gpu05", "cpu7"]`.
/// Port of `src/lib/hostlist.ts`.
public enum Hostlist {

    /// Expand a hostlist into its individual node names.
    ///
    /// Three behaviours are load-bearing and pinned by fixtures:
    /// * the zero padding of the expanded numbers copies the width of the range's *start*
    ///   token (`n[001-003]` → `n001,n002,n003`, `gpu[3]` → `gpu3`);
    /// * the top-level comma split ignores commas inside `[...]`;
    /// * a malformed range entry is skipped silently rather than falling back to the raw text
    ///   (`gpu[a-b]` → `[]`), while a piece with no bracket at all passes through verbatim
    ///   (`(Resources)` → `["(Resources)"]`).
    ///
    /// Only the first bracket group expands; anything after it is treated as a literal suffix
    /// (`rack[1-2]node[3-4]` → `rack1node[3-4]`, `rack2node[3-4]`).
    public static func expand(_ hostlist: String) -> [String] {
        if hostlist.isEmpty { return [] }
        var out: [String] = []
        for piece in splitTopLevel(hostlist, ",") {
            let trimmed = JS.trim(piece)
            if trimmed.isEmpty { continue }
            guard let m = bracketGroup.exec(trimmed) else {
                out.append(trimmed)
                continue
            }
            let prefix = m[1] ?? ""
            let ranges = m[2] ?? ""
            let suffix = m[3] ?? ""
            for r in JS.split(ranges, ",") {
                guard let rm = rangePattern.exec(JS.trim(r)), let startToken = rm[1] else { continue }
                let start = JS.int(JS.number(startToken))
                let end = rm[2].map { JS.int(JS.number($0)) } ?? start
                let width = startToken.count
                if start > end { continue }
                for i in start...end {
                    out.append("\(prefix)\(padStart(String(i), width))\(suffix)")
                }
            }
        }
        return out
    }

    /// Split on `separator`, ignoring separators inside a `[...]` range group.
    private static func splitTopLevel(_ s: String, _ separator: Character) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for c in s {
            if c == "[" {
                depth += 1
                current.append(c)
            } else if c == "]" {
                depth -= 1
                current.append(c)
            } else if c == separator && depth == 0 {
                out.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current)
        return out
    }

    /// `String.prototype.padStart(width, "0")` — never truncates.
    private static func padStart(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

// `/^([^[]*)\[([^\]]+)\](.*)$/` and `/^(\d+)(?:-(\d+))?$/`, with JS end-of-input anchors.
private let bracketGroup = Pattern(#"^([^\[]*)\[([^\]]+)\](.*)\z"#)
private let rangePattern = Pattern(#"^(\d+)(?:-(\d+))?\z"#)
