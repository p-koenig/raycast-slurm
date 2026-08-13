import Foundation
import SlurmKit

/// Demo mode's data source.
///
/// The golden fixtures under `<repo>/fixtures` are bundled into the app (see the folder
/// reference in `macos/project.yml`), and every case that was captured through a real lib call
/// records `(host, cmd, input)` — which *is* a demo response map. Feeding `DemoTransport` from
/// it means the demo flows through the real command builders and the real parsers, exactly like
/// the extension's demo mode: wire-format drift shows up as a missing entry, never as stale
/// output that quietly disagrees with the parser.
enum DemoFixtures {

    /// Fixture kinds whose cases carry a host and a command. `format-scalars` and
    /// `metric-stream` are pure-function vectors with no remote call behind them.
    static let commandKinds = ["jobs-user", "jobs-all", "node-jobs", "partition-activity", "nodes", "job-detail"]

    /// The tail length the log panes request (`LOG_TAIL_LINES`, `JobDetailView.tsx:347`).
    static let logTailLines = 500

    struct Loaded {
        var entries: [DemoTransport.Entry]
        /// Every job the demo knows about, per host, keyed by `%i` job id. Used to synthesise
        /// metric ticks that match the job's actual GPU allocation.
        var jobs: [String: [String: Job]]
    }

    /// Read the bundled fixtures. A missing bundle resource is not fatal: demo mode then serves
    /// only the synthetic entries and every real query surfaces as a normal per-cluster error
    /// row, which is a far better failure mode than a crash on launch.
    static func load(bundle: Bundle = .main) -> Loaded {
        var entries: [DemoTransport.Entry] = []
        var jobs: [String: [String: Job]] = [:]
        var detailFields: [(host: String, fields: [String: String])] = []

        for kind in commandKinds {
            for record in records(kind: kind, bundle: bundle) {
                guard let host = record.host, let command = record.cmd else { continue }
                let input = record.input ?? ""
                entries.append(DemoTransport.Entry(host: host, command: command, output: input))

                // Index the job lists so the metrics synthesiser can look a job's TRES up, and
                // the job details so the log panes have their StdOut/StdErr paths.
                if kind == "jobs-user" || kind == "jobs-all" {
                    for job in SqueueParse.jobs(stdout: input) {
                        jobs[host, default: [:]][job.jobId] = job
                    }
                } else if kind == "job-detail" {
                    detailFields.append((host: host, fields: ScontrolParse.jobDetail(stdout: input).fields))
                }
            }
        }

        entries += identityEntries()
        entries += logEntries(details: detailFields)
        return Loaded(entries: entries, jobs: jobs)
    }

    /// `whoami` per demo host. No fixture pins it — there is no parser to pin — but every view
    /// gates on a detected user, so the demo has to answer it.
    private static func identityEntries() -> [DemoTransport.Entry] {
        Demo.hosts.map { DemoTransport.Entry(host: $0.name, command: "whoami", output: "\(Demo.user)\n") }
    }

    /// Log tails for the jobs that have a `scontrol` fixture, keyed on the exact `readLogTail`
    /// command so a drifting builder shows up as a miss.
    private static func logEntries(details: [(host: String, fields: [String: String])]) -> [DemoTransport.Entry] {
        var entries: [DemoTransport.Entry] = []
        for detail in details {
            let fields = detail.fields
            guard let jobId = fields["JobId"], let name = fields["JobName"] else { continue }
            for (key, isError) in [("StdOut", false), ("StdErr", true)] {
                let path = JobTime.firstMeaningfulTres(fields[key])
                guard !path.isEmpty else { continue }
                entries.append(
                    DemoTransport.Entry(
                        host: detail.host,
                        command: SlurmClient.readLogTailCommand(path: path, lines: logTailLines),
                        output: isError
                            ? errorLog(jobId: jobId)
                            : outputLog(jobId: jobId, name: name, host: detail.host)
                    )
                )
            }
        }
        return entries
    }

    private static func outputLog(jobId: String, name: String, host: String) -> String {
        """
        === \(name) (job \(jobId)) on \(host) ===
        Loading dataset shards from /scratch/\(Demo.user)/\(name)/data ... done (1024 shards)
        Initializing model ... done
        Starting training from checkpoint step 42000
        step 42010 | loss 2.4137 | lr 3.0e-4 | 1.42 it/s
        step 42020 | loss 2.4051 | lr 3.0e-4 | 1.45 it/s
        step 42030 | loss 2.3988 | lr 3.0e-4 | 1.44 it/s
        step 42040 | loss 2.3902 | lr 3.0e-4 | 1.45 it/s
        [eval] step 42040 | val_loss 2.4310 | val_ppl 11.37
        saved checkpoint to checkpoints/step_42040.pt
        step 42050 | loss 2.3877 | lr 3.0e-4 | 1.43 it/s
        step 42060 | loss 2.3815 | lr 3.0e-4 | 1.44 it/s

        """
    }

    private static func errorLog(jobId: String) -> String {
        """
        [\(jobId)] WARNING: torch.distributed run with OMP_NUM_THREADS=1 — set it explicitly for best performance.
        FutureWarning: `torch.cuda.amp.autocast(...)` is deprecated, use `torch.amp.autocast('cuda', ...)` instead.
        UserWarning: Detected call of `lr_scheduler.step()` before `optimizer.step()`.

        """
    }

    // MARK: - Fixture decoding

    private struct Record: Decodable {
        var host: String?
        var cmd: String?
        var input: String?
    }

    private struct File: Decodable {
        var cases: [Record]
    }

    private static func records(kind: String, bundle: Bundle) -> [Record] {
        guard let url = bundle.url(forResource: kind, withExtension: "json", subdirectory: "fixtures"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.cases
    }
}

/// The transport demo mode actually installs.
///
/// It composes `DemoTransport` (the fixture lookup) with the three things a *plausible* demo
/// needs and a fixture map cannot provide, per SPEC-P3 §13:
///
/// 1. **Latency.** ~220 ms per call, so loading states, the search field and the poll cadence
///    behave the way they do against a real login node instead of resolving instantly.
/// 2. **A miss policy.** A command the fixtures do not cover, but which one of our own builders
///    plainly produced (`squeue`/`scontrol`/`whoami`/`scancel`), answers with empty output — the
///    same thing a cluster returns for a query that matches nothing. Anything else throws
///    `remote-cmd`, so a genuinely wrong command is loud.
/// 3. **Live metrics.** There is no `srun` to attach to, so ticks are synthesised at 1 Hz in the
///    collector's own wire format and pushed through the **real** `MetricStream.parse` — the
///    parser is never bypassed.
final class DemoAppTransport: SshTransport {

    /// `DEMO_DELAY_MS` in `src/lib/demo.ts`.
    static let latency: Duration = .milliseconds(220)

    private let inner: DemoTransport
    private let known: [String: Set<String>]
    private let jobs: [String: [String: Job]]

    init(loaded: DemoFixtures.Loaded) {
        self.inner = DemoTransport(entries: loaded.entries)
        var known: [String: Set<String>] = [:]
        for entry in loaded.entries { known[entry.host, default: []].insert(entry.command) }
        self.known = known
        self.jobs = loaded.jobs
    }

    func run(host: String, command: String, timeout: Duration) async throws -> String {
        try? await Task.sleep(for: Self.latency)
        if known[host]?.contains(command) == true {
            return try await inner.run(host: host, command: command, timeout: timeout)
        }
        if Self.looksLikeOurBuilder(command) { return "" }
        throw SshError(
            SshErrorInfo(
                kind: .remoteCmd,
                host: host,
                title: "\(host): command failed",
                message: "Demo mode has no answer for this command.",
                hint: "Only commands built by SlurmKit are simulated.",
                raw: command
            )
        )
    }

    func spawnStream(host: String, command: String) -> AsyncThrowingStream<String, any Error> {
        guard let jobId = Self.streamedJobId(command) else {
            return inner.spawnStream(host: host, command: command)
        }
        let job = jobs[host]?[jobId]
        return AsyncThrowingStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    continuation.yield(Self.tickText(job: job, tick: tick))
                    tick += 1
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Synthetic metric ticks

    /// `GPU_SPECS` (`demo.ts:1280`) — the device names `nvidia-smi` actually prints.
    private static let gpuSpecs: [String: (name: String, totalMiB: Double)] = [
        "h100": ("NVIDIA H100 80GB HBM3", 81_559),
        "a100": ("NVIDIA A100-SXM4-80GB", 81_920),
        "l40s": ("NVIDIA L40S", 46_068),
    ]

    /// `GPU_UTIL` / `GPU_MEM_PCT` — fixed per-index figures so the pane shows a believable mixed
    /// picture. The extension stops there because it renders numbers; we also draw a chart, so a
    /// small deterministic wobble is layered on top — a dead-flat sparkline reads as "broken",
    /// not as "steady". Run/window averages still land on the base figures.
    private static let gpuUtil: [Double] = [94, 88, 97, 91, 86, 96, 90, 93]
    private static let gpuMemPct: [Double] = [78, 71, 84, 69, 75, 81, 66, 73]

    private static func wobble(_ base: Double, tick: Int, seed: Int) -> Double {
        let phase = Double((tick &* 7 &+ seed &* 13) % 12) / 12 * 2 * .pi
        return min(100, max(0, base + sin(phase) * 4))
    }

    /// One tick in the collector's line format (`METRICS_SCRIPT`), so it parses through
    /// `MetricStream.parse` with no special-casing.
    private static func tickText(job: Job?, tick: Int) -> String {
        let now = Int((Date().timeIntervalSince1970 * 1000).rounded(.down))
        var lines = ["T \(now)"]

        let info = job.flatMap { SlurmFormat.gpuInfoFromTres($0.tres) }
        let count = info?.count ?? 0
        let type = info?.type ?? ""
        let spec = gpuSpecs[type] ?? (name: type.isEmpty ? "GPU" : type.uppercased(), totalMiB: 81_920)
        for index in 0..<count {
            let util = wobble(gpuUtil[index % gpuUtil.count], tick: tick, seed: index)
            let memPct = wobble(gpuMemPct[index % gpuMemPct.count], tick: tick, seed: index + 5)
            let used = (memPct / 100 * spec.totalMiB).rounded()
            lines.append("G \(index), \(spec.name), \(Int(util.rounded())), \(Int(used)), \(Int(spec.totalMiB))")
        }

        // CPU-only jobs run hotter on CPU; GPU jobs are mostly dataloader-bound (demo.ts:1306).
        let cpu = wobble(count > 0 ? 62 : 87, tick: tick, seed: 3)
        let ram = wobble(54, tick: tick, seed: 9)
        // The `C` line is `cpu% memCurrentBytes memMaxBytes`; RAM percent is the ratio.
        lines.append("C \(String(format: "%.1f", cpu)) \(Int(ram * 1_000_000)) \(100_000_000)")
        lines.append("E")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Command shapes

    private static func streamedJobId(_ command: String) -> String? {
        guard command.hasPrefix("srun --jobid=") else { return nil }
        let rest = command.dropFirst("srun --jobid=".count)
        guard let end = rest.firstIndex(of: " ") else { return nil }
        return String(rest[rest.startIndex..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    private static func looksLikeOurBuilder(_ command: String) -> Bool {
        ["squeue", "scontrol", "scancel", "whoami", "srun"].contains { command.hasPrefix($0) }
    }
}

/// The master-connection lifecycle, as the cluster picker needs it.
///
/// A struct of closures rather than a protocol because the two implementations are "call
/// `OpenSshTransport`" and "pretend" — and the pretending one has to be reachable from the
/// snapshot runner, where spawning `ssh` is forbidden outright.
struct ConnectionControl: Sendable {
    var isMasterUp: @Sendable (String) async -> Bool
    var openMaster: @Sendable (String) async throws -> Void
    var closeMaster: @Sendable (String) async -> Void
    var interactiveCommand: @Sendable (String) -> String

    static func real(_ transport: OpenSshTransport) -> ConnectionControl {
        ConnectionControl(
            isMasterUp: { await transport.isMasterUp(host: $0) },
            openMaster: { try await transport.openMaster(host: $0) },
            closeMaster: { await transport.closeMaster(host: $0) },
            interactiveCommand: { transport.interactiveOpenMasterCmd(host: $0) }
        )
    }

    /// Demo mode: `isMasterUp` is always true, master and terminal operations are no-ops
    /// (UI-INVENTORY §12, "Demo mode").
    static let demo = ConnectionControl(
        isMasterUp: { _ in true },
        openMaster: { _ in },
        closeMaster: { _ in },
        interactiveCommand: { "echo 'demo mode — no connection is opened for \($0)'" }
    )
}
