import Foundation
import Testing

@testable import SlurmKit

// Behaviour no fixture can reach, because the demo corpus never produces it.

@Suite("Partition activity: time-left ordering")
struct TimeLeftSortTests {

    /// Build the four-section stdout `listPartitionActivity` returns, with no AllocTRES rows so
    /// the entries keep their `%b` shorthand and the sort is the only thing under test.
    private func stdout(runningRows: [String]) -> String {
        """
        ---PALLOC---
        ---RUN---
        \(runningRows.joined(separator: "\n"))
        ---RALLOC---
        """
    }

    /// `%i|%j|%u|%C|%m|%l|%L|%b`
    private func row(_ jobId: String, timeLeft: String) -> String {
        "\(jobId)|job|u|1|1G|1-00:00:00|\(timeLeft)|(null)"
    }

    @Test("UNLIMITED, empty and unparsable time-left values sink to the end")
    func sinkers() {
        let parsed = SqueueParse.partitionActivity(
            stdout: stdout(runningRows: [
                row("1", timeLeft: "UNLIMITED"),
                row("2", timeLeft: "4:00:00"),
                row("3", timeLeft: ""),
                row("4", timeLeft: "0:30"),
                row("5", timeLeft: "not-a-duration"),
                row("6", timeLeft: "1-00:00:00"),
                row("7", timeLeft: "unlimited"),
            ])
        )
        // 0:30 (30s) < 4:00:00 < 1-00:00:00, then everything that could not be ranked.
        #expect(parsed.running.map(\.jobId) == ["4", "2", "6", "1", "3", "5", "7"])
    }

    @Test("the sort is stable, so equally unrankable rows keep squeue's order")
    func stability() {
        let ids = (1...12).map(String.init)
        let parsed = SqueueParse.partitionActivity(
            stdout: stdout(runningRows: ids.map { row($0, timeLeft: "UNLIMITED") })
        )
        #expect(parsed.running.map(\.jobId) == ids)
    }

    @Test("timeLeftSeconds maps the unrankable values to MAX_SAFE_INTEGER")
    func sentinelValue() {
        #expect(SqueueParse.timeLeftSeconds("") == SqueueParse.maxSafeInteger)
        #expect(SqueueParse.timeLeftSeconds("UNLIMITED") == SqueueParse.maxSafeInteger)
        #expect(SqueueParse.timeLeftSeconds("unlimited") == SqueueParse.maxSafeInteger)
        #expect(SqueueParse.timeLeftSeconds("garbage") == SqueueParse.maxSafeInteger)
        #expect(SqueueParse.timeLeftSeconds("0:30") == 30)
        #expect(SqueueParse.timeLeftSeconds("1-00:00:00") == 86_400)
    }
}

@Suite("Metric stream: timestamp fallback")
struct MetricStreamUnitTests {

    private let tick = """
        T not-a-timestamp
        G 0, NVIDIA L40S, 50, 23034, 46068
        C 42.0 1024 4096
        E

        """

    @Test("an unparsable T line falls back to the current time")
    func invalidTimestampFallsBackToNow() throws {
        let before = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        let parsed = MetricStream.parse(buffer: tick)
        let after = (Date().timeIntervalSince1970 * 1000).rounded(.down)

        let sample = try #require(parsed.samples.first)
        #expect(parsed.samples.count == 1)
        #expect(sample.t >= before && sample.t <= after, "timestamp \(sample.t) is not between \(before) and \(after)")
        // The rest of the tick still parses.
        #expect(sample.gpus.map(\.index) == [0])
        #expect(sample.cpu == 42.0)
    }

    @Test("a zero T line also falls back, because the TS guard is `Number(...) || Date.now()`")
    func zeroTimestampFallsBack() throws {
        let parsed = MetricStream.parse(buffer: tick.replacingOccurrences(of: "not-a-timestamp", with: "0"), now: 4242)
        #expect(try #require(parsed.samples.first).t == 4242)
    }

    @Test("a valid T line is used verbatim")
    func validTimestampWins() throws {
        let parsed = MetricStream.parse(
            buffer: tick.replacingOccurrences(of: "not-a-timestamp", with: "1767225600000"),
            now: 4242
        )
        #expect(try #require(parsed.samples.first).t == 1_767_225_600_000)
    }
}

@Suite("tokenizeKv edge cases")
struct TokenizeKvTests {

    // The demo corpus contains no duplicate keys and no bare tokens, so these two documented
    // behaviours are unreachable from the fixtures and are pinned here instead.

    @Test("the first occurrence of a key wins")
    func firstKeyWins() {
        let fields = ScontrolParse.tokenizeKv("State=IDLE Reason=None State=DOWN Reason=\"drained by admin\"")
        #expect(fields["State"] == "IDLE")
        #expect(fields["Reason"] == "None")
    }

    @Test("quoted values keep their spaces")
    func quotedValues() {
        let fields = ScontrolParse.tokenizeKv("NodeName=gpu16 Reason=\"hardware fault GPU0\" CPUTot=64")
        #expect(fields["Reason"] == "hardware fault GPU0")
        #expect(fields["CPUTot"] == "64")
    }

    @Test("bare tokens are skipped without swallowing what follows")
    func bareTokens() {
        let fields = ScontrolParse.tokenizeKv("JobId=1 BARE ANOTHER=2 trailing")
        #expect(fields == ["JobId": "1", "ANOTHER": "2"])
    }

    @Test("an unterminated quote consumes the remainder")
    func unterminatedQuote() {
        let fields = ScontrolParse.tokenizeKv("A=1 Reason=\"never closed")
        #expect(fields == ["A": "1", "Reason": "never closed"])
    }

    @Test("newlines are whitespace, which is what makes multi-line scontrol output tokenize")
    func newlinesAreWhitespace() {
        let fields = ScontrolParse.tokenizeKv("JobId=1 JobName=x\n   UserId=r.shaw(1000)\n")
        #expect(fields == ["JobId": "1", "JobName": "x", "UserId": "r.shaw(1000)"])
    }
}

@Suite("Command builders without a fixture")
struct CommandBuilderTests {

    @Test("detectUser, cancelJob and the alloc format are single-sourced")
    func commands() {
        #expect(SlurmCommands.detectUser() == "whoami")
        #expect(SlurmCommands.cancelJob(jobId: "145789") == "scancel 145789")
        // shellQuote protects the bracketed array notation scancel is happy to take.
        #expect(SlurmCommands.cancelJob(jobId: "145851_[3-64%1]") == "scancel '145851_[3-64%1]'")
        #expect(SqueueParse.allocTresFormat == "ArrayJobID:24,ArrayTaskID:24,tres-alloc:512")
        #expect(SlurmCommands.listJobs(user: "r.shaw").contains(SqueueParse.allocTresFormat))
    }

    @Test("splitOnSentinel yields the whole string when the sentinel is absent")
    func sentinelAbsent() {
        let (head, tail) = SqueueParse.splitOnSentinel("no sentinel here", "---ALLOC---")
        #expect(head == "no sentinel here")
        #expect(tail == "")
    }
}
