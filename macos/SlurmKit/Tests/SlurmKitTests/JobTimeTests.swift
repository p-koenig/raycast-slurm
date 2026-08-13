import Foundation
import Testing

@testable import SlurmKit

// `Parse/JobTime.swift` has no golden fixtures: the TypeScript it is ported from
// (`buildJobTime` and the private helpers in `JobDetailView.tsx`) is only ever called from
// React render bodies, so the exporter never captured it. These are therefore hand-written
// unit tests, and they pin the clock: every `buildJobTime` case passes an explicit `nowMs`
// and an explicit UTC calendar, so a machine in any time zone gets the same answers.

/// Slurm prints local cluster time with no offset, and `parseSlurmDateTime` reads it in the
/// injected calendar's zone. Pinning UTC makes the expected epochs literal.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// `2026-01-01T00:00:00Z`, the instant the demo corpus is written around.
private let epochNewYear: Double = 1_767_225_600_000

@Suite("JobTime.parseSlurmDateTime")
struct ParseSlurmDateTimeTests {

    @Test("A well-formed Slurm timestamp is read in the given calendar's zone")
    func wellFormed() throws {
        let date = try #require(JobTime.parseSlurmDateTime("2026-01-01T00:00:00", calendar: utc))
        #expect(date.epochMillis == epochNewYear)
    }

    @Test("Time-of-day components are honoured")
    func timeOfDay() throws {
        let date = try #require(JobTime.parseSlurmDateTime("2025-12-31T23:14:37", calendar: utc))
        #expect(date.epochMillis == epochNewYear - ((45 * 60) + 23) * 1000)
    }

    @Test(
        "Slurm's sentinels and blank values yield nil",
        arguments: ["", "   ", "Unknown", "N/A", "None"]
    )
    func sentinels(value: String) {
        #expect(JobTime.parseSlurmDateTime(value, calendar: utc) == nil)
    }

    @Test("A missing field yields nil")
    func missing() {
        #expect(JobTime.parseSlurmDateTime(nil, calendar: utc) == nil)
    }

    @Test(
        "Anything that is not exactly the ISO-without-offset shape yields nil",
        arguments: [
            "2026-01-01",  // date only
            "2026-01-01T00:00",  // no seconds
            "2026-1-1T00:00:00",  // unpadded
            "2026-01-01T00:00:00Z",  // trailing zone
            "2026-01-01 00:00:00",  // space separator
            "today",
        ]
    )
    func rejected(value: String) {
        #expect(JobTime.parseSlurmDateTime(value, calendar: utc) == nil)
    }

    @Test("Surrounding whitespace is trimmed before matching")
    func trimmed() throws {
        let date = try #require(JobTime.parseSlurmDateTime("  2026-01-01T00:00:00\n", calendar: utc))
        #expect(date.epochMillis == epochNewYear)
    }
}

@Suite("JobTime.buildJobTime")
struct BuildJobTimeTests {

    /// The demo corpus's running job 145789: 12 h limit, started 45 min 23 s before new year.
    private let running: [String: String] = [
        "JobState": "RUNNING",
        "SubmitTime": "2025-12-31T23:11:37",
        "StartTime": "2025-12-31T23:14:37",
        "EndTime": "2026-01-01T11:14:37",
        "TimeLimit": "12:00:00",
    ]

    @Test("A running job's elapsed counts from StartTime to now, not to EndTime")
    func runningElapsedIsLive() {
        let oneHourIn = 1_767_225_600_000 + (14 * 60 + 37) * 1000  // StartTime + 1 h
        let t = JobTime.buildJobTime(fields: running, nowMs: Double(oneHourIn), calendar: utc)
        #expect(t.elapsedSec == 3600)
        #expect(t.limitSec == 43_200)
        #expect(t.remainingSec == 39_600)
        #expect(t.progress == 1.0 / 12.0)
    }

    @Test("Elapsed advances with the clock — this is what the 1 Hz re-render depends on")
    func elapsedTracksNow() {
        let start = 1_767_225_600_000 - ((45 * 60) + 23) * 1000
        let a = JobTime.buildJobTime(fields: running, nowMs: Double(start + 10_000), calendar: utc)
        let b = JobTime.buildJobTime(fields: running, nowMs: Double(start + 11_000), calendar: utc)
        #expect(a.elapsedSec == 10)
        #expect(b.elapsedSec == 11)
    }

    @Test("A clock behind StartTime clamps elapsed to zero rather than going negative")
    func elapsedNeverNegative() {
        let beforeStart = 1_767_225_600_000 - 24 * 3600 * 1000
        let t = JobTime.buildJobTime(fields: running, nowMs: Double(beforeStart), calendar: utc)
        #expect(t.elapsedSec == 0)
        #expect(t.remainingSec == 43_200)
        #expect(t.progress == 0)
    }

    @Test("Progress is clamped to 1 once a job overruns its limit")
    func progressClamped() {
        let wayPastLimit = 1_767_225_600_000 + 48 * 3600 * 1000
        let t = JobTime.buildJobTime(fields: running, nowMs: Double(wayPastLimit), calendar: utc)
        #expect(t.progress == 1)
        #expect(t.remainingSec == 0)
    }

    @Test("EndTime is the projected end for a running job")
    func runningEndsAtEndTime() throws {
        let t = JobTime.buildJobTime(fields: running, nowMs: epochNewYear, calendar: utc)
        let ends = try #require(t.ends)
        #expect(ends == JobTime.parseSlurmDateTime("2026-01-01T11:14:37", calendar: utc))
    }

    @Test("A running job with no EndTime projects StartTime + TimeLimit")
    func runningEndsProjected() throws {
        var fields = running
        fields["EndTime"] = "Unknown"
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        let ends = try #require(t.ends)
        let start = try #require(JobTime.parseSlurmDateTime("2025-12-31T23:14:37", calendar: utc))
        #expect(ends.epochMillis == start.epochMillis + 12 * 3600 * 1000)
    }

    @Test("UNLIMITED yields no limit, and therefore no remaining and no progress")
    func unlimited() {
        var fields = running
        fields["TimeLimit"] = "UNLIMITED"
        fields["EndTime"] = "Unknown"
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.limitSec == nil)
        #expect(t.remainingSec == nil)
        #expect(t.progress == nil)
        #expect(t.elapsedSec == 2_723)
        // With no limit there is nothing to project an end from either.
        #expect(t.ends == nil)
    }

    @Test("UNLIMITED is matched case-insensitively and after trimming")
    func unlimitedSpelling() {
        for spelling in ["unlimited", " Unlimited ", "UNLIMITED"] {
            var fields = running
            fields["TimeLimit"] = spelling
            #expect(JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc).limitSec == nil)
        }
    }

    @Test("An unparsable TimeLimit is treated as no limit, not as zero")
    func unparsableLimit() {
        var fields = running
        fields["TimeLimit"] = "N/A"
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.limitSec == nil)
        #expect(t.progress == nil)
    }

    @Test("A day-prefixed limit parses (the multi-node demo job's 7-00:00:00)")
    func dayPrefixedLimit() {
        var fields = running
        fields["TimeLimit"] = "7-00:00:00"
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.limitSec == 604_800)
    }

    @Test("A pending job has no elapsed, no remaining and no progress")
    func pending() {
        // Demo job 145847: AllocTRES empty, EndTime Unknown, StartTime is an *estimate*.
        let fields = [
            "JobState": "PENDING",
            "Reason": "Resources",
            "SubmitTime": "2025-12-31T23:55:00",
            "StartTime": "2026-01-01T00:40:00",
            "EndTime": "Unknown",
            "TimeLimit": "2:00:00",
        ]
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.elapsedSec == nil)
        #expect(t.remainingSec == nil)
        #expect(t.progress == nil)
        #expect(t.limitSec == 7_200)
        #expect(t.ends == nil)
        // The estimated start still surfaces — the pending pane renders it as "Est. Start".
        #expect(t.started == JobTime.parseSlurmDateTime("2026-01-01T00:40:00", calendar: utc))
        #expect(t.submitted == JobTime.parseSlurmDateTime("2025-12-31T23:55:00", calendar: utc))
    }

    @Test("A pending job with no estimated start yields nil rather than a placeholder date")
    func pendingWithoutEstimate() {
        let fields = ["JobState": "PENDING", "StartTime": "Unknown", "EndTime": "Unknown", "TimeLimit": "2:00:00"]
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.started == nil)
        #expect(t.elapsedSec == nil)
    }

    @Test("A finished job's elapsed is the closed EndTime − StartTime interval, ignoring now")
    func finishedElapsedIsClosed() {
        let fields = [
            "JobState": "COMPLETING",
            "StartTime": "2025-12-31T23:51:18",
            "EndTime": "2026-01-01T00:00:00",
            "TimeLimit": "0:30:00",
        ]
        let farFuture = epochNewYear + 365 * 86_400 * 1000
        let t = JobTime.buildJobTime(fields: fields, nowMs: farFuture, calendar: utc)
        #expect(t.elapsedSec == 522)
        // Finished jobs never get a remaining row, even though the limit parsed.
        #expect(t.remainingSec == nil)
        #expect(t.limitSec == 1_800)
    }

    @Test("A decorated RUNNING state still counts as running")
    func decoratedRunningState() {
        var fields = running
        fields["JobState"] = "RUNNING+CONFIGURING"
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.remainingSec != nil)
    }

    @Test("A job with no StartTime at all has no elapsed and no progress")
    func noStart() {
        let fields = ["JobState": "RUNNING", "TimeLimit": "1:00:00"]
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.elapsedSec == nil)
        #expect(t.progress == nil)
        #expect(t.remainingSec == nil)
        #expect(t.ends == nil)
    }

    @Test("A zero time limit yields no progress (division guard), but still a remaining of 0")
    func zeroLimit() {
        var fields = running
        fields["TimeLimit"] = "0:00:00"
        let t = JobTime.buildJobTime(fields: fields, nowMs: epochNewYear, calendar: utc)
        #expect(t.limitSec == 0)
        #expect(t.progress == nil)
        #expect(t.remainingSec == 0)
    }

    @Test("An empty field map produces an all-nil timeline rather than crashing")
    func empty() {
        #expect(JobTime.buildJobTime(fields: [:], nowMs: epochNewYear, calendar: utc) == JobTime.JobTimeInfo())
    }
}

@Suite("JobTime.prettifyMem")
struct PrettifyMemTests {

    @Test(
        "A compact memFromTres suffix expands",
        arguments: [
            ("336G", "336 GB"),
            ("64G", "64 GB"),
            ("1.5G", "1.5 GB"),
            ("512M", "512 MB"),
            ("2T", "2 TB"),
            ("900K", "900 KB"),
            ("64g", "64 GB"),
        ]
    )
    func expands(input: String, expected: String) {
        #expect(JobTime.prettifyMem(input) == expected)
    }

    @Test(
        "Anything that is not <number><unit> passes through untouched",
        arguments: ["", "—", "64", "64GB", "cpu=16,mem=64G", "GB"]
    )
    func passthrough(input: String) {
        #expect(JobTime.prettifyMem(input) == input)
    }
}

@Suite("JobTime.stripUid")
struct StripUidTests {

    @Test("The scontrol (uid) tail is removed")
    func strips() {
        #expect(JobTime.stripUid("r.shaw(1000)") == "r.shaw")
        #expect(JobTime.stripUid("alice.chen(1042)  ") == "alice.chen")
    }

    @Test("A UserId with no uid tail is returned as-is")
    func noTail() {
        #expect(JobTime.stripUid("r.shaw") == "r.shaw")
    }

    @Test("A missing UserId renders as an em dash")
    func missing() {
        #expect(JobTime.stripUid(nil) == "—")
        #expect(JobTime.stripUid("") == "—")
    }

    @Test("Stripping never yields an empty string — the original wins instead")
    func neverEmpties() {
        #expect(JobTime.stripUid("(1000)") == "(1000)")
    }

    @Test("Only a trailing uid is stripped, not one embedded in the name")
    func onlyTrailing() {
        #expect(JobTime.stripUid("svc(1)acct(1000)") == "svc(1)acct")
    }
}

@Suite("JobTime.firstMeaningfulTres")
struct FirstMeaningfulTresTests {

    @Test("The first candidate carrying data wins")
    func firstWins() {
        #expect(JobTime.firstMeaningfulTres("cpu=16", "cpu=8") == "cpu=16")
    }

    @Test(
        "scontrol's truthy placeholders are skipped — the rule a plain `a || b` gets wrong",
        arguments: ["(null)", "N/A", "", "   "]
    )
    func placeholdersSkipped(placeholder: String) {
        // This is the pending-job case: AllocTRES is a placeholder, ReqTRES has the request.
        #expect(
            JobTime.firstMeaningfulTres(placeholder, "cpu=8,mem=64G,gres/gpu:a100=2")
                == "cpu=8,mem=64G,gres/gpu:a100=2"
        )
    }

    @Test("A nil candidate is skipped like a blank one")
    func nilSkipped() {
        #expect(JobTime.firstMeaningfulTres(nil, "(null)", nil, "cpu=4") == "cpu=4")
    }

    @Test("All-placeholder candidates yield the empty string, never a placeholder")
    func allPlaceholders() {
        #expect(JobTime.firstMeaningfulTres("(null)", "N/A", "", nil) == "")
        #expect(JobTime.firstMeaningfulTres() == "")
    }

    @Test("The value is trimmed, as the log panes rely on for StdOut paths")
    func trims() {
        #expect(JobTime.firstMeaningfulTres("  /home/r.shaw/logs/a.out\n") == "/home/r.shaw/logs/a.out")
    }

    @Test("The array overload behaves identically")
    func arrayOverload() {
        #expect(JobTime.firstMeaningfulTres(["(null)", "cpu=2"]) == "cpu=2")
    }
}
