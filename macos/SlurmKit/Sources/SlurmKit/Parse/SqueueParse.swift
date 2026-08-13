import Foundation

/// Parsers for `squeue` output, ported from `src/lib/slurm.ts`.
///
/// Every entry point takes the raw stdout of one remote command (see `SlurmCommands`) and
/// returns models. There is no I/O in this package.
public enum SqueueParse {

    // MARK: - The AllocTRES two-call contract

    /// `squeue -O` column layout for the AllocTRES join.
    ///
    /// The format string handed to `squeue` and the slice offsets in `parseAllocTres` MUST stay
    /// in lockstep — the two-call pattern is fragile precisely here — so both derive from these
    /// constants. `tres-alloc` keeps a wide column because AllocTRES grows with every resource
    /// type; ArrayJobID/ArrayTaskID are short (an int, and a task index or a `44-67%2`-style
    /// range).
    public static let allocJobIdWidth = 24
    public static let allocTaskIdWidth = 24
    public static let allocTresFormat =
        "ArrayJobID:\(allocJobIdWidth),ArrayTaskID:\(allocTaskIdWidth),tres-alloc:512"

    /// Sentinel separating the primary `-o` block from the `-O tres-alloc` block.
    public static let allocSentinel = "---ALLOC---"

    /// Split `s` at the first occurrence of `sentinel`. When the sentinel is absent the whole
    /// string is the head and the tail is empty.
    public static func splitOnSentinel(_ s: String, _ sentinel: String) -> (String, String) {
        guard let r = s.range(of: sentinel, options: .literal) else { return (s, "") }
        return (String(s[s.startIndex..<r.lowerBound]), String(s[r.upperBound...]))
    }

    /// Parse the output of `squeue -O <allocTresFormat>` into a map of job id → AllocTRES, keyed
    /// to match the primary `-o %i` column so `allocForJob` can join them.
    ///
    /// We deliberately do NOT key on `-O JobID`: for a RUNNING array task that field prints the
    /// task's underlying JobID (e.g. 6718 for 6644_33), which `%i` never exposes — so a
    /// JobID-keyed map cannot be joined for a running array task at all (its `%b` GPU/mem
    /// shorthand then silently vanishes, especially in the node drill-down whose `-t RUNNING`
    /// alloc call has no pending-array row to fall back on). Instead the `%i` notation is
    /// reconstructed from ArrayJobID + ArrayTaskID:
    /// * numeric ArrayTaskID → running task, key `6644_33`
    /// * `N/A` (non-array)   → key on ArrayJobID alone (== the JobID, e.g. `6690`)
    /// * a range `44-67%2`   → pending array, key on ArrayJobID (`6644`)
    ///
    /// The bare-ArrayJobID key is what `allocForJob`'s suffix-stripped fallback matches for a
    /// pending array range (whose `%i` is `6644_[44-67%2]`).
    public static func parseAllocTres(_ block: String) -> [String: String] {
        var map: [String: String] = [:]
        for rawLine in JS.split(block, "\n") {
            if JS.trim(rawLine).isEmpty { continue }
            // JS slices by UTF-16 code unit; the column widths are byte offsets in `squeue`'s
            // fixed-width output, so the UTF-16 view is the faithful (and for this ASCII wire
            // format, identical) choice.
            let units = Array(rawLine.utf16)
            let arrayJobId = JS.trim(slice(units, 0, allocJobIdWidth))
            let arrayTaskId = JS.trim(slice(units, allocJobIdWidth, allocJobIdWidth + allocTaskIdWidth))
            let tres = JS.trim(slice(units, allocJobIdWidth + allocTaskIdWidth, units.count))
            if arrayJobId.isEmpty { continue }
            let key = numericTaskId.test(arrayTaskId) ? "\(arrayJobId)_\(arrayTaskId)" : arrayJobId
            map[key] = tres
        }
        return map
    }

    /// Resolve a primary-row job id (`%i`) to its AllocTRES entry.
    ///
    /// `parseAllocTres` keys a running array task under its reconstructed `base_task` notation,
    /// so a running task (`5818_27`) lands on the exact lookup. A pending array range's `%i` is
    /// `5818_[28-50%2]`, which never matches directly, so the lookup is retried with the task
    /// suffix stripped to hit the bare-ArrayJobID key (`5818`). Empty entries are ignored
    /// (returns `nil`) so the caller keeps the `%b` shorthand. Non-array ids (no `_`) only ever
    /// hit the exact lookup.
    public static func allocForJob(_ allocByJob: [String: String], _ jobId: String) -> String? {
        if let exact = allocByJob[jobId], !exact.isEmpty { return exact }
        let base = taskSuffix.replaceFirst(in: jobId, with: "")
        if base != jobId, let fallback = allocByJob[base], !fallback.isEmpty { return fallback }
        return nil
    }

    // MARK: - Entry points

    /// Parse the stdout of the per-user job list (primary block + `---ALLOC---` + alloc block).
    public static func jobs(stdout: String) -> [Job] {
        let (primary, allocBlock) = splitOnSentinel(stdout, allocSentinel)
        let allocByJob = parseAllocTres(allocBlock)
        var jobs = rows(primary, jobRow)
        for i in jobs.indices {
            if let a = allocForJob(allocByJob, jobs[i].jobId) { jobs[i].tres = a }
        }
        return jobs
    }

    /// Parse the stdout of the menu bar's lightweight per-user list: one `squeue` call, no
    /// AllocTRES join, so `tres` stays the `%b` GPU shorthand.
    public static func jobsBrief(stdout: String) -> [Job] {
        rows(stdout, jobRow)
    }

    /// Parse the stdout of the cluster-wide job list (adds `%u`).
    public static func allJobs(stdout: String) -> [Job] {
        let (primary, allocBlock) = splitOnSentinel(stdout, allocSentinel)
        let allocByJob = parseAllocTres(allocBlock)
        var jobs = rows(primary, allJobRow)
        for i in jobs.indices {
            if let a = allocForJob(allocByJob, jobs[i].jobId) { jobs[i].tres = a }
        }
        return jobs
    }

    /// Parse the stdout of the per-node RUNNING job list (the Node Utilization drill-down).
    public static func nodeJobs(stdout: String) -> [NodeJob] {
        let (primary, allocBlock) = splitOnSentinel(stdout, allocSentinel)
        return joinAlloc(rows(primary, nodeJobRow), allocBlock)
    }

    /// Parse the stdout of the four-section partition activity command.
    ///
    /// Running jobs are sorted by remaining wallclock so the soonest to free resources comes
    /// first; `UNLIMITED`, empty and unparsable values sink to the end (see `timeLeftSeconds`).
    /// The sort is stable, matching `Array.prototype.sort`, so equal-ranked rows keep `squeue`'s
    /// order — which for the sunk rows is the only ordering there is.
    public static func partitionActivity(stdout: String) -> PartitionActivity {
        let (pendPrimary, afterPendPrimary) = splitOnSentinel(stdout, "---PALLOC---")
        let (pendAlloc, afterPendAlloc) = splitOnSentinel(afterPendPrimary, "---RUN---")
        let (runPrimary, runAlloc) = splitOnSentinel(afterPendAlloc, "---RALLOC---")

        let pending = joinAlloc(rows(pendPrimary, pendingRow), pendAlloc)
        let running = joinAlloc(rows(runPrimary, runningRow), runAlloc)
            .stableSorted { timeLeftSeconds($0.timeLeft) < timeLeftSeconds($1.timeLeft) }
        return PartitionActivity(pending: pending, running: running)
    }

    /// `"1-04:23:11"` / `"23:45:00"` → seconds for sorting; `UNLIMITED`, the empty string and
    /// anything unparsable sink to the end (TS returns `Number.MAX_SAFE_INTEGER`).
    public static func timeLeftSeconds(_ v: String) -> Double {
        if v.isEmpty || v.uppercased() == "UNLIMITED" { return maxSafeInteger }
        return SlurmFormat.parseSlurmDurationSeconds(v) ?? maxSafeInteger
    }

    /// JS `Number.MAX_SAFE_INTEGER`.
    public static let maxSafeInteger: Double = 9_007_199_254_740_991

    // MARK: - Row parsers

    /// `%i|%P|%j|%T|%M|%l|%D|%C|%R|%b`
    public static func jobRow(_ row: String) -> Job {
        let p = JS.split(row, "|")
        return Job(
            jobId: p[at: 0],
            partition: p[at: 1],
            name: p[at: 2],
            state: p[at: 3],
            elapsed: p[at: 4],
            timeLimit: p[at: 5],
            nodes: p[at: 6],
            cpus: p[at: 7],
            reasonOrNodeList: p[at: 8],
            tres: p[at: 9]
        )
    }

    /// `%i|%P|%j|%T|%M|%l|%D|%C|%R|%u|%b` — same as `jobRow` with `%u` inserted before `%b`.
    /// Adding a column changes the indices in both parsers; keep them in sync.
    public static func allJobRow(_ row: String) -> Job {
        let p = JS.split(row, "|")
        return Job(
            jobId: p[at: 0],
            partition: p[at: 1],
            name: p[at: 2],
            state: p[at: 3],
            elapsed: p[at: 4],
            timeLimit: p[at: 5],
            nodes: p[at: 6],
            cpus: p[at: 7],
            reasonOrNodeList: p[at: 8],
            tres: p[at: 10],
            user: p[at: 9]
        )
    }

    /// `%i|%j|%u|%C|%m|%l|%b`
    public static func pendingRow(_ row: String) -> QueueEntry {
        let p = JS.split(row, "|")
        return QueueEntry(
            jobId: p[at: 0],
            name: p[at: 1],
            user: p[at: 2],
            cpus: p[at: 3],
            mem: p[at: 4],
            timeLimit: p[at: 5],
            tres: p[at: 6]
        )
    }

    /// `%i|%j|%u|%C|%m|%l|%L|%b`
    public static func runningRow(_ row: String) -> RunningEntry {
        let p = JS.split(row, "|")
        return RunningEntry(
            jobId: p[at: 0],
            name: p[at: 1],
            user: p[at: 2],
            cpus: p[at: 3],
            mem: p[at: 4],
            timeLimit: p[at: 5],
            timeLeft: p[at: 6],
            tres: p[at: 7]
        )
    }

    /// `%i|%u|%j|%P|%M|%l|%D|%C|%b`
    public static func nodeJobRow(_ row: String) -> NodeJob {
        let p = JS.split(row, "|")
        return NodeJob(
            jobId: p[at: 0],
            user: p[at: 1],
            name: p[at: 2],
            partition: p[at: 3],
            elapsed: p[at: 4],
            timeLimit: p[at: 5],
            nodeCount: p[at: 6],
            cpus: p[at: 7],
            tres: p[at: 8]
        )
    }

    // MARK: - Plumbing

    /// Trim every line, drop the blank ones, parse the rest.
    private static func rows<T>(_ block: String, _ parse: (String) -> T) -> [T] {
        JS.split(block, "\n")
            .map(JS.trim)
            .filter { !$0.isEmpty }
            .map(parse)
    }

    /// Overwrite each entry's `tres` with its AllocTRES where one exists, the same way the job
    /// lists do; entries with no (or an empty) alloc row keep the `%b` shorthand.
    ///
    /// The TS constrains this to `T extends { jobId: string; tres: string }`; `AllocJoinable` is
    /// the same constraint spelled as a protocol.
    static func joinAlloc<T: AllocJoinable>(_ entries: [T], _ allocBlock: String) -> [T] {
        let allocByJob = parseAllocTres(allocBlock)
        var out = entries
        for i in out.indices {
            if let a = allocForJob(allocByJob, out[i].jobId) { out[i].tres = a }
        }
        return out
    }

    private static func slice(_ units: [UInt16], _ from: Int, _ to: Int) -> String {
        let lo = min(max(from, 0), units.count)
        let hi = min(max(to, lo), units.count)
        return String(decoding: units[lo..<hi], as: UTF16.self)
    }
}

/// The TS generic constraint `T extends { jobId: string; tres: string }`, which is what lets one
/// `joinAlloc` serve the job lists, the node drill-down and both partition-activity lists.
protocol AllocJoinable {
    var jobId: String { get }
    var tres: String { get set }
}

extension Job: AllocJoinable {}
extension NodeJob: AllocJoinable {}
extension QueueEntry: AllocJoinable {}
extension RunningEntry: AllocJoinable {}

extension Array where Element == String {
    /// `parts[i] ?? ""` — a `squeue` row with fewer fields than the format string simply leaves
    /// the trailing model fields empty.
    fileprivate subscript(at index: Int) -> String {
        index < count ? self[index] : ""
    }
}

private let numericTaskId = Pattern(#"^\d+\z"#)
// `/_.*$/` — strips a task suffix so a pending array range falls back to its bare ArrayJobID.
private let taskSuffix = Pattern(#"_.*\z"#)
