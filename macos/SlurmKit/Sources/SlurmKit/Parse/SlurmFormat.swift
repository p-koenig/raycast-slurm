import Foundation

/// Scalar formatting and extraction helpers, ported from `src/lib/format.ts`.
///
/// The TS module imports Raycast's `Color`; that is the single UI leak in the reference
/// implementation and it is deliberately *not* ported. `stateColor` / `nodeStateColor` become
/// `stateCategory` / `nodeStateCategory` here, and the App layer owns the colour mapping.
public enum SlurmFormat {

    // MARK: - Durations

    /// `"1-04:23:11"` / `"23:45:00"` / `"23:45"` → seconds, or `nil` when the shape is not a
    /// Slurm duration.
    ///
    /// The accepted shapes follow the TS exactly: with a `D-` prefix the clock must have three
    /// or two fields (`D-HH:MM:SS`, `D-HH:MM`), without it exactly three (`HH:MM:SS`) or two
    /// (`MM:SS`). Anything else — one field (`"5"`), four fields, two dashes (`"1-2-3"`), a
    /// non-numeric day (`"x-01:00:00"`) — is `nil`. Note that `"UNLIMITED"` is *not* special
    /// cased here; callers handle it (see `formatSlurmDuration` and `SqueueParse`'s time-left
    /// sort).
    public static func parseSlurmDurationSeconds(_ v: String) -> Double? {
        let dashSplit = JS.split(v, "-")
        var days = 0.0
        var rest = v
        if dashSplit.count == 2 {
            let d = JS.number(dashSplit[0])
            guard d.isFinite else { return nil }
            days = d
            rest = dashSplit[1]
        }
        let parts = JS.split(rest, ":").map(JS.number)
        if parts.contains(where: { !$0.isFinite }) { return nil }

        var h = 0.0
        var m = 0.0
        var s = 0.0
        if dashSplit.count == 2 {
            if parts.count == 3 {
                (h, m, s) = (parts[0], parts[1], parts[2])
            } else if parts.count == 2 {
                (h, m) = (parts[0], parts[1])
            } else {
                return nil
            }
        } else if parts.count == 3 {
            (h, m, s) = (parts[0], parts[1], parts[2])
        } else if parts.count == 2 {
            (m, s) = (parts[0], parts[1])
        } else {
            return nil
        }
        return days * 86_400 + h * 3600 + m * 60 + s
    }

    /// A Slurm duration string rendered for humans; unparsable input is passed through verbatim.
    public static func formatSlurmDuration(_ s: String) -> String {
        let v = JS.trim(s)
        if v.isEmpty { return "—" }
        if v.uppercased() == "UNLIMITED" { return "unlimited" }
        guard let total = parseSlurmDurationSeconds(v) else { return v }
        return formatDurationSeconds(total)
    }

    /// Human-readable duration from a raw second count, e.g. `8045` → `"2h 14m"`.
    /// Seconds only appear for sub-hour durations, matching `formatSlurmDuration`.
    public static func formatDurationSeconds(_ total: Double) -> String {
        if !total.isFinite || total <= 0 { return "0s" }
        let days = (total / 86_400).rounded(.down)
        let hours = (total.truncatingRemainder(dividingBy: 86_400) / 3600).rounded(.down)
        let minutes = (total.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down)
        let seconds = total.truncatingRemainder(dividingBy: 60).rounded(.down)
        var parts: [String] = []
        if days != 0 { parts.append("\(JS.int(days))d") }
        if hours != 0 { parts.append("\(JS.int(hours))h") }
        if minutes != 0 { parts.append("\(JS.int(minutes))m") }
        if seconds != 0 && total < 3600 { parts.append("\(JS.int(seconds))s") }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }

    // MARK: - Sizes and percentages

    public static func formatBytesMB(_ mb: Double) -> String {
        if !mb.isFinite || mb <= 0 { return "0 MB" }
        if mb >= 1024 * 1024 { return "\(JS.toFixed(mb / (1024 * 1024), 1)) TB" }
        if mb >= 1024 { return "\(JS.toFixed(mb / 1024, 1)) GB" }
        return "\(JS.int(JS.round(mb))) MB"
    }

    /// `num/den` as a rounded percentage; a zero (or `NaN`) denominator renders as an em dash,
    /// because JS `if (!den)` is a falsy check, not a comparison.
    public static func formatPercent(_ num: Double, _ den: Double) -> String {
        if den == 0 || den.isNaN { return "—" }
        return "\(JS.int(JS.round((num / den) * 100)))%"
    }

    // MARK: - GPU / TRES extraction

    /// GPU count from a node's `Gres` / `GresUsed` string, e.g. `gpu:a100:4(S:0-1)` → 4.
    ///
    /// The `(?:^|,)` anchor is why `gres/gpu:1` yields 0 here — that TRES-shaped string is
    /// `gpuCountFromTres`'s job.
    public static func gpuCountFromGres(_ gres: String) -> Int {
        if gres.isEmpty || gres == "(null)" { return 0 }
        guard let m = gresCount.exec(gres), let n = m[1] else { return 0 }
        return JS.int(JS.number(n))
    }

    /// GPU count from an AllocTRES / CfgTRES / `%b` string.
    ///
    /// The `=` forms are tried before the per-node colon form because AllocTRES carries both
    /// `gres/gpu=N` and `gres/gpu:<model>=N`.
    public static func gpuCountFromTres(_ tres: String) -> Int {
        if tres.isEmpty || tres == "(null)" { return 0 }
        if let m = tresCountEq.exec(tres), let n = m[1] { return JS.int(JS.number(n)) }
        // Per-node gres form (squeue %b): "gres/gpu:A100:4", "gres/gpu:2g.10gb:1", "gres/gpu:1".
        if let m = tresCountColon.exec(tres), let n = m[1] { return JS.int(JS.number(n)) }
        return 0
    }

    /// Requested/allocated memory from a TRES string, normalised to G where that reads better.
    public static func memFromTres(_ tres: String) -> String? {
        if tres.isEmpty || tres == "N/A" || tres == "(null)" { return nil }
        guard let m = memPattern.exec(tres), let digits = m[1] else { return nil }
        let val = JS.int(JS.number(digits))
        let unit = (m[2] ?? "").uppercased()
        if unit == "M" || unit.isEmpty {
            let gb = Double(val) / 1024
            if gb >= 1 {
                // JS `${gb}` prints an integral double without a fractional part.
                let isInteger = gb.truncatingRemainder(dividingBy: 1) == 0
                return isInteger ? "\(JS.int(gb))G" : "\(JS.toFixed(gb, 1))G"
            }
            return "\(val)M"
        }
        return "\(val)\(unit)"
    }

    /// A display label for a job's GPUs, e.g. `"4×H100"` / `"8 GPU"`, or `nil` when the string
    /// carries no GPU allocation.
    ///
    /// The four accepted spellings are tried in the order the TS uses, which is the order that
    /// surfaces a model name when one is available:
    /// 1. typed TRES `gres/gpu:<model>=N`
    /// 2. generic TRES `gres/gpu=N`
    /// 3. per-node gres / `squeue %b` `gres/gpu:<model>:N` (the shape a *pending* job has,
    ///    since its AllocTRES is not populated yet)
    /// 4. legacy GRES `gpu:<model>:N`
    ///
    /// A zero count is treated as "no GPUs" at every step (JS `if (!count) return null`).
    ///
    /// The TS spells this out as its own regex cascade; since `gpuInfoFromTres` runs the same
    /// four patterns in the same order with the same zero-count guard, and every branch's label
    /// is a pure function of `(count, type)`, delegating is behaviourally identical — the 71
    /// `gpuLabelFromTres` fixture cases pin that.
    public static func gpuLabelFromTres(_ tres: String) -> String? {
        guard let info = gpuInfoFromTres(tres) else { return nil }
        guard let type = info.type else { return "\(info.count) GPU" }
        return "\(info.count)×\(prettifyGpuModel(type))"
    }

    /// Count + raw gres type token for a job's allocated GPUs. Same spellings, same order and
    /// same zero-count handling as `gpuLabelFromTres`.
    public static func gpuInfoFromTres(_ tres: String) -> GpuInfo? {
        if tres.isEmpty || tres == "N/A" || tres == "(null)" { return nil }
        if let m = tresTyped.exec(tres), let n = m[2] {
            let count = JS.int(JS.number(n))
            return count != 0 ? GpuInfo(count: count, type: m[1]) : nil
        }
        if let m = tresGeneric.exec(tres), let n = m[1] {
            let count = JS.int(JS.number(n))
            return count != 0 ? GpuInfo(count: count, type: nil) : nil
        }
        if let m = tresPerNode.exec(tres), let n = m[2] {
            let count = JS.int(JS.number(n))
            return count != 0 ? GpuInfo(count: count, type: m[1]) : nil
        }
        if let m = gresLegacy.exec(tres), let n = m[2] {
            let count = JS.int(JS.number(n))
            return count != 0 ? GpuInfo(count: count, type: m[1]) : nil
        }
        return nil
    }

    /// `rtx_pro_6000` → `Rtx Pro 6000`. Slurm gres types are lowercase with underscores; this
    /// only replaces the underscores and uppercases each token's first character (so `2g.10gb`
    /// survives unchanged and `_leading` keeps its empty leading token).
    public static func prettifyGpuModel(_ raw: String) -> String {
        JS.split(raw, "_")
            .map { token -> String in
                guard let first = token.first else { return token }
                return String(first).uppercased() + String(token.dropFirst())
            }
            .joined(separator: " ")
    }

    // MARK: - Node / job display

    /// `scontrol` returns compound states such as `MIXED+DRAIN`; take the leading flag.
    public static func shortNodeState(_ state: String) -> String {
        JS.split(JS.split(state, "+")[0], ",")[0]
    }

    /// A node's drain/down reason, with Slurm's `None` sentinel (and a missing value) flattened
    /// to the empty string.
    public static func shortReason(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty, reason != "None" else { return "" }
        return reason
    }

    /// Semantic bucket for a job state — the SlurmKit stand-in for the TS `stateColor`.
    /// Lookup is by exact state string, exactly like the TS `STATE_COLORS` record.
    public static func stateCategory(_ state: String) -> JobStateCategory {
        JobStateCategory(rawValue: state) ?? .other
    }

    /// Semantic bucket for a node state — the stand-in for the TS `nodeStateColor`. The
    /// substring tests run in the TS's order, which matters for compound states like
    /// `MIXED+DRAIN` (drain wins).
    public static func nodeStateCategory(_ state: String) -> NodeStateCategory {
        let s = state.lowercased()
        if s.contains("down") || s.contains("drain") || s.contains("fail") { return .unavailable }
        if s.contains("alloc") { return .allocated }
        if s.contains("mix") { return .mixed }
        if s.contains("idle") { return .idle }
        if s.contains("reserved") || s.contains("maint") { return .reserved }
        return .other
    }
}

// Patterns ported verbatim from format.ts; JS `$` (end of input) is written `\z`.
private let gresCount = Pattern(#"(?:^|,)gpu(?::[^:,(]+)?:(\d+)"#)
private let tresCountEq = Pattern(#"gres/gpu(?::[^=,]+)?=(\d+)"#)
private let tresCountColon = Pattern(#"gres/gpu:(?:[^:=,]+:)?(\d+)(?:\z|,)"#)
private let memPattern = Pattern(#"(?:^|,)mem=(\d+)([TGMK]?)"#, caseInsensitive: true)
private let tresTyped = Pattern(#"gres/gpu:([^=,]+)=(\d+)"#)
private let tresGeneric = Pattern(#"gres/gpu=(\d+)"#)
private let tresPerNode = Pattern(#"gres/gpu:(?:([^:=,]+):)?(\d+)(?:\z|,)"#)
private let gresLegacy = Pattern(#"(?:^|,)gpu(?::([^:,(]+))?:(\d+)"#)
