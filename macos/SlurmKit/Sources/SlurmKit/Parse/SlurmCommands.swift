import Foundation

/// The exact remote command strings the extension issues, ported from `src/lib/slurm.ts`.
///
/// Command construction is part of the parity contract, not an implementation detail: the
/// golden fixtures capture the string the TypeScript actually sent, and the Swift builders are
/// asserted against it byte for byte. Every user-derived value goes through `shellQuote`.
///
/// The `-o` format strings and the AllocTRES column widths are single-sourced with the parsers
/// (`SqueueParse.allocTresFormat`), because the two-call join breaks silently if they drift.
public enum SlurmCommands {

    /// Primary `squeue -o` format for the per-user and menu bar job lists.
    /// Adding a column changes the indices in `SqueueParse.jobRow` — keep them in sync.
    public static let jobsFormat = "%i|%P|%j|%T|%M|%l|%D|%C|%R|%b"

    /// Primary `squeue -o` format for the cluster-wide list (`%u` before `%b`).
    public static let allJobsFormat = "%i|%P|%j|%T|%M|%l|%D|%C|%R|%u|%b"

    /// Primary `squeue -o` format for the per-node drill-down.
    public static let nodeJobsFormat = "%i|%u|%j|%P|%M|%l|%D|%C|%b"

    /// Primary `squeue -o` format for a partition's pending queue.
    public static let pendingFormat = "%i|%j|%u|%C|%m|%l|%b"

    /// Primary `squeue -o` format for a partition's running jobs (adds `%L`, time left).
    public static let runningFormat = "%i|%j|%u|%C|%m|%l|%L|%b"

    /// `whoami` — used to discover the remote account name.
    public static func detectUser() -> String {
        "whoami"
    }

    /// The per-user job list: primary rows, the `---ALLOC---` sentinel, then the AllocTRES rows.
    public static func listJobs(user: String) -> String {
        "squeue -h -u \(shellQuote(user)) -o \(shellQuote(jobsFormat)); "
            + "echo '\(SqueueParse.allocSentinel)'; "
            + "squeue -h -u \(shellQuote(user)) -O \(shellQuote(SqueueParse.allocTresFormat))"
    }

    /// Lightweight variant for the menu bar's background refresh: skips the second
    /// `squeue -O tres-alloc` call and the join, because the menu bar only renders state counts
    /// and never reads `tres`. Keeping this tick cheap is what lets the background refresh land
    /// the title reliably.
    public static func listJobsBrief(user: String) -> String {
        "squeue -h -u \(shellQuote(user)) -o \(shellQuote(jobsFormat))"
    }

    /// The cluster-wide job list.
    public static func listAllJobs() -> String {
        "squeue -h -o \(shellQuote(allJobsFormat)); "
            + "echo '\(SqueueParse.allocSentinel)'; "
            + "squeue -h -O \(shellQuote(SqueueParse.allocTresFormat))"
    }

    /// Everything RUNNING on a single node. `-w` selects jobs holding an allocation there.
    public static func listNodeJobs(node: String) -> String {
        let w = shellQuote(node)
        return "squeue -h -w \(w) -t RUNNING -o \(shellQuote(nodeJobsFormat)); "
            + "echo '\(SqueueParse.allocSentinel)'; "
            + "squeue -h -w \(w) -t RUNNING -O \(shellQuote(SqueueParse.allocTresFormat))"
    }

    /// Everything competing for `partition`, in one round trip: the pending queue in Slurm's
    /// scheduling order (`--sort=-p,i` — priority desc, then JobID asc, the FIFO tie-break the
    /// scheduler walks) and the running jobs, each with its own AllocTRES block.
    public static func listPartitionActivity(partition: String) -> String {
        let p = shellQuote(partition)
        let alloc = shellQuote(SqueueParse.allocTresFormat)
        return "squeue -h -t PENDING -p \(p) --sort=-p,i -o \(shellQuote(pendingFormat)); echo '---PALLOC---'; "
            + "squeue -h -t PENDING -p \(p) --sort=-p,i -O \(alloc); echo '---RUN---'; "
            + "squeue -h -t RUNNING -p \(p) -o \(shellQuote(runningFormat)); echo '---RALLOC---'; "
            + "squeue -h -t RUNNING -p \(p) -O \(alloc)"
    }

    /// `scontrol show job` for one job. The id is normalised by `ScontrolParse.jobId` first,
    /// because `scontrol` rejects `squeue`'s bracketed pending-array notation.
    public static func showJob(jobId: String) -> String {
        "scontrol show job \(shellQuote(ScontrolParse.jobId(jobId)))"
    }

    public static func cancelJob(jobId: String) -> String {
        "scancel \(shellQuote(jobId))"
    }

    public static func listNodes() -> String {
        "scontrol show node --oneliner"
    }

    /// The live metrics streamer.
    ///
    /// The script is shipped base64-encoded so its quoting survives the ssh → srun → bash hops
    /// untouched (base64 has no shell-special characters). The `metrics-script` fixture pins the
    /// payload byte for byte.
    public static func streamJobMetrics(jobId: String) -> String {
        let b64 = Data(metricsScript.utf8).base64EncodedString()
        let inner = "echo \(b64) | base64 -d | bash"
        return "srun --jobid=\(shellQuote(jobId)) --overlap -n1 bash -c \(shellQuote(inner))"
    }

    /// Portable collector that joins a RUNNING job's allocation via `srun --overlap` and streams
    /// one tick per second: per-GPU utilization/memory from `nvidia-smi` (device-scoped to the
    /// job) plus job-wide CPU%/RAM% from the job cgroup (cgroup v2 primary, v1 fallback).
    ///
    /// Ported byte-for-byte from `METRICS_SCRIPT` in `src/lib/slurm.ts`. Swift raw strings keep
    /// the shell `${...}` expansions and the escaped `\"` inside the `awk` program literal — do
    /// not "clean up" the quoting; `MetricStream.parse` and the fixture both depend on the exact
    /// bytes.
    public static let metricsScript: String = [
        #"NCPU=${SLURM_CPUS_ON_NODE:-1}"#,
        #"if [ -f /sys/fs/cgroup/cgroup.controllers ]; then"#,
        #"  rel=$(sed -n "s/^0:://p" /proc/self/cgroup); job=${rel%%/step_*}; CG=/sys/fs/cgroup$job; MODE=v2"#,
        #"else"#,
        #"  crel=$(grep -m1 -E ":cpuacct:|:cpu,cpuacct:|:cpu:" /proc/self/cgroup | cut -d: -f3); cjob=${crel%%/step_*}"#,
        #"  mrel=$(grep -m1 ":memory:" /proc/self/cgroup | cut -d: -f3); mjob=${mrel%%/step_*}"#,
        #"  CPUF=/sys/fs/cgroup/cpu,cpuacct$cjob/cpuacct.usage; MEMC=/sys/fs/cgroup/memory$mjob/memory.usage_in_bytes; MEMM=/sys/fs/cgroup/memory$mjob/memory.limit_in_bytes; MODE=v1"#,
        #"fi"#,
        #"prev=""; ptime="""#,
        #"while true; do"#,
        #"  now=$(date +%s%3N); echo "T $now""#,
        #"  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | sed "s/^/G /""#,
        #"  if [ "$MODE" = v2 ]; then"#,
        #"    usage=$(grep usage_usec "$CG/cpu.stat" 2>/dev/null | cut -d" " -f2)"#,
        #"    memc=$(cat "$CG/memory.current" 2>/dev/null); memm=$(cat "$CG/memory.max" 2>/dev/null)"#,
        #"  else"#,
        #"    raw=$(cat "$CPUF" 2>/dev/null); usage=$(( ${raw:-0} / 1000 ))"#,
        #"    memc=$(cat "$MEMC" 2>/dev/null); memm=$(cat "$MEMM" 2>/dev/null)"#,
        #"  fi"#,
        #"  cpu="-""#,
        #"  if [ -n "$prev" ] && [ -n "$usage" ]; then"#,
        #"    dt=$(( now - ptime )); dus=$(( usage - prev ))"#,
        #"    cpu=$(awk -v dus=$dus -v dt=$dt -v n=$NCPU "BEGIN{printf \"%.1f\", (dus/1000.0)/dt/n*100}")"#,
        #"  fi"#,
        #"  prev=$usage; ptime=$now"#,
        #"  echo "C $cpu $memc $memm"; echo "E"; sleep 1"#,
        #"done"#,
    ].joined(separator: "\n")
}
