import Foundation
import Observation
import SlurmKit

/// Live per-job utilization. Port of `LiveUtilization` (`JobDetailView.tsx:175`).
///
/// A persistent `srun --overlap` step streams one tick per second; `SlurmClient.streamJobMetrics`
/// runs the chunks through `MetricStream.parse` with its carried remainder, and this model folds
/// each tick into two accumulators with deliberately different lifetimes:
///
/// * `samples` — capped at 300 (~5 min at 1 Hz). Bounds memory the way TailView's line cap does.
///   Only the trailing window and the "which GPUs exist" lookup read it.
/// * `stats` — an unbounded `RunStats`. The run average must stay exact for the whole session,
///   so it can never be computed from the capped array: past 300 ticks that would silently turn
///   "run" into a 5-minute rolling window.
///
/// Everything is measured since the pane opened. Stock Slurm keeps no per-job time series to
/// backfill from, and `sacct`'s `gres/gpuutil` is a *peak*, not an average — so there is nothing
/// to seed this with.
@Observable
@MainActor
final class MetricsModel {

    /// `MAX_SAMPLES` (`JobDetailView.tsx:173`).
    static let maxSamples = 300

    let host: String
    let jobId: String

    private let transport: any SshTransport
    private var streamTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    private(set) var samples: [MetricSample] = []
    private(set) var stats = RunStats()
    private(set) var errorMessage: String?

    /// When the pane opened, in epoch ms. The trailing window grows from 0 to 30 s from here.
    private(set) var openedAt: Double = Date().timeIntervalSince1970 * 1000
    /// Re-read once a second so the window slides (and grows) live.
    private(set) var now: Double = Date().timeIntervalSince1970 * 1000

    init(host: String, jobId: String, transport: any SshTransport) {
        self.host = host
        self.jobId = jobId
        self.transport = transport
    }

    // MARK: - Derived figures

    /// Seconds of trailing window currently shown: `min(30, time since open)`.
    var windowSeconds: Double { MetricStream.windowSeconds(openedAt: openedAt, now: now) }

    private var windowStart: Double { now - windowSeconds * 1000 }

    /// The GPU set from the most recent tick that reported any — gives index + model + total
    /// VRAM without assuming a contiguous `0..<n` range.
    var gpus: [GpuSample] {
        for sample in samples.reversed() where !sample.gpus.isEmpty { return sample.gpus }
        return []
    }

    /// Session average for a series.
    func runAverage(_ key: String) -> Double? { stats.runAvg(key) }

    /// Trailing-window average for a series.
    func windowAverage(_ pick: (MetricSample) -> Double?) -> Double? {
        MetricStream.windowAvg(samples, sinceMs: windowStart, pick: pick)
    }

    static func gpuValue(_ sample: MetricSample, index: Int, field: RunStats.GpuField) -> Double? {
        guard let gpu = sample.gpus.first(where: { $0.index == index }) else { return nil }
        return field == .util ? gpu.util : gpu.memPct
    }

    /// The chart series for one metric, newest last, as (tick offset, percent) pairs. The x axis
    /// is a plain sample index rather than a timestamp: ticks are 1 Hz by construction and an
    /// index keeps the sparkline stable when the stream stutters.
    func series(_ pick: (MetricSample) -> Double?) -> [(x: Int, y: Double)] {
        samples.enumerated().compactMap { index, sample in
            guard let value = pick(sample), value.isFinite else { return nil }
            return (x: index, y: value)
        }
    }

    // MARK: - Lifecycle

    /// Attach to the job's metric stream. Safe to call repeatedly; only the first call starts it.
    func start() {
        guard streamTask == nil else { return }
        openedAt = Date().timeIntervalSince1970 * 1000
        now = openedAt

        let client = SlurmClient(host: host, transport: transport)
        let jobId = self.jobId
        streamTask = Task { @MainActor in
            do {
                for try await sample in client.streamJobMetrics(jobId: jobId) {
                    self.append(sample)
                }
            } catch is CancellationError {
                // Expected: the pane, the screen or the popover closed.
            } catch {
                self.errorMessage = classifySshError(error, host: self.host).message
            }
        }

        clockTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.now = Date().timeIntervalSince1970 * 1000
            }
        }
    }

    /// Kill the child process and the clock. Called when the pane, the screen or the popover
    /// goes away — a leaked `srun --overlap` step holds a slot on the cluster.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        clockTask?.cancel()
        clockTask = nil
    }

    private func append(_ sample: MetricSample) {
        // Fold into the unbounded accumulator *before* the cap, so the run average sees every
        // tick even after the retained array starts dropping the oldest.
        stats = stats.accumulate([sample])
        samples.append(sample)
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        now = Date().timeIntervalSince1970 * 1000
    }

    /// Snapshot-mode helper: block until at least `count` ticks have landed (or the deadline
    /// passes), so the charts have something to draw when `ImageRenderer` takes its single pass.
    func awaitSamples(_ count: Int, timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while samples.count < count, ContinuousClock.now < deadline, errorMessage == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // No `deinit` teardown: `@Observable` turns these into isolated computed properties, which a
    // `deinit` cannot touch under Swift 6 isolation. `stop()` is called explicitly from every
    // path that can end the stream — pane, screen and popover — which is the contract anyway
    // (SPEC-P3 §8), since a leaked `srun --overlap` step holds a cluster slot.
}
