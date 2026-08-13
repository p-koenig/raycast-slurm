import Foundation

// Live per-job utilization samples, ported from `src/lib/metrics.ts`.

/// One GPU inside one tick (`metrics.ts:15`).
///
/// `index` is `Int` although the TS holds a JS `number`: the producing line is
/// `nvidia-smi --query-gpu=index,…`, whose index column is integral by construction, and the
/// parser already drops the row when the value is not finite.
public struct GpuSample: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    /// Utilization percent as reported by `nvidia-smi`.
    public var util: Double
    /// `memUsed / memTotal * 100`.
    public var memPct: Double
    /// Total device memory in MiB. Integral off the wire but kept as `Double` because the TS
    /// carries it through `Number` and divides by it.
    public var memTotalMiB: Double

    public init(index: Int, name: String, util: Double, memPct: Double, memTotalMiB: Double) {
        self.index = index
        self.name = name
        self.util = util
        self.memPct = memPct
        self.memTotalMiB = memTotalMiB
    }
}

/// One complete tick of the metrics streamer (`metrics.ts:17`).
public struct MetricSample: Codable, Equatable, Sendable {
    /// Epoch milliseconds, from the tick's `T` line.
    public var t: Double
    public var gpus: [GpuSample]
    /// Percent of the allocated CPUs; `nil` when the collector printed `-` (first tick) or a
    /// non-finite value.
    public var cpu: Double?
    /// Percent of the allocated memory; `nil` when the cgroup limit is unreadable or zero.
    public var ram: Double?

    public init(t: Double, gpus: [GpuSample], cpu: Double?, ram: Double?) {
        self.t = t
        self.gpus = gpus
        self.cpu = cpu
        self.ram = ram
    }
}

/// Result of one `MetricStream.parse` pass: every complete tick found, plus the unconsumed
/// trailing bytes the caller must carry into the next read.
///
/// The TS returns an object literal `{ samples, rest }`; the fixtures serialize exactly that,
/// so this named struct decodes them directly (a Swift tuple could not be `Decodable`).
public struct MetricStreamResult: Codable, Equatable, Sendable {
    public var samples: [MetricSample]
    public var rest: String

    public init(samples: [MetricSample], rest: String) {
        self.samples = samples
        self.rest = rest
    }
}
