import Foundation

/// Live per-job utilization sampling. Port of `src/lib/metrics.ts`.
///
/// The persistent `srun --overlap` step (`SlurmCommands.streamJobMetrics`) emits one tick per
/// second in this line-oriented format:
///
/// ```
/// T <epochMillis>
/// G <index>, <name>, <util%>, <memUsedMiB>, <memTotalMiB>   (one per GPU, job-scoped)
/// C <cpu%|-> <memCurrentBytes> <memMaxBytes>                (job cgroup)
/// E
/// ```
///
/// Everything is computed from samples collected since the detail view opened — stock Slurm
/// keeps no per-job time series to backfill from.
public enum MetricStream {

    /// The trailing window (in seconds) shown alongside the run average. It grows from 0 as the
    /// view stays open and is capped here so the figure stabilises.
    public static let maxWindowSeconds: Double = 30

    /// Extract every complete tick from the accumulated stream buffer, returning the parsed
    /// samples and the unconsumed remainder (an incomplete trailing tick).
    ///
    /// Contractual behaviours, all pinned by fixtures except the `T` fallback:
    /// * parsing stops after the **last** `E` line; everything after it is carried in `rest`,
    ///   and with no `E` at all nothing is parsed and the whole buffer is carried;
    /// * a `G` line is dropped unless its index and utilization are finite *and* total memory is
    ///   greater than zero;
    /// * a `C` line's `-` cpu becomes `nil`, as does a `ram` whose cgroup limit is not positive;
    /// * a tick's GPUs are sorted by index.
    ///
    /// - Parameter now: epoch milliseconds used when a tick's `T` line is unparsable or zero.
    ///   Defaulted per call, mirroring the TS `Date.now()` fallback.
    public static func parse(
        buffer: String,
        now: Double = (Date().timeIntervalSince1970 * 1000).rounded(.down)
    ) -> MetricStreamResult {
        let lines = JS.split(buffer, "\n")
        var lastE = -1
        for i in lines.indices where JS.trim(lines[i]) == "E" { lastE = i }
        if lastE < 0 { return MetricStreamResult(samples: [], rest: buffer) }

        let rest = lines[(lastE + 1)...].joined(separator: "\n")
        var samples: [MetricSample] = []
        var cur: MetricSample?

        for raw in lines[0...lastE] {
            let line = JS.trim(raw)
            if line.hasPrefix("T ") {
                let t = JS.number(dropPrefix(line, 2))
                // JS `Number(...) || Date.now()`: a NaN *or a zero* timestamp falls back.
                cur = MetricSample(t: (t.isNaN || t == 0) ? now : t, gpus: [], cpu: nil, ram: nil)
            } else if line.hasPrefix("G "), cur != nil {
                let parts = JS.split(dropPrefix(line, 2), ",")
                let idx = JS.number(parts[at: 0])
                let name = JS.trim(parts[at: 1])
                let util = JS.number(parts[at: 2])
                let used = JS.number(parts[at: 3])
                let total = JS.number(parts[at: 4])
                if idx.isFinite && util.isFinite && total > 0 {
                    cur?.gpus.append(
                        GpuSample(
                            index: JS.int(idx),
                            name: name,
                            util: util,
                            memPct: (used / total) * 100,
                            memTotalMiB: total
                        )
                    )
                }
            } else if line.hasPrefix("C "), cur != nil {
                let parts = JS.splitWhitespaceRuns(dropPrefix(line, 2))
                let cpuS = parts[at: 0]
                let cpu = JS.number(cpuS)
                cur?.cpu = cpuS == "-" ? nil : (cpu.isFinite ? cpu : nil)
                let memc = JS.number(parts[at: 1])
                let memm = JS.number(parts[at: 2])
                cur?.ram = (memm > 0 && memc.isFinite) ? (memc / memm) * 100 : nil
            } else if line == "E", var sample = cur {
                sample.gpus = sample.gpus.stableSorted { $0.index < $1.index }
                samples.append(sample)
                cur = nil
            }
        }
        return MetricStreamResult(samples: samples, rest: rest)
    }

    /// Number of GPUs the job exposes, taken from the most recent sample that reported any.
    public static func gpuCount(_ samples: [MetricSample]) -> Int {
        for s in samples.reversed() where !s.gpus.isEmpty { return s.gpus.count }
        return 0
    }

    /// Most recent sample for a given GPU index (for its static name / VRAM).
    public static func latestGpu(_ samples: [MetricSample], index: Int) -> GpuSample? {
        for s in samples.reversed() {
            if let g = s.gpus.first(where: { $0.index == index }) { return g }
        }
        return nil
    }

    /// Average of `pick` over samples no older than `sinceMs` (use 0 for "all").
    public static func windowAvg(
        _ samples: [MetricSample],
        sinceMs: Double,
        pick: (MetricSample) -> Double?
    ) -> Double? {
        var sum = 0.0
        var n = 0
        for s in samples {
            if s.t < sinceMs { continue }
            if let v = pick(s), v.isFinite {
                sum += v
                n += 1
            }
        }
        return n != 0 ? sum / Double(n) : nil
    }

    /// Seconds of the trailing window to show: time since the view opened, capped.
    public static func windowSeconds(openedAt: Double, now: Double) -> Double {
        min(maxWindowSeconds, max(0, JS.round((now - openedAt) / 1000)))
    }

    private static func dropPrefix(_ s: String, _ n: Int) -> String {
        String(s.dropFirst(n))
    }
}

/// Running per-series sum/count, accumulated as ticks arrive.
///
/// This is what backs the run average: the retained `[MetricSample]` is capped (memory), so
/// averaging over it would silently turn "run" into a rolling window once the cap is hit.
/// Folding each tick in here instead keeps the run figure exact for the whole session at
/// O(series) memory, independent of how long the view stays open.
public struct RunStats: Equatable, Sendable {
    private var entries: [String: Entry] = [:]

    private struct Entry: Equatable, Sendable {
        var sum: Double
        var n: Int
    }

    public init() {}

    /// Series keys are stable across ticks so a GPU's history survives a tick that happens to
    /// omit it (an `nvidia-smi` hiccup); they never collide with `cpu`/`ram`.
    public enum GpuField: String, Sendable {
        case util
        case memPct
    }

    public static func gpuKey(index: Int, field: GpuField) -> String {
        "gpu:\(index):\(field.rawValue)"
    }

    public static let cpuKey = "cpu"
    public static let ramKey = "ram"

    /// Fold ticks in, returning a new value (callers hold this in state, as the TS returns a new
    /// `Map`).
    public func accumulate(_ samples: [MetricSample]) -> RunStats {
        var next = self
        for s in samples {
            for g in s.gpus {
                next.bump(RunStats.gpuKey(index: g.index, field: .util), g.util)
                next.bump(RunStats.gpuKey(index: g.index, field: .memPct), g.memPct)
            }
            next.bump(RunStats.cpuKey, s.cpu)
            next.bump(RunStats.ramKey, s.ram)
        }
        return next
    }

    /// Session-wide average for one series, or `nil` if it never reported a value.
    public func runAvg(_ key: String) -> Double? {
        guard let e = entries[key], e.n != 0 else { return nil }
        return e.sum / Double(e.n)
    }

    private mutating func bump(_ key: String, _ v: Double?) {
        guard let v, v.isFinite else { return }
        if let e = entries[key] {
            entries[key] = Entry(sum: e.sum + v, n: e.n + 1)
        } else {
            entries[key] = Entry(sum: v, n: 1)
        }
    }
}

extension Array where Element == String {
    /// A missing field reads as `""`, where the TS reads `undefined` and coerces it to `NaN`
    /// rather than to `0`. That difference is unobservable here: the only indices that can be
    /// missing are the ones guarded by `total > 0` / `memm > 0`, which reject `0` and `NaN`
    /// alike. Index 0 always exists — both line kinds are recognised by a two-character prefix
    /// on an already-trimmed line, so there is always at least one field after it.
    fileprivate subscript(at index: Int) -> String {
        index < count ? self[index] : ""
    }
}
