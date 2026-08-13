import Foundation

/// One node from `scontrol show node --oneliner`. Mirrors the TS `SlurmNode` (`slurm.ts:100`).
///
/// Numeric typing follows what the TS can actually produce on Slurm output: `cpuLoad` is a
/// fractional load average (and `null` when Slurm prints `N/A`), everything else is an integral
/// count or a whole number of MiB.
public struct SlurmNode: Codable, Equatable, Sendable {
    public var name: String
    public var state: String
    public var partitions: [String]
    /// `CPULoad`; `nil` for `N/A`, an absent field, or an unparsable value (the TS yields `NaN`
    /// there, which `JSON.stringify` writes as `null` — the fixtures record `null`).
    public var cpuLoad: Double?
    public var cpuTot: Int
    public var cpuAlloc: Int
    public var realMemoryMB: Int
    public var freeMemoryMB: Int
    public var allocMemoryMB: Int
    public var gres: String
    public var gresUsed: String
    public var allocTres: String
    public var features: String
    public var reason: String

    public init(
        name: String,
        state: String,
        partitions: [String],
        cpuLoad: Double?,
        cpuTot: Int,
        cpuAlloc: Int,
        realMemoryMB: Int,
        freeMemoryMB: Int,
        allocMemoryMB: Int,
        gres: String,
        gresUsed: String,
        allocTres: String,
        features: String,
        reason: String
    ) {
        self.name = name
        self.state = state
        self.partitions = partitions
        self.cpuLoad = cpuLoad
        self.cpuTot = cpuTot
        self.cpuAlloc = cpuAlloc
        self.realMemoryMB = realMemoryMB
        self.freeMemoryMB = freeMemoryMB
        self.allocMemoryMB = allocMemoryMB
        self.gres = gres
        self.gresUsed = gresUsed
        self.allocTres = allocTres
        self.features = features
        self.reason = reason
    }
}

/// Count + raw gres type token for a job's allocated GPUs, e.g.
/// `cpu=64,gres/gpu:rtx_pro_6000=4` → `GpuInfo(count: 4, type: "rtx_pro_6000")`.
///
/// `type` is the lowercase Slurm token (feed it to `SlurmFormat.prettifyGpuModel` for display);
/// it is `nil` for the generic `gres/gpu=N` form. Mirrors the TS object literal returned by
/// `gpuInfoFromTres` (`format.ts:330`), so it decodes straight from the fixtures.
public struct GpuInfo: Codable, Equatable, Sendable {
    public var count: Int
    public var type: String?

    public init(count: Int, type: String?) {
        self.count = count
        self.type = type
    }
}

/// Semantic job-state buckets — the SlurmKit-side replacement for the TS `stateColor`
/// (`format.ts:19`), whose `Color` import is the one UI leak that is deliberately not ported.
/// The App layer maps a category to a SwiftUI `Color`; the buckets themselves are exactly the
/// keys of `STATE_COLORS` plus a fallback.
public enum JobStateCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case running = "RUNNING"
    case pending = "PENDING"
    case completing = "COMPLETING"
    case completed = "COMPLETED"
    case cancelled = "CANCELLED"
    case failed = "FAILED"
    case timeout = "TIMEOUT"
    case preempted = "PREEMPTED"
    case suspended = "SUSPENDED"
    case configuring = "CONFIGURING"
    /// Anything not in `STATE_COLORS` — the TS renders this as secondary text.
    case other
}

/// Semantic node-state buckets, replacing the TS `nodeStateColor` (`format.ts:373`). The cases
/// are listed in the substring-match order the TS uses; `SlurmFormat.nodeStateCategory` honours
/// that order because a node state such as `MIXED+DRAIN` matches more than one bucket.
public enum NodeStateCategory: String, Codable, Equatable, Sendable, CaseIterable {
    /// `down` / `drain` / `fail` — the TS colours these red.
    case unavailable
    case allocated
    case mixed
    case idle
    /// `reserved` / `maint`.
    case reserved
    case other
}
