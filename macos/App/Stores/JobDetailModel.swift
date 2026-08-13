import Foundation
import Observation
import SlurmKit

/// One pushed job-detail screen. Port of `JobDetailView.tsx`'s data layer.
///
/// The `scontrol show job` fetch is **one-shot** — it describes a job's configuration, not its
/// progress, and the Schedule pane recomputes elapsed/remaining from a local clock instead. The
/// log panes poll on their own 10 s tick.
@Observable
@MainActor
final class JobDetailModel {

    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case info, schedule, utilization, stdout, stderr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .info: return "Info"
            case .schedule: return "Schedule"
            case .utilization: return "Utilization"
            case .stdout: return "Output"
            case .stderr: return "Error"
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .schedule: return "calendar"
            case .utilization: return "chart.line.uptrend.xyaxis"
            case .stdout: return "text.alignleft"
            case .stderr: return "exclamationmark.triangle"
            }
        }
    }

    let host: String
    let jobId: String
    /// Gates live metrics and log reading. `true` unconditionally from My Jobs; computed from
    /// the row's `%u` in All Jobs and the node drill-down.
    let owned: Bool

    private let transport: any SshTransport

    private(set) var fields: [String: String]?
    private(set) var error: SshErrorInfo?
    private(set) var isLoading = false

    var pane: Pane = .info

    let stdout: LogPaneModel
    let stderr: LogPaneModel

    /// The live metrics stream, created on first use.
    ///
    /// It hangs off this model rather than off the Utilization pane's `@State` so that flipping
    /// between panes does not tear the `srun --overlap` step down and immediately respawn it —
    /// which would also reset the run average the pane exists to show.
    private(set) var metrics: MetricsModel?

    init(host: String, jobId: String, owned: Bool, transport: any SshTransport) {
        self.host = host
        self.jobId = jobId
        self.owned = owned
        self.transport = transport
        self.stdout = LogPaneModel(host: host, stream: .stdout, owned: owned, transport: transport)
        self.stderr = LogPaneModel(host: host, stream: .stderr, owned: owned, transport: transport)
    }

    var state: String { (fields?["JobState"] ?? "").uppercased() }
    var isRunning: Bool { state.hasPrefix("RUNNING") }
    var isPending: Bool { state.hasPrefix("PENDING") }

    /// The TRES resolution rule (`JobDetailView.tsx:95`): a pending job's `AllocTRES` is a
    /// placeholder, so a plain `??`/`||` would never reach `ReqTRES`.
    var tres: String {
        guard let fields else { return "" }
        return JobTime.firstMeaningfulTres(fields["AllocTRES"], fields["ReqTRES"], fields["TRES"])
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await SlurmClient(host: host, transport: transport).showJob(jobId: jobId)
            fields = detail.fields
            error = nil
            stdout.setPath(JobTime.firstMeaningfulTres(detail.fields["StdOut"]))
            stderr.setPath(JobTime.firstMeaningfulTres(detail.fields["StdErr"]))
        } catch {
            self.error = classifySshError(error, host: host)
            // Leave `fields` nil: the panes' first gate is "no fields → loading", and an error
            // row renders above them.
        }
    }

    /// Attach the metrics stream, creating it if needed. Only ever called past the pane's gates,
    /// so a non-running or someone else's job never spawns an `srun`.
    @discardableResult
    func startMetrics() -> MetricsModel {
        let model = metrics ?? MetricsModel(host: host, jobId: jobId, transport: transport)
        metrics = model
        model.start()
        return model
    }

    func stopMetrics() {
        metrics?.stop()
    }
}

/// One log pane (stdout or stderr).
///
/// A one-shot `readLogTail` plus a 10 s poll while it is readable — **not** the live `tail -F`
/// TailView, which is v1.1 and explicitly out of scope (SPEC-P3 §9).
@Observable
@MainActor
final class LogPaneModel {

    enum Stream: String {
        case stdout, stderr

        var label: String { self == .stdout ? "Output (stdout)" : "Error (stderr)" }
        /// The word the "no file is set" copy uses.
        var noun: String { self == .stdout ? "output" : "error" }
    }

    /// `LOG_TAIL_LINES` (`JobDetailView.tsx:347`).
    static let lines = 500

    let host: String
    let stream: Stream
    let owned: Bool

    private let transport: any SshTransport
    private let poll = PollLoop()

    private(set) var path: String = ""
    private(set) var tail: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    init(host: String, stream: Stream, owned: Bool, transport: any SshTransport) {
        self.host = host
        self.stream = stream
        self.owned = owned
        self.transport = transport
    }

    /// Reading a job's log needs the filesystem access its owner has, so this is gated on
    /// ownership as well as on a path being set at all.
    var canRead: Bool { owned && !path.isEmpty }

    func setPath(_ path: String) {
        guard path != self.path else { return }
        self.path = path
        tail = nil
    }

    func refresh() async {
        guard canRead else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let raw = try await SlurmClient(host: host, transport: transport)
                .readLogTail(path: path, lines: Self.lines)
            // Trailing newlines only add blank lines to a monospaced pane.
            var trimmed = Substring(raw)
            while trimmed.last == "\n" { trimmed = trimmed.dropLast() }
            tail = String(trimmed)
            errorMessage = nil
        } catch {
            errorMessage = classifySshError(error, host: host).message
        }
    }

    func startPolling() {
        guard canRead else { return }
        poll.start(seconds: { 10 }) { [weak self] in await self?.refresh() }
    }

    func stopPolling() { poll.stop() }
}

/// One pushed per-node drill-down. Port of `NodeJobsView.tsx`.
///
/// Polls at **10 s**, faster than the parent node list's 30 s: you are watching one node here,
/// so the job cadence is the right one. Errors surface only through the error row — the
/// extension suppresses the default toast for exactly this reason, since a failing poll would
/// otherwise fire one every 10 s.
@Observable
@MainActor
final class NodeJobsModel {

    let host: String
    let node: String

    private let transport: any SshTransport
    private let poll = PollLoop()

    private(set) var jobs: [NodeJob] = []
    private(set) var error: SshErrorInfo?
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    init(host: String, node: String, transport: any SshTransport) {
        self.host = host
        self.node = node
        self.transport = transport
    }

    var userCount: Int { Set(jobs.map(\.user)).count }

    func refresh() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let jobs = try await SlurmClient(host: host, transport: transport).listNodeJobs(node: node)
            self.jobs = Self.sortByFootprint(jobs)
            error = nil
        } catch {
            self.error = classifySshError(error, host: host)
        }
    }

    func startPolling() {
        poll.start(seconds: { 10 }) { [weak self] in await self?.refresh() }
    }

    func stopPolling() { poll.stop() }

    /// Biggest consumer first (`NodeJobsView.tsx:96`): this view exists to explain the node
    /// row's `gpu 6/8` and CPU chips, so the jobs accounting for most of them lead.
    static func sortByFootprint(_ jobs: [NodeJob]) -> [NodeJob] {
        jobs.sorted { a, b in
            let gpu = SlurmFormat.gpuCountFromTres(b.tres) - SlurmFormat.gpuCountFromTres(a.tres)
            if gpu != 0 { return gpu < 0 }
            let cpu = (Int(b.cpus) ?? 0) - (Int(a.cpus) ?? 0)
            if cpu != 0 { return cpu < 0 }
            return a.jobId < b.jobId
        }
    }
}
