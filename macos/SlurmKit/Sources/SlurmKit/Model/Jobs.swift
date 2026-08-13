import Foundation

// Job-shaped models, ported field-for-field from `src/lib/slurm.ts`. The property names are
// also the `CodingKeys` (synthesized), because the golden fixtures serialize the TypeScript
// values with their exact camelCase names.

/// One row of `squeue`. Mirrors the TS `Job` type (`slurm.ts:86`).
///
/// `user` is only populated by the all-jobs format (`%u`); the per-user list leaves it
/// `undefined` in TS, which the fixture exporter drops from the JSON entirely — so a missing
/// key decodes to `nil` here.
public struct Job: Codable, Equatable, Sendable {
    public var jobId: String
    public var partition: String
    public var name: String
    /// Free-form Slurm state (`RUNNING`, `PENDING`, …). TS widens its union to `string`, and so
    /// do we — clusters invent states.
    public var state: String
    public var elapsed: String
    public var timeLimit: String
    public var nodes: String
    public var cpus: String
    public var reasonOrNodeList: String
    /// AllocTRES when the second `squeue -O` call resolved it, otherwise the `%b` shorthand.
    public var tres: String
    public var user: String?

    public init(
        jobId: String,
        partition: String,
        name: String,
        state: String,
        elapsed: String,
        timeLimit: String,
        nodes: String,
        cpus: String,
        reasonOrNodeList: String,
        tres: String,
        user: String? = nil
    ) {
        self.jobId = jobId
        self.partition = partition
        self.name = name
        self.state = state
        self.elapsed = elapsed
        self.timeLimit = timeLimit
        self.nodes = nodes
        self.cpus = cpus
        self.reasonOrNodeList = reasonOrNodeList
        self.tres = tres
        self.user = user
    }
}

/// `scontrol show job` output: the raw text plus its `Key=Value` tokens (`slurm.ts:117`).
///
/// The golden fixtures omit `raw` (it is byte-identical to the case's `input`), so decoding
/// tolerates a missing `raw` and defaults it to the empty string.
public struct JobDetail: Codable, Equatable, Sendable {
    public var raw: String
    public var fields: [String: String]

    public init(raw: String, fields: [String: String]) {
        self.raw = raw
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
        self.fields = try c.decode([String: String].self, forKey: .fields)
    }
}

/// A pending job competing for a partition (`slurm.ts:219`).
public struct QueueEntry: Codable, Equatable, Sendable {
    public var jobId: String
    public var name: String
    public var user: String
    public var cpus: String
    /// Requested memory as `squeue` prints it (`%m`), e.g. `64G`.
    public var mem: String
    /// Requested wallclock (`%l`), e.g. `1-00:00:00` / `UNLIMITED`.
    public var timeLimit: String
    /// AllocTRES (running) or the `%b` GPU shorthand fallback.
    public var tres: String

    public init(
        jobId: String, name: String, user: String, cpus: String, mem: String, timeLimit: String, tres: String
    ) {
        self.jobId = jobId
        self.name = name
        self.user = user
        self.cpus = cpus
        self.mem = mem
        self.timeLimit = timeLimit
        self.tres = tres
    }
}

/// A running job, i.e. a `QueueEntry` plus its remaining wallclock `%L` (`slurm.ts:230`).
///
/// TS models this as an intersection type; Swift gets a struct with the same JSON shape.
public struct RunningEntry: Codable, Equatable, Sendable {
    public var jobId: String
    public var name: String
    public var user: String
    public var cpus: String
    public var mem: String
    public var timeLimit: String
    public var timeLeft: String
    public var tres: String

    public init(
        jobId: String,
        name: String,
        user: String,
        cpus: String,
        mem: String,
        timeLimit: String,
        timeLeft: String,
        tres: String
    ) {
        self.jobId = jobId
        self.name = name
        self.user = user
        self.cpus = cpus
        self.mem = mem
        self.timeLimit = timeLimit
        self.timeLeft = timeLeft
        self.tres = tres
    }
}

/// Everything competing for one partition, in one round trip (`slurm.ts:232`).
public struct PartitionActivity: Codable, Equatable, Sendable {
    public var pending: [QueueEntry]
    public var running: [RunningEntry]

    public init(pending: [QueueEntry], running: [RunningEntry]) {
        self.pending = pending
        self.running = running
    }
}

/// One RUNNING job holding an allocation on a specific node (`slurm.ts:318`).
///
/// CAVEAT (carried over verbatim from the TS): AllocTRES is job-wide, so for a job spanning
/// several nodes `tres` describes the whole allocation, not this node's share — hence
/// `nodeCount` travels with the row so the UI can flag it.
public struct NodeJob: Codable, Equatable, Sendable {
    public var jobId: String
    public var user: String
    public var name: String
    public var partition: String
    public var elapsed: String
    public var timeLimit: String
    /// `%D` — how many nodes the job holds, this one included.
    public var nodeCount: String
    public var cpus: String
    public var tres: String

    public init(
        jobId: String,
        user: String,
        name: String,
        partition: String,
        elapsed: String,
        timeLimit: String,
        nodeCount: String,
        cpus: String,
        tres: String
    ) {
        self.jobId = jobId
        self.user = user
        self.name = name
        self.partition = partition
        self.elapsed = elapsed
        self.timeLimit = timeLimit
        self.nodeCount = nodeCount
        self.cpus = cpus
        self.tres = tres
    }
}
