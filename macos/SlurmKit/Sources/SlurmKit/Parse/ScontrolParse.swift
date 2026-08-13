import Foundation

/// Parsers for `scontrol` output, ported from `src/lib/slurm.ts`.
public enum ScontrolParse {

    // MARK: - Entry points

    /// Parse the stdout of `scontrol show node --oneliner` into nodes.
    public static func nodes(stdout: String) -> [SlurmNode] {
        JS.split(stdout, "\n")
            .map(JS.trim)
            .filter { !$0.isEmpty }
            .map(nodeLine)
    }

    /// Parse the stdout of `scontrol show job <id>` into a `JobDetail`.
    ///
    /// The whole (multi-line) output is tokenized in one pass — `tokenizeKv` treats newlines as
    /// ordinary whitespace, which is what lets the indented continuation lines contribute their
    /// keys.
    public static func jobDetail(stdout: String) -> JobDetail {
        JobDetail(raw: stdout, fields: tokenizeKv(stdout))
    }

    // MARK: - Row parsing

    /// One line of `scontrol show node --oneliner`.
    public static func nodeLine(_ line: String) -> SlurmNode {
        let fields = tokenizeKv(line)
        return SlurmNode(
            name: fields["NodeName"] ?? "",
            state: fields["State"] ?? "",
            partitions: JS.split(fields["Partitions"] ?? "", ",").filter { !$0.isEmpty },
            cpuLoad: cpuLoad(fields["CPULoad"]),
            cpuTot: numOr(fields["CPUTot"], 0),
            cpuAlloc: numOr(fields["CPUAlloc"], 0),
            realMemoryMB: numOr(fields["RealMemory"], 0),
            freeMemoryMB: numOr(fields["FreeMem"], 0),
            allocMemoryMB: numOr(fields["AllocMem"], 0),
            gres: fields["Gres"] ?? "",
            gresUsed: fields["GresUsed"] ?? "",
            allocTres: fields["AllocTRES"] ?? fields["AllocTres"] ?? "",
            features: fields["AvailableFeatures"] ?? fields["Features"] ?? "",
            reason: fields["Reason"] ?? ""
        )
    }

    /// `squeue`'s `%i` renders a still-pending array as `6754_[380-543%1]` — base id + bracketed
    /// task range + optional `%N` throttle. `scontrol`'s job-id parser rejects that syntax
    /// outright ("Invalid job id specified"), so the bracketed tail is stripped and the base
    /// array job id queried, which `scontrol` resolves to the pending array record. A running
    /// task (`6754_380`) and a plain job (`6754`) contain no bracket and pass through unchanged.
    public static func jobId(_ jobId: String) -> String {
        arrayTail.replaceFirst(in: jobId, with: "")
    }

    // MARK: - Tokenizer

    /// Parse `Key=Value` tokens out of a whitespace-separated blob.
    ///
    /// A character scan, not a regex, exactly like the TS original — this runs once per node
    /// line for every node in the cluster. Three behaviours are contractual:
    /// * quoted values are supported so `Reason="kernel upgrade pending"` survives intact;
    /// * a bare token (no `=`) is skipped;
    /// * the **first** occurrence of a key wins; later duplicates are ignored.
    public static func tokenizeKv(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(line)
        let n = chars.count
        var i = 0
        while i < n {
            while i < n, JS.isSpace(chars[i]) { i += 1 }
            if i >= n { break }
            let keyStart = i
            while i < n, chars[i] != "=", !JS.isSpace(chars[i]) { i += 1 }
            // `line[i]` is `undefined` at the end of the string in JS, so running off the end
            // also lands in the bare-token branch and terminates the loop.
            guard i < n, chars[i] == "=" else {
                while i < n, !JS.isSpace(chars[i]) { i += 1 }
                continue
            }
            let key = String(chars[keyStart..<i])
            i += 1  // skip '='
            let value: String
            if i < n, chars[i] == "\"" {
                i += 1
                let start = i
                while i < n, chars[i] != "\"" { i += 1 }
                value = String(chars[start..<i])
                if i < n, chars[i] == "\"" { i += 1 }
            } else {
                let start = i
                while i < n, !JS.isSpace(chars[i]) { i += 1 }
                value = String(chars[start..<i])
            }
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    // MARK: - Numeric coercion

    /// `CPULoad`, or `nil` for a missing/empty value and Slurm's `N/A` sentinel.
    ///
    /// The TS guards with `fields.CPULoad && fields.CPULoad !== "N/A"` and then calls `Number`
    /// unconditionally, so a garbage value produces `NaN` — which `JSON.stringify` writes as
    /// `null`, and which the fixtures therefore record as `null`. `nil` is the faithful Swift
    /// equivalent.
    private static func cpuLoad(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty, raw != "N/A" else { return nil }
        let n = JS.number(raw)
        return n.isNaN ? nil : n
    }

    /// The TS `numOr`: a falsy guard *before* the coercion, which is why `""` falls back rather
    /// than becoming `Number("") === 0`; non-finite results fall back too.
    private static func numOr(_ v: String?, _ fallback: Int) -> Int {
        guard let v, !v.isEmpty else { return fallback }
        let n = JS.number(v)
        guard n.isFinite else { return fallback }
        return JS.int(n)
    }
}

// `/_\[.*$/` — `.` never crosses a newline and `$` is end of input.
private let arrayTail = Pattern(#"_\[.*\z"#)
