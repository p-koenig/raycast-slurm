import Foundation
import SlurmKit

/// App-layer display helpers: the parts of the reference `format.ts` that are presentation
/// rather than parsing, plus the native replacements for its hand-rolled date formatters.
///
/// `fitSubtitleToRow` is **not** ported: it exists only because Raycast gives no row width and
/// lets exactly one element overflow. SwiftUI lays out properly, so job names get `.truncationMode`
/// and the accessories keep their intrinsic width.
enum Display {

    // MARK: - Dates

    /// `"Tue 14:25"` when the date falls today, otherwise `"Tue 13 Jun, 14:25"`
    /// (`format.ts:63`, `formatShortDateTimeFor`), via `Date.FormatStyle` rather than the TS's
    /// hand-assembled `toLocaleString` calls.
    static func shortDateTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        if calendar.isDate(date, inSameDayAs: now) { return "\(weekday) \(time)" }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return "\(weekday) \(day), \(time)"
    }

    /// `"in 2h 14m"` / `"3d ago"` (`format.ts:74`, `relativeFromNow`). `Date.RelativeFormatStyle`
    /// is the native equivalent and localises for free — and unlike `RelativeDateTimeFormatter`
    /// it is a `Sendable` value, so it needs no shared mutable instance. The "just now" floor at
    /// one minute is kept because the TS has it and the Schedule pane reads oddly without it.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    /// The composite the detail rows show: `"Tue 13 Jun, 14:25 · in 2h"`. `"—"` for no date,
    /// which is what `withRelative` returns for Slurm's sentinels.
    static func dateWithRelative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        return "\(shortDateTime(date, now: now)) · \(relative(date, now: now))"
    }

    // MARK: - Counts

    /// The menu bar title: `"R3·P2"`, or `"idle"` when nothing is running, pending or completing
    /// (`menu-bar.tsx:151`, `formatTitle`).
    static func menuBarTitle(_ counts: [String: Int]) -> String {
        let r = counts["RUNNING"] ?? 0
        let p = counts["PENDING"] ?? 0
        let c = counts["COMPLETING"] ?? 0
        if r == 0 && p == 0 && c == 0 { return "idle" }
        var parts: [String] = []
        if r != 0 { parts.append("R\(r)") }
        if p != 0 { parts.append("P\(p)") }
        if c != 0 { parts.append("CG\(c)") }
        return parts.joined(separator: "·")
    }

    /// The My Jobs header count: first letter of each state + its count, RUNNING/PENDING/
    /// COMPLETING first and everything else after (`manage-jobs.tsx:356`, `formatCounts`).
    static func stateCounts(_ counts: [String: Int]) -> String {
        let order = ["RUNNING", "PENDING", "COMPLETING"]
        var parts: [String] = []
        for key in order where (counts[key] ?? 0) != 0 {
            parts.append("\(key.prefix(1))\(counts[key]!)")
        }
        // The TS iterates `Object.entries`, i.e. insertion order of the counting pass. Sorting
        // is the deterministic stand-in — Swift dictionaries have no insertion order at all.
        for key in counts.keys.sorted() where !order.contains(key) {
            parts.append("\(key.prefix(1))\(counts[key]!)")
        }
        return parts.isEmpty ? "idle" : parts.joined(separator: "·")
    }

    static func countByState(_ jobs: [Job]) -> [String: Int] {
        var out: [String: Int] = [:]
        for job in jobs { out[job.state, default: 0] += 1 }
        return out
    }

    /// `"1 job"` / `"3 jobs"` (`NodeJobsView.tsx:167`).
    static func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: - Node chips

    /// One node-utilization chip.
    struct Tag: Identifiable, Equatable {
        let id: String
        let value: String
        let role: Role

        /// The colour is resolved at render time (an asset `Color` is not `Equatable` in a way
        /// that survives appearance changes), so the model stays a plain value.
        enum Role: Equatable {
            case state(String)
            case fixed(ColorRole)
        }

        enum ColorRole: Equatable { case green, yellow, red, orange, blue, purple, secondary }
    }

    /// The chips describing how full a node is: state, CPU load, memory and — only for nodes that
    /// have any — GPU allocation. Port of `nodeUtilTags` (`format.ts:388-418`), shared by the node
    /// list and the per-node drill-down so a node reads identically in both.
    static func nodeUtilTags(_ n: SlurmNode) -> [Tag] {
        let usedMem = Double(max(0, n.realMemoryMB - n.freeMemoryMB))
        let total = Double(n.realMemoryMB)
        let cpuRatio: Double? = {
            guard let load = n.cpuLoad, n.cpuTot != 0 else { return nil }
            return load / Double(n.cpuTot)
        }()

        var tags: [Tag] = [
            Tag(id: "state", value: SlurmFormat.shortNodeState(n.state), role: .state(n.state)),
            Tag(
                id: "cpu",
                value: n.cpuLoad.map { "cpu \(JSFormat.toFixed($0, 2))/\(n.cpuTot)" } ?? "cpu —/\(n.cpuTot)",
                role: .fixed(
                    cpuRatio == nil
                        ? .secondary
                        : (cpuRatio! > 1.0 ? .red : (cpuRatio! > 0.7 ? .orange : .green))
                )
            ),
            Tag(
                id: "mem",
                value: "mem \(SlurmFormat.formatBytesMB(usedMem))/\(SlurmFormat.formatBytesMB(total))"
                    + " (\(SlurmFormat.formatPercent(usedMem, total)))",
                role: .fixed(usedMem / Swift.max(1, total) > 0.85 ? .red : .blue)
            ),
        ]

        let gpuTotal = SlurmFormat.gpuCountFromGres(n.gres)
        if gpuTotal != 0 {
            // `||` in the TS is a falsy fallback: a zero from AllocTRES defers to GresUsed.
            let fromTres = SlurmFormat.gpuCountFromTres(n.allocTres)
            let gpuAlloc = fromTres != 0 ? fromTres : SlurmFormat.gpuCountFromGres(n.gresUsed)
            tags.append(
                Tag(
                    id: "gpu",
                    value: "gpu \(gpuAlloc)/\(gpuTotal)",
                    role: .fixed(gpuAlloc >= gpuTotal ? .red : (gpuAlloc > 0 ? .orange : .green))
                )
            )
        }
        return tags
    }

    // MARK: - Shapes (Info tab)

    /// `gpuModelFromGres` (`format.ts:420`): the gres type token, else a guess from the node's
    /// feature list, else the literal `"gpu"`.
    static func gpuModelFromGres(_ gres: String, features: String) -> String {
        if gres.isEmpty || gres == "(null)" { return "" }
        if let m = gresModel.firstMatch(in: gres), let model = m.first, let model { return model }
        let tokens = features.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for guess in ["a100", "h100", "v100", "a40", "rtx3090", "rtx2080ti"] where tokens.contains(guess) {
            return guess
        }
        return "gpu"
    }

    private static let gresModel = SimplePattern(#"(?:^|,)gpu:([^:,(]+):\d+"#)
}

/// `Number.prototype.toFixed` for the two-decimal CPU load chip. SlurmKit's `JS.toFixed` is
/// internal to the package, and the only App-side need is this one chip, so a thin wrapper over
/// `String(format:)` is enough — a CPU load average never lands on an exact binary tie.
enum JSFormat {
    static func toFixed(_ x: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", x)
    }
}

/// A minimal precompiled regex for the two App-layer patterns that have no SlurmKit equivalent.
struct SimplePattern {
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        self.regex = try! NSRegularExpression(pattern: pattern)
    }

    /// The first match's capture groups (index 1 upward), or `nil` when there is no match.
    func firstMatch(in s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}
