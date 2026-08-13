import Foundation
import Testing

@testable import SlurmKit

// The transport → parse loop, closed on golden data: every client method is driven through a
// `DemoTransport` loaded from the fixtures, so a case passes only if the *command the client built*
// matched the command the TypeScript issued (otherwise there is no fixture to answer with) and the
// models it parsed equal the models the TypeScript produced.

@Suite("SlurmClient: jobs")
struct SlurmClientJobTests {

    static let userCases = Fixtures.cases("jobs-user", as: [Job].self)
    static let allCases = Fixtures.cases("jobs-all", as: [Job].self)

    @Test("listJobs / listJobsBrief over the fixtures", arguments: userCases)
    func jobs(c: FixtureCase<[Job]>) async throws {
        let host = try #require(c.host)
        let (client, transport) = DemoFixtures.client(host: host)

        let jobs =
            c.name.hasSuffix("-brief")
            ? try await client.listJobsBrief(user: Demo.user)
            : try await client.listJobs(user: Demo.user)

        #expect(jobs == c.expected, "jobs-user/\(c.name)")
        let calls = await transport.recordedCalls()
        #expect(calls.map(\.command) == [c.cmd])
        #expect(calls.map(\.host) == [host])
    }

    @Test("listAllJobs over the fixtures", arguments: allCases)
    func allJobs(c: FixtureCase<[Job]>) async throws {
        let host = try #require(c.host)
        let (client, transport) = DemoFixtures.client(host: host)

        #expect(try await client.listAllJobs() == c.expected, "jobs-all/\(c.name)")
        #expect(await transport.recordedCalls().map(\.command) == [c.cmd])
    }

    @Test("detectUser trims whoami")
    func detectUser() async throws {
        let (client, transport) = DemoFixtures.client(host: "phoenix")
        #expect(try await client.detectUser() == "r.shaw")
        #expect(await transport.recordedCalls().map(\.command) == ["whoami"])
    }

    @Test("cancelJob shell-quotes the id and discards the output")
    func cancelJob() async throws {
        let (client, transport) = DemoFixtures.client(host: "phoenix")
        try await client.cancelJob(jobId: "145789")
        #expect(await transport.recordedCalls().map(\.command) == ["scancel 145789"])
    }
}

@Suite("SlurmClient: nodes and partitions")
struct SlurmClientNodeTests {

    static let nodeJobCases = Fixtures.cases("node-jobs", as: [NodeJob].self)
    static let partitionCases = Fixtures.cases("partition-activity", as: PartitionActivity.self)
    static let nodeCases = Fixtures.cases("nodes", as: [SlurmNode].self)

    @Test("listNodeJobs over the fixtures", arguments: nodeJobCases)
    func nodeJobs(c: FixtureCase<[NodeJob]>) async throws {
        let host = try #require(c.host)
        // The exporter names each case "<host>-<node>-<description>".
        let node = String(c.name.split(separator: "-")[1])
        let (client, transport) = DemoFixtures.client(host: host)

        #expect(try await client.listNodeJobs(node: node) == c.expected, "node-jobs/\(c.name)")
        #expect(await transport.recordedCalls().map(\.command) == [c.cmd])
    }

    @Test("listPartitionActivity over the fixtures", arguments: partitionCases)
    func partitionActivity(c: FixtureCase<PartitionActivity>) async throws {
        let host = try #require(c.host)
        // Recovered from the captured command, because one case deliberately uses the empty
        // partition (shellQuote("") -> '').
        let partition = Self.partitionArgument(from: c.cmd ?? "")
        let (client, transport) = DemoFixtures.client(host: host)

        #expect(try await client.listPartitionActivity(partition: partition) == c.expected, "partition-activity/\(c.name)")
        #expect(await transport.recordedCalls().map(\.command) == [c.cmd])
    }

    @Test("listNodes over the fixtures", arguments: nodeCases)
    func nodes(c: FixtureCase<[SlurmNode]>) async throws {
        let host = try #require(c.host)
        let (client, transport) = DemoFixtures.client(host: host)

        #expect(try await client.listNodes() == c.expected, "nodes/\(c.name)")
        #expect(await transport.recordedCalls().map(\.command) == ["scontrol show node --oneliner"])
    }

    /// Pull the value of the first `-p <value>` out of a captured command, undoing shellQuote.
    static func partitionArgument(from cmd: String) -> String {
        guard let range = cmd.range(of: " -p ") else { return "" }
        let rest = cmd[range.upperBound...]
        if rest.first == "'" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return "" }
            return String(body[body.startIndex..<end]).replacingOccurrences(of: #"'\''"#, with: "'")
        }
        return String(rest.prefix(while: { $0 != " " }))
    }
}

@Suite("SlurmClient: job detail, log tail and metrics")
struct SlurmClientDetailTests {

    static let detailCases = Fixtures.cases("job-detail", as: JobDetail.self)

    /// The `squeue`-shaped id the exporter asked `showJob` for. It cannot be recovered from the
    /// fixture: `scontrol` answers a pending array range with the base id, which is exactly the
    /// normalisation `ScontrolParse.jobId` performs. Mirrors `detailTargets` in the exporter.
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

    @Test("showJob over the fixtures, including the array-id normalisation", arguments: detailCases)
    func showJob(c: FixtureCase<JobDetail>) async throws {
        let host = try #require(c.host)
        let jobId = try #require(Self.queriedJobIds[c.name])
        let (client, transport) = DemoFixtures.client(host: host)

        let detail = try await client.showJob(jobId: jobId)
        #expect(detail.fields == c.expected.fields, "job-detail/\(c.name)")
        #expect(detail.raw == c.input, "job-detail/\(c.name) raw is the untouched stdout")
        #expect(await transport.recordedCalls().map(\.command) == [c.cmd])
    }

    @Test("readLogTail builds the double-bounded pipeline from slurm.ts")
    func readLogTailCommand() async throws {
        // `tail -c` caps the bytes on the wire, `tr` flattens CR redraws, `tail -n` keeps the last
        // n lines. Byte-identical to `readLogTail` (slurm.ts:475).
        #expect(
            SlurmClient.readLogTailCommand(path: "/scratch/r.shaw/slurm-145789.out", lines: 200)
                == "tail -c 131072 -- /scratch/r.shaw/slurm-145789.out | tr '\\r' '\\n' | tail -n 200"
        )
        // A path needing quoting goes through shellQuote, and `lines` is floored at 1.
        #expect(
            SlurmClient.readLogTailCommand(path: "/scratch/my logs/out.log", lines: 0)
                == "tail -c 131072 -- '/scratch/my logs/out.log' | tr '\\r' '\\n' | tail -n 1"
        )

        let (client, transport) = DemoFixtures.client(host: "phoenix")
        let tail = try await client.readLogTail(path: "/scratch/r.shaw/slurm-145789.out", lines: 200)
        #expect(tail == "epoch 3/10 loss 0.214\nepoch 4/10 loss 0.198\n")
        #expect(await transport.recordedCalls().count == 1)
    }

    @Test("streamJobMetrics issues the fixture command byte for byte")
    func metricsCommand() async throws {
        let fixture = try #require(Fixtures.rawCases("metrics-script").first?.objectValue)
        let expectedCommand = try #require(fixture["cmd"]?.stringValue)
        let host = try #require(fixture["host"]?.stringValue)

        let (client, transport) = DemoFixtures.client(host: host)
        // The fixture carries no body, so the stream ends immediately; the assertion is on the
        // command, which is what the base64-shipped METRICS_SCRIPT rides in.
        for try await _ in client.streamJobMetrics(jobId: "145789") {}
        #expect(await transport.recordedCalls().map(\.command) == [expectedCommand])
    }

    @Test("streamJobMetrics parses ticks out of the streamed chunks")
    func metricsParsing() async throws {
        let command = SlurmCommands.streamJobMetrics(jobId: "42")
        let body = """
            T 1767225600000
            G 1, NVIDIA A100, 55, 4096, 40960
            G 0, NVIDIA A100, 90, 20480, 40960
            C 42.5 8589934592 17179869184
            E
            T 1767225601000
            C - 8589934592 17179869184
            E
            T 176722560
            """
        let transport = DemoTransport(entries: [.init(host: "phoenix", command: command, output: body)])
        let client = SlurmClient(host: "phoenix", transport: transport)

        var samples: [MetricSample] = []
        for try await sample in client.streamJobMetrics(jobId: "42") { samples.append(sample) }

        #expect(samples.count == 2)
        // GPUs are sorted by index within a tick.
        #expect(samples.first?.gpus.map(\.index) == [0, 1])
        #expect(samples.first?.cpu == 42.5)
        #expect(samples.first?.ram == 50)
        #expect(samples.last?.cpu == nil, "the collector's `-` becomes nil")
        // The trailing partial tick is carried, never emitted.
        #expect(samples.last?.t == 1_767_225_601_000)
    }

    @Test("an unknown command fails like a remote command failure")
    func unknownCommand() async {
        let transport = DemoTransport(responses: ["phoenix": [:]])
        let client = SlurmClient(host: "phoenix", transport: transport)

        do {
            _ = try await client.listNodes()
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .remoteCmd)
            #expect(error.info.host == "phoenix")
            #expect(error.info.raw == "scontrol show node --oneliner")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }
}
