import Foundation
import Testing

@testable import SlurmKit

// Golden tests: each fixture case's `input` goes through the ported Swift parser and the decoded
// `expected` must compare equal. Every kind is parameterized per case so a failure names the
// case (Swift Testing prints the argument's `description`, which is the fixture case name).

@Suite("Fixture inventory")
struct FixtureInventoryTests {

    @Test(
        "every fixture kind is present with its full case count",
        arguments: Fixtures.expectedCaseCounts.map(\.kind)
    )
    func kindIsFullyLoaded(kind: String) {
        let expected = Fixtures.expectedCaseCounts.first { $0.kind == kind }!.count
        let actual = Fixtures.rawCases(kind).count
        // If the exporter grew new cases, update Fixtures.expectedCaseCounts deliberately; if it
        // shrank, something regressed.
        #expect(actual == expected, "fixtures/\(kind).json has \(actual) cases, expected \(expected)")
    }
}

@Suite("Golden: squeue job lists")
struct JobListGoldenTests {

    static let userCases = Fixtures.cases("jobs-user", as: [Job].self)
    static let allCases = Fixtures.cases("jobs-all", as: [Job].self)

    @Test("jobs-user parses and joins AllocTRES", arguments: userCases)
    func jobsUser(c: FixtureCase<[Job]>) {
        // The two `*-brief` cases record demo-mode noise faithfully: listJobsBrief issues a
        // single squeue with no sentinel, but demo.ts keys its responses on the command prefix
        // and hands back the two-block body anyway. The TS therefore parses the sentinel line
        // and the fixed-width alloc rows into junk Jobs (a pipe-free row becomes
        // jobId=<whole line>), and this port must reproduce that tolerance exactly.
        let parsed = c.name.hasSuffix("-brief")
            ? SqueueParse.jobsBrief(stdout: c.input ?? "")
            : SqueueParse.jobs(stdout: c.input ?? "")
        #expect(parsed == c.expected, "jobs-user/\(c.name)")
    }

    @Test("jobs-user command string", arguments: userCases)
    func jobsUserCommand(c: FixtureCase<[Job]>) {
        let built = c.name.hasSuffix("-brief")
            ? SlurmCommands.listJobsBrief(user: demoUser)
            : SlurmCommands.listJobs(user: demoUser)
        #expect(built == c.cmd, "jobs-user/\(c.name) command")
    }

    @Test("jobs-all parses and joins AllocTRES", arguments: allCases)
    func jobsAll(c: FixtureCase<[Job]>) {
        #expect(SqueueParse.allJobs(stdout: c.input ?? "") == c.expected, "jobs-all/\(c.name)")
    }

    @Test("jobs-all command string", arguments: allCases)
    func jobsAllCommand(c: FixtureCase<[Job]>) {
        #expect(SlurmCommands.listAllJobs() == c.cmd, "jobs-all/\(c.name) command")
    }

    /// The account the demo corpus is exported for (`DEMO_USER` in `src/lib/demo.ts`).
    private var demoUser: String { "r.shaw" }
}

@Suite("Golden: node drill-down")
struct NodeJobGoldenTests {

    static let cases = Fixtures.cases("node-jobs", as: [NodeJob].self)

    @Test("node-jobs parses and joins AllocTRES", arguments: cases)
    func nodeJobs(c: FixtureCase<[NodeJob]>) {
        #expect(SqueueParse.nodeJobs(stdout: c.input ?? "") == c.expected, "node-jobs/\(c.name)")
    }

    @Test("node-jobs command string", arguments: cases)
    func nodeJobsCommand(c: FixtureCase<[NodeJob]>) {
        // The exporter names each case "<host>-<node>-<description>".
        let node = String(c.name.split(separator: "-")[1])
        #expect(SlurmCommands.listNodeJobs(node: node) == c.cmd, "node-jobs/\(c.name) command")
    }
}

@Suite("Golden: partition activity")
struct PartitionActivityGoldenTests {

    static let cases = Fixtures.cases("partition-activity", as: PartitionActivity.self)

    @Test("partition-activity parses all four sections", arguments: cases)
    func partitionActivity(c: FixtureCase<PartitionActivity>) {
        #expect(SqueueParse.partitionActivity(stdout: c.input ?? "") == c.expected, "partition-activity/\(c.name)")
    }

    @Test("partition-activity command string", arguments: cases)
    func partitionActivityCommand(c: FixtureCase<PartitionActivity>) {
        // Recovered from the captured command rather than re-derived from the case name, since
        // one case deliberately uses the empty partition (shellQuote("") -> '').
        let partition = partitionArgument(from: c.cmd ?? "")
        #expect(
            SlurmCommands.listPartitionActivity(partition: partition) == c.cmd,
            "partition-activity/\(c.name) command"
        )
    }

    /// Pull the value of the first `-p <value>` out of a captured command, undoing shellQuote.
    private func partitionArgument(from cmd: String) -> String {
        guard let r = cmd.range(of: " -p ") else { return "" }
        let rest = cmd[r.upperBound...]
        if rest.first == "'" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return "" }
            return String(body[body.startIndex..<end]).replacingOccurrences(of: #"'\''"#, with: "'")
        }
        return String(rest.prefix(while: { $0 != " " }))
    }
}

@Suite("Golden: scontrol")
struct ScontrolGoldenTests {

    static let nodeCases = Fixtures.cases("nodes", as: [SlurmNode].self)
    static let detailCases = Fixtures.cases("job-detail", as: JobDetail.self)

    @Test("nodes parse from scontrol show node --oneliner", arguments: nodeCases)
    func nodes(c: FixtureCase<[SlurmNode]>) {
        #expect(ScontrolParse.nodes(stdout: c.input ?? "") == c.expected, "nodes/\(c.name)")
    }

    @Test("nodes command string", arguments: nodeCases)
    func nodesCommand(c: FixtureCase<[SlurmNode]>) {
        #expect(SlurmCommands.listNodes() == c.cmd, "nodes/\(c.name) command")
    }

    @Test("job-detail tokenizes scontrol show job", arguments: detailCases)
    func jobDetail(c: FixtureCase<JobDetail>) {
        let input = c.input ?? ""
        let parsed = ScontrolParse.jobDetail(stdout: input)
        // `expected` carries only `fields`; the exporter drops `raw` because it is byte-identical
        // to the case input, which is asserted here instead.
        #expect(parsed.fields == c.expected.fields, "job-detail/\(c.name)")
        #expect(parsed.raw == input, "job-detail/\(c.name) raw")
    }

    /// The `squeue`-shaped job id the exporter asked `showJob` for, per case. It cannot be
    /// recovered from the fixture itself: `scontrol` answers a pending array range with the base
    /// id (`145851`), which is precisely the normalisation `ScontrolParse.jobId` performs and
    /// this test exists to pin. Mirrors `detailTargets` in `scripts/export-fixtures.ts`.
    static let queriedJobIds: [String: String] = [
        "phoenix-running-plain": "145789",
        "phoenix-running-array-task": "145843_7",
        "phoenix-pending-array-range": "145851_[3-64%1]",
        "phoenix-pending-plain": "145847",
        "phoenix-completing": "145855",
        "phoenix-running-multinode": "145782",
        "phoenix-not-found": "999999",
        "nimbus-running-cpu-only": "92341",
        "nimbus-pending-cpu-only": "92358",
    ]

    @Test("job-detail command string applies scontrolJobId", arguments: detailCases)
    func jobDetailCommand(c: FixtureCase<JobDetail>) throws {
        let jobId = try #require(Self.queriedJobIds[c.name], "no queried job id recorded for \(c.name)")
        #expect(SlurmCommands.showJob(jobId: jobId) == c.cmd, "job-detail/\(c.name) command")
    }
}

@Suite("Golden: metric stream")
struct MetricStreamGoldenTests {

    static let cases = Fixtures.cases("metric-stream", as: MetricStreamResult.self)

    @Test("metric-stream parses complete ticks and carries the remainder", arguments: cases)
    func metricStream(c: FixtureCase<MetricStreamResult>) {
        // `now` is pinned so a case that fell back to the current time would be visible; none of
        // the fixtures exercise the fallback (see MetricStreamUnitTests).
        let parsed = MetricStream.parse(buffer: c.input ?? "", now: 0)
        #expect(parsed == c.expected, "metric-stream/\(c.name)")
    }
}

@Suite("Golden: metrics script")
struct MetricsScriptGoldenTests {

    struct Payload: Decodable, Sendable {
        let b64: String
    }

    static let cases = Fixtures.cases("metrics-script", as: Payload.self)

    @Test("METRICS_SCRIPT is byte-identical to the extension's", arguments: cases)
    func payload(c: FixtureCase<Payload>) {
        let b64 = Data(SlurmCommands.metricsScript.utf8).base64EncodedString()
        #expect(b64 == c.expected.b64, "metrics-script/\(c.name) payload")
    }

    @Test("streamJobMetrics command string", arguments: cases)
    func command(c: FixtureCase<Payload>) {
        // The exporter captured this for job 145789 on host "phoenix".
        #expect(SlurmCommands.streamJobMetrics(jobId: "145789") == c.cmd, "metrics-script/\(c.name) command")
    }
}
