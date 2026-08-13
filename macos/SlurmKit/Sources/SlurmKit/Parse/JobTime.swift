import Foundation

/// The job-detail scalars: `scontrol` timestamps, the derived timeline, and the three small
/// string cleaners the detail view needs. Ported from `src/lib/format.ts` and the private helpers
/// at the bottom of `src/lib/components/JobDetailView.tsx`.
///
/// What is deliberately *not* here: the TypeScript's date **formatting**
/// (`formatShortDateTime`, `relativeFromNow`, `withRelative`). Those exist because JS has no
/// locale-aware relative formatter worth using; on Apple platforms `Date.FormatStyle` and
/// `RelativeDateTimeFormatter` do the same job better and belong to the App layer. So
/// `buildJobTime` hands back `Date`s and second counts and lets the view decide how to spell
/// them. `progressBar` is not ported either — SwiftUI has `ProgressView`.
public enum JobTime {

    // MARK: - Timestamps

    /// A Slurm ISO datetime (`"2025-06-10T14:23:45"`) as a `Date`, or `nil` for an empty value,
    /// one of Slurm's sentinels (`Unknown`, `N/A`, `None`), or anything that is not exactly that
    /// shape.
    ///
    /// The components are interpreted in `calendar`'s time zone, which mirrors the TS
    /// `new Date(y, mo - 1, d, …)` — Slurm prints local cluster time with no offset, and the
    /// extension has always read it as local. `calendar` is injectable so tests are not at the
    /// mercy of the machine's zone.
    public static func parseSlurmDateTime(_ s: String?, calendar: Calendar = .current) -> Date? {
        let v = JS.trim(s ?? "")
        if v.isEmpty || v == "Unknown" || v == "N/A" || v == "None" { return nil }
        guard let m = slurmDateTime.exec(v) else { return nil }
        var components = DateComponents()
        components.year = Int(JS.number(m[1] ?? ""))
        components.month = Int(JS.number(m[2] ?? ""))
        components.day = Int(JS.number(m[3] ?? ""))
        components.hour = Int(JS.number(m[4] ?? ""))
        components.minute = Int(JS.number(m[5] ?? ""))
        components.second = Int(JS.number(m[6] ?? ""))
        return calendar.date(from: components)
    }

    // MARK: - Timeline

    /// The time facts a job detail renders, all derived from `scontrol` fields.
    ///
    /// Every field is optional in the same places the TS returns `null`, so a view can decide
    /// "row absent" rather than inventing a placeholder: a finished job has no `remainingSec`, an
    /// UNLIMITED job has no `limitSec` (and therefore no `progress`), a pending job has no
    /// `elapsedSec`.
    public struct JobTimeInfo: Equatable, Sendable {

        /// Wallclock consumed. Live (`now - StartTime`) while RUNNING, otherwise the closed
        /// interval `EndTime - StartTime`.
        public var elapsedSec: Double?

        /// `TimeLimit` in seconds; `nil` for `UNLIMITED` or an unparsable limit.
        public var limitSec: Double?

        /// Time left against the limit. RUNNING **and** limited only.
        public var remainingSec: Double?

        /// `elapsed / limit`, clamped to `0...1`. Needs a positive limit and a known elapsed.
        public var progress: Double?

        public var submitted: Date?
        public var started: Date?

        /// `EndTime` when Slurm gives one; for a RUNNING job whose `EndTime` is missing, the
        /// projection `StartTime + TimeLimit`.
        public var ends: Date?

        public init(
            elapsedSec: Double? = nil,
            limitSec: Double? = nil,
            remainingSec: Double? = nil,
            progress: Double? = nil,
            submitted: Date? = nil,
            started: Date? = nil,
            ends: Date? = nil
        ) {
            self.elapsedSec = elapsedSec
            self.limitSec = limitSec
            self.remainingSec = remainingSec
            self.progress = progress
            self.submitted = submitted
            self.started = started
            self.ends = ends
        }
    }

    /// Derive the timeline from `scontrol show job` fields.
    ///
    /// Pure and `nowMs`-parameterised so the 1 Hz re-render of a RUNNING job's elapsed/remaining
    /// is a plain recomputation with no hidden clock — and so the unit tests can pin a clock.
    ///
    /// - Parameters:
    ///   - fields: the `Key=Value` map from `ScontrolParse.jobDetail`.
    ///   - nowMs: epoch milliseconds. Only read for RUNNING jobs.
    public static func buildJobTime(
        fields: [String: String],
        nowMs: Double,
        calendar: Calendar = .current
    ) -> JobTimeInfo {
        // `startsWith("RUNNING")`, not `==`: Slurm decorates states (`RUNNING+CONFIGURING`).
        let running = (fields["JobState"] ?? "").uppercased().hasPrefix("RUNNING")
        let start = parseSlurmDateTime(fields["StartTime"], calendar: calendar)
        let end = parseSlurmDateTime(fields["EndTime"], calendar: calendar)
        let rawLimit = fields["TimeLimit"] ?? ""
        let limitSec: Double? =
            JS.trim(rawLimit).uppercased() == "UNLIMITED"
            ? nil
            : SlurmFormat.parseSlurmDurationSeconds(rawLimit)

        var elapsedSec: Double?
        if let start {
            if running {
                elapsedSec = max(0, JS.round((nowMs - start.epochMillis) / 1000))
            } else if let end {
                elapsedSec = max(0, JS.round((end.epochMillis - start.epochMillis) / 1000))
            }
        }

        var remainingSec: Double?
        if running, let limitSec, let elapsedSec {
            remainingSec = max(0, limitSec - elapsedSec)
        }

        var progress: Double?
        if let limitSec, limitSec > 0, let elapsedSec {
            progress = max(0, min(1, elapsedSec / limitSec))
        }

        // For a RUNNING job `scontrol`'s EndTime is already the projected end; the fallback only
        // matters on clusters (or states) where it is missing.
        var ends = end
        if ends == nil, running, let start, let limitSec {
            ends = Date(timeIntervalSince1970: start.timeIntervalSince1970 + limitSec)
        }

        return JobTimeInfo(
            elapsedSec: elapsedSec,
            limitSec: limitSec,
            remainingSec: remainingSec,
            progress: progress,
            submitted: parseSlurmDateTime(fields["SubmitTime"], calendar: calendar),
            started: start,
            ends: ends
        )
    }

    // MARK: - Field cleaners

    /// `memFromTres`'s compact suffix expanded for display: `"336G"` → `"336 GB"`.
    /// Anything that is not `<number><T|G|M|K>` is returned untouched.
    public static func prettifyMem(_ mem: String) -> String {
        guard let m = memSuffix.exec(mem), let value = m[1], let unit = m[2] else { return mem }
        return "\(value) \(unit.uppercased())B"
    }

    /// `scontrol` reports `UserId` as `"username(1000)"`; show just the username.
    ///
    /// Returns `"—"` when the field is absent, and falls back to the original string if stripping
    /// the tail would leave nothing (`"(1000)"` stays `"(1000)"` rather than becoming blank).
    public static func stripUid(_ userId: String?) -> String {
        guard let userId, !userId.isEmpty else { return "—" }
        let stripped = JS.trim(uidTail.replaceFirst(in: userId, with: ""))
        return stripped.isEmpty ? userId : stripped
    }

    /// The first candidate that actually carries data.
    ///
    /// `scontrol` fills unset fields with the literal `"(null)"` or `"N/A"`, both of which are
    /// *truthy* in JS and would win a plain `a || b` — which is why a pending job (whose
    /// `AllocTRES` is `"(null)"` on most clusters and `""` on others) would otherwise never fall
    /// through to its `ReqTRES`. Returns `""` when none are usable.
    ///
    /// It is also the reason the log panes route `StdOut`/`StdErr` through here: the same
    /// placeholders appear in those fields.
    public static func firstMeaningfulTres(_ candidates: String?...) -> String {
        firstMeaningfulTres(candidates)
    }

    public static func firstMeaningfulTres(_ candidates: [String?]) -> String {
        for candidate in candidates {
            let v = JS.trim(candidate ?? "")
            if !v.isEmpty && v != "(null)" && v != "N/A" { return v }
        }
        return ""
    }
}

extension Date {
    /// `Date.prototype.getTime()`.
    var epochMillis: Double { timeIntervalSince1970 * 1000 }
}

// `/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$/`, with the JS end-of-input anchor.
private let slurmDateTime = Pattern(#"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\z"#)
private let memSuffix = Pattern(#"^(\d+(?:\.\d+)?)([TGMK])\z"#, caseInsensitive: true)
private let uidTail = Pattern(#"\(\d+\)\s*\z"#)
