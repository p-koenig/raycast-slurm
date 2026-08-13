import Foundation

/// One cluster, viewed as Slurm. The per-host façade over `SlurmCommands` (command construction),
/// an `SshTransport` (bytes) and `Parse` (models) — i.e. the second half of every
/// `src/lib/slurm.ts` entry point, the half that is not the command string.
///
/// It is a value type over a transport reference, so a view model can hold one per active cluster
/// and they all share the same multiplexed connections.
public struct SlurmClient: Sendable {

    public let host: String
    public let transport: any SshTransport

    public init(host: String, transport: any SshTransport) {
        self.host = host
        self.transport = transport
    }

    // MARK: - Identity

    /// `whoami`, trimmed. Gets its own 10 s deadline in the TS, kept here.
    public func detectUser() async throws -> String {
        JS.trim(try await transport.run(host: host, command: SlurmCommands.detectUser(), timeout: .seconds(10)))
    }

    // MARK: - Jobs

    public func listJobs(user: String) async throws -> [Job] {
        SqueueParse.jobs(stdout: try await transport.run(host: host, command: SlurmCommands.listJobs(user: user)))
    }

    /// The menu bar's cheap tick: one `squeue`, no AllocTRES join, `tres` stays the `%b` shorthand.
    public func listJobsBrief(user: String) async throws -> [Job] {
        SqueueParse.jobsBrief(
            stdout: try await transport.run(host: host, command: SlurmCommands.listJobsBrief(user: user))
        )
    }

    public func listAllJobs() async throws -> [Job] {
        SqueueParse.allJobs(stdout: try await transport.run(host: host, command: SlurmCommands.listAllJobs()))
    }

    public func listPartitionActivity(partition: String) async throws -> PartitionActivity {
        SqueueParse.partitionActivity(
            stdout: try await transport.run(host: host, command: SlurmCommands.listPartitionActivity(partition: partition))
        )
    }

    public func listNodeJobs(node: String) async throws -> [NodeJob] {
        SqueueParse.nodeJobs(stdout: try await transport.run(host: host, command: SlurmCommands.listNodeJobs(node: node)))
    }

    /// `scontrol show job`. The returned `raw` is the untouched stdout — the detail view shows it
    /// verbatim when a field is missing.
    public func showJob(jobId: String) async throws -> JobDetail {
        ScontrolParse.jobDetail(stdout: try await transport.run(host: host, command: SlurmCommands.showJob(jobId: jobId)))
    }

    public func cancelJob(jobId: String) async throws {
        _ = try await transport.run(host: host, command: SlurmCommands.cancelJob(jobId: jobId))
    }

    // MARK: - Nodes

    public func listNodes() async throws -> [SlurmNode] {
        ScontrolParse.nodes(stdout: try await transport.run(host: host, command: SlurmCommands.listNodes()))
    }

    // MARK: - Log tail

    /// `tail -c` caps the bytes pulled over the wire (a CR-redraw progress bar can make a single
    /// "line" enormous — see the tailview-cr-buffer-leak note), `tr` flattens the CR redraws to
    /// newlines, and `tail -n` keeps the last `lines`. We never read a whole ML log; they are
    /// routinely gigabytes.
    public static let logTailBytes = 128 * 1024

    /// The command is built here rather than in `SlurmCommands` because that file is P1b's and the
    /// log tail has no fixture; the string is byte-identical to `readLogTail` (`slurm.ts:475`).
    public static func readLogTailCommand(path: String, lines: Int) -> String {
        let n = max(1, lines)
        return "tail -c \(logTailBytes) -- \(shellQuote(path)) | tr '\\r' '\\n' | tail -n \(n)"
    }

    /// One-shot read of the bottom of a log file. The UI lands in v1.1; the client method is here
    /// so the command never has to be re-derived.
    public func readLogTail(path: String, lines: Int) async throws -> String {
        try await transport.run(host: host, command: Self.readLogTailCommand(path: path, lines: lines))
    }

    // MARK: - Live metrics

    /// Cap on the carried stream remainder. `MetricStream.parse` hands back everything after the
    /// last `E`, which stays tiny for a well-behaved collector — but a wedged remote (or a
    /// progress bar leaking into the step's stdout) must not be able to grow it without bound.
    public static let maxMetricBufferBytes = 1 << 20

    /// Follow a RUNNING job's live GPU/CPU/RAM samples.
    ///
    /// The remote side is the base64-shipped `METRICS_SCRIPT` (`SlurmCommands.streamJobMetrics`,
    /// pinned byte-for-byte by the `metrics-script` fixture). Chunks are accumulated and drained
    /// through `MetricStream.parse` with its carried remainder; ending iteration kills the step.
    public func streamJobMetrics(jobId: String) -> AsyncThrowingStream<MetricSample, any Error> {
        let chunks = transport.spawnStream(host: host, command: SlurmCommands.streamJobMetrics(jobId: jobId))
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                do {
                    for try await chunk in chunks {
                        buffer += chunk
                        if buffer.utf8.count > Self.maxMetricBufferBytes {
                            buffer = String(buffer.suffix(Self.maxMetricBufferBytes / 2))
                        }
                        let result = MetricStream.parse(buffer: buffer)
                        for sample in result.samples { continuation.yield(sample) }
                        buffer = result.rest
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
