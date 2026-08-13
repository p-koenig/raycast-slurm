import { ChildProcess } from "node:child_process";
import { runSsh, spawnSsh } from "./ssh";
import { SshError } from "./errors";
import { shellQuote } from "./shell";
import { parseSlurmDurationSeconds } from "./format";
import { expandHostlist } from "./hostlist";

function splitOnSentinel(s: string, sentinel: string): [string, string] {
  const idx = s.indexOf(sentinel);
  if (idx < 0) return [s, ""];
  return [s.slice(0, idx), s.slice(idx + sentinel.length)];
}

// squeue -O column layout for the AllocTRES join. The format string handed to
// `squeue` and the slice offsets in parseAllocTres MUST stay in lockstep (the
// two-call pattern is fragile precisely here — see CLAUDE.md), so both derive
// from these constants. tres-alloc keeps a wide column because AllocTRES grows
// with every resource type; ArrayJobID/ArrayTaskID are short (an int, and a
// task index or a "44-67%2"-style range).
const ALLOC_JOBID_WIDTH = 24;
const ALLOC_TASKID_WIDTH = 24;
const ALLOC_TRES_FMT = `ArrayJobID:${ALLOC_JOBID_WIDTH},ArrayTaskID:${ALLOC_TASKID_WIDTH},tres-alloc:512`;

/**
 * Parse the output of `squeue -O ALLOC_TRES_FMT` into a map of job-id ->
 * AllocTRES, keyed to match the primary `-o %i` column so allocForJob can join
 * them.
 *
 * We deliberately do NOT key on `-O JobID`: for a RUNNING array task that field
 * prints the task's underlying JobID (e.g. 6718 for 6644_33), which `%i` never
 * exposes — so a JobID-keyed map cannot be joined for a running array task at
 * all (its `%b` GPU/mem shorthand then silently vanishes, especially in the
 * node drill-down whose `-t RUNNING` alloc call has no pending-array row to fall
 * back on). Instead we reconstruct the `%i` notation from ArrayJobID +
 * ArrayTaskID:
 *   • numeric ArrayTaskID → running task, key "6644_33"
 *   • "N/A" (non-array)   → key on ArrayJobID alone (== the JobID, e.g. "6690")
 *   • a range "44-67%2"   → pending array, key on ArrayJobID ("6644")
 * The bare-ArrayJobID key is what allocForJob's suffix-stripped fallback matches
 * for a pending array range (whose `%i` is "6644_[44-67%2]").
 */
function parseAllocTres(block: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const rawLine of block.split("\n")) {
    if (!rawLine.trim()) continue;
    const arrayJobId = rawLine.slice(0, ALLOC_JOBID_WIDTH).trim();
    const arrayTaskId = rawLine.slice(ALLOC_JOBID_WIDTH, ALLOC_JOBID_WIDTH + ALLOC_TASKID_WIDTH).trim();
    const tres = rawLine.slice(ALLOC_JOBID_WIDTH + ALLOC_TASKID_WIDTH).trim();
    if (!arrayJobId) continue;
    const key = /^\d+$/.test(arrayTaskId) ? `${arrayJobId}_${arrayTaskId}` : arrayJobId;
    map.set(key, tres);
  }
  return map;
}

// Resolve a primary-row job id (`%i`) to its AllocTRES entry. parseAllocTres
// keys a running array task under its reconstructed "base_task" notation, so a
// running task ("5818_27") lands on the exact lookup. A pending array range's
// `%i` is "5818_[28-50%2]", which never matches directly, so we retry with the
// task suffix stripped to hit the bare-ArrayJobID key ("5818"). Empty entries
// are ignored (returns undefined) so the caller keeps the `%b` shorthand.
// Non-array ids (no `_`) only ever hit the exact lookup.
function allocForJob(allocByJob: Map<string, string>, jobId: string): string | undefined {
  const exact = allocByJob.get(jobId);
  if (exact) return exact;
  const base = jobId.replace(/_.*$/, "");
  if (base !== jobId) {
    const fallback = allocByJob.get(base);
    if (fallback) return fallback;
  }
  return undefined;
}

export type JobState =
  | "RUNNING"
  | "PENDING"
  | "COMPLETING"
  | "COMPLETED"
  | "FAILED"
  | "CANCELLED"
  | "TIMEOUT"
  | "PREEMPTED"
  | "SUSPENDED"
  | "CONFIGURING"
  | "STAGE_OUT"
  | string;

export type Job = {
  jobId: string;
  partition: string;
  name: string;
  state: JobState;
  elapsed: string;
  timeLimit: string;
  nodes: string;
  cpus: string;
  reasonOrNodeList: string;
  tres: string;
  user?: string;
};

export type SlurmNode = {
  name: string;
  state: string;
  partitions: string[];
  cpuLoad: number | null;
  cpuTot: number;
  cpuAlloc: number;
  realMemoryMB: number;
  freeMemoryMB: number;
  allocMemoryMB: number;
  gres: string;
  gresUsed: string;
  allocTres: string;
  features: string;
  reason: string;
};

export type JobDetail = {
  raw: string;
  fields: Record<string, string>;
};

export async function detectUser(host: string): Promise<string> {
  const out = await runSsh(host, "whoami", { timeout: 10_000 });
  return out.trim();
}

// ---------- jobs ----------

export async function listJobs(host: string, user: string): Promise<Job[]> {
  const fmt = "%i|%P|%j|%T|%M|%l|%D|%C|%R|%b";
  const allocFmt = ALLOC_TRES_FMT;
  const cmd =
    `squeue -h -u ${shellQuote(user)} -o ${shellQuote(fmt)}; ` +
    `echo '---ALLOC---'; ` +
    `squeue -h -u ${shellQuote(user)} -O ${shellQuote(allocFmt)}`;
  const out = await runSsh(host, cmd);
  const [primary, allocBlock = ""] = splitOnSentinel(out, "---ALLOC---");
  const allocByJob = parseAllocTres(allocBlock);
  const jobs = primary
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map(parseJobRow);
  for (const j of jobs) {
    const a = allocForJob(allocByJob, j.jobId);
    if (a) j.tres = a;
  }
  return jobs;
}

// Lightweight variant for the menu bar's background refresh. Skips the second
// `squeue -O tres-alloc` call and the AllocTRES map join from listJobs, because
// the menu bar only renders state counts + basic job fields and never reads
// `tres`. `tres` is left as the `%b` GPU shorthand from parseJobRow. Keeping this
// tick cheap is what lets the background refresh land the title/color reliably
// without doing (and buffering) work the menu bar throws away.
export async function listJobsBrief(host: string, user: string): Promise<Job[]> {
  const fmt = "%i|%P|%j|%T|%M|%l|%D|%C|%R|%b";
  const out = await runSsh(host, `squeue -h -u ${shellQuote(user)} -o ${shellQuote(fmt)}`);
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map(parseJobRow);
}

function parseJobRow(row: string): Job {
  const p = row.split("|");
  return {
    jobId: p[0] ?? "",
    partition: p[1] ?? "",
    name: p[2] ?? "",
    state: (p[3] ?? "") as JobState,
    elapsed: p[4] ?? "",
    timeLimit: p[5] ?? "",
    nodes: p[6] ?? "",
    cpus: p[7] ?? "",
    reasonOrNodeList: p[8] ?? "",
    tres: p[9] ?? "",
  };
}

export async function listAllJobs(host: string): Promise<Job[]> {
  const fmt = "%i|%P|%j|%T|%M|%l|%D|%C|%R|%u|%b";
  const allocFmt = ALLOC_TRES_FMT;
  const cmd = `squeue -h -o ${shellQuote(fmt)}; ` + `echo '---ALLOC---'; ` + `squeue -h -O ${shellQuote(allocFmt)}`;
  const out = await runSsh(host, cmd);
  const [primary, allocBlock = ""] = splitOnSentinel(out, "---ALLOC---");
  const allocByJob = parseAllocTres(allocBlock);
  const jobs = primary
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map(parseAllJobRow);
  for (const j of jobs) {
    const a = allocForJob(allocByJob, j.jobId);
    if (a) j.tres = a;
  }
  return jobs;
}

function parseAllJobRow(row: string): Job {
  const p = row.split("|");
  return {
    jobId: p[0] ?? "",
    partition: p[1] ?? "",
    name: p[2] ?? "",
    state: (p[3] ?? "") as JobState,
    elapsed: p[4] ?? "",
    timeLimit: p[5] ?? "",
    nodes: p[6] ?? "",
    cpus: p[7] ?? "",
    reasonOrNodeList: p[8] ?? "",
    user: p[9] ?? "",
    tres: p[10] ?? "",
  };
}

export type QueueEntry = {
  jobId: string;
  name: string;
  user: string;
  cpus: string;
  mem: string; // requested memory as squeue prints it (%m), e.g. "64G"
  timeLimit: string; // requested wallclock (%l), e.g. "1-00:00:00" / "UNLIMITED"
  tres: string; // AllocTRES (running) or the `%b` GPU shorthand fallback
};

// A running job additionally carries its remaining wallclock (%L, "time left").
export type RunningEntry = QueueEntry & { timeLeft: string };

export type PartitionActivity = { pending: QueueEntry[]; running: RunningEntry[] };

// Everything competing for `partition`, in one SSH round trip:
//   • pending jobs in Slurm's scheduling order (priority desc, then JobID asc —
//     the FIFO tie-break the scheduler walks). The caller finds its own JobID;
//     everything before it is "ahead in the queue".
//   • running jobs, sorted by remaining time so the soonest to free resources
//     comes first.
// Each list mirrors listAllJobs' resource routine: a primary `-o` row plus a
// second `-O tres-alloc` call joined by JobID, so GPUs/mem parse the same way
// they do in the All Jobs view (gpuLabelFromTres / memFromTres over `tres`).
export async function listPartitionActivity(host: string, partition: string): Promise<PartitionActivity> {
  const p = shellQuote(partition);
  const allocFmt = ALLOC_TRES_FMT;
  const pendFmt = "%i|%j|%u|%C|%m|%l|%b";
  const runFmt = "%i|%j|%u|%C|%m|%l|%L|%b";
  const cmd =
    `squeue -h -t PENDING -p ${p} --sort=-p,i -o ${shellQuote(pendFmt)}; echo '---PALLOC---'; ` +
    `squeue -h -t PENDING -p ${p} --sort=-p,i -O ${shellQuote(allocFmt)}; echo '---RUN---'; ` +
    `squeue -h -t RUNNING -p ${p} -o ${shellQuote(runFmt)}; echo '---RALLOC---'; ` +
    `squeue -h -t RUNNING -p ${p} -O ${shellQuote(allocFmt)}`;
  const out = await runSsh(host, cmd);

  const [pendPrimary, afterPP] = splitOnSentinel(out, "---PALLOC---");
  const [pendAlloc, afterPA] = splitOnSentinel(afterPP, "---RUN---");
  const [runPrimary, runAlloc = ""] = splitOnSentinel(afterPA, "---RALLOC---");

  const pending = joinAlloc(parseRows(pendPrimary, parsePendingRow), pendAlloc);
  const running = joinAlloc(parseRows(runPrimary, parseRunningRow), runAlloc).sort(
    (a, b) => timeLeftSeconds(a.timeLeft) - timeLeftSeconds(b.timeLeft),
  );
  return { pending, running };
}

function parseRows<T>(block: string, parse: (row: string) => T): T[] {
  return block
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map(parse);
}

// Overwrite each entry's `tres` with its AllocTRES (when present) the same way
// listAllJobs does; pending jobs keep the `%b` shorthand from the primary row.
function joinAlloc<T extends { jobId: string; tres: string }>(entries: T[], allocBlock: string): T[] {
  const allocByJob = parseAllocTres(allocBlock);
  for (const e of entries) {
    const a = allocForJob(allocByJob, e.jobId);
    if (a) e.tres = a;
  }
  return entries;
}

function parsePendingRow(row: string): QueueEntry {
  const p = row.split("|");
  return {
    jobId: p[0] ?? "",
    name: p[1] ?? "",
    user: p[2] ?? "",
    cpus: p[3] ?? "",
    mem: p[4] ?? "",
    timeLimit: p[5] ?? "",
    tres: p[6] ?? "",
  };
}

function parseRunningRow(row: string): RunningEntry {
  const p = row.split("|");
  return {
    jobId: p[0] ?? "",
    name: p[1] ?? "",
    user: p[2] ?? "",
    cpus: p[3] ?? "",
    mem: p[4] ?? "",
    timeLimit: p[5] ?? "",
    timeLeft: p[6] ?? "",
    tres: p[7] ?? "",
  };
}

// "1-04:23:11" / "23:45:00" → seconds for sorting; UNLIMITED sinks to the end.
function timeLeftSeconds(v: string): number {
  if (!v || v.toUpperCase() === "UNLIMITED") return Number.MAX_SAFE_INTEGER;
  return parseSlurmDurationSeconds(v) ?? Number.MAX_SAFE_INTEGER;
}

export type NodeJob = {
  jobId: string;
  user: string;
  name: string;
  partition: string;
  elapsed: string;
  timeLimit: string;
  nodeCount: string; // %D — how many nodes the job holds, this one included
  cpus: string;
  tres: string; // AllocTRES (see the caveat on listNodeJobs)
};

// Everything RUNNING on a single node — the Node Utilization drill-down. `-w`
// selects jobs holding an allocation on that node; the AllocTRES join mirrors
// listAllJobs so the GPU/mem tags parse identically to the other job lists.
//
// CAVEAT: AllocTRES is job-wide, so for a job spanning several nodes the CPU /
// mem / GPU figures cover its whole allocation, not just its share of *this*
// node. Slurm exposes no per-node breakdown via squeue, so we carry `nodeCount`
// and let the UI flag those rows rather than print a number we can't stand behind.
const NODE_JOB_FMT = "%i|%u|%j|%P|%M|%l|%D|%C|%b";

export async function listNodeJobs(host: string, node: string): Promise<NodeJob[]> {
  const w = shellQuote(node);
  const allocFmt = ALLOC_TRES_FMT;
  const cmd =
    `squeue -h -w ${w} -t RUNNING -o ${shellQuote(NODE_JOB_FMT)}; echo '---ALLOC---'; ` +
    `squeue -h -w ${w} -t RUNNING -O ${shellQuote(allocFmt)}`;
  try {
    const out = await runSsh(host, cmd);
    const [primary, allocBlock = ""] = splitOnSentinel(out, "---ALLOC---");
    return joinAlloc(parseRows(primary, parseNodeJobRow), allocBlock);
  } catch (err) {
    if (!isInvalidNodeName(err)) throw err;
    return listNodeJobsByNodeList(host, node);
  }
}

// squeue resolves `-w` against the controller's *usable* node table, which on a
// cloud/dynamic cluster excludes the very nodes `scontrol show node --future`
// surfaces (see SHOW_NODES_CMD) — every drill-down there dies with
// "squeue: error: Invalid node name <node>", including for nodes that plainly
// have running jobs. So we re-ask without the filter, carrying `%N` (the job's
// allocated nodelist) as an extra trailing column, and match client-side.
// Cluster-wide `-t RUNNING` is the heavier query, hence fallback-only: clusters
// whose `-w` works never issue it.
async function listNodeJobsByNodeList(host: string, node: string): Promise<NodeJob[]> {
  const cmd =
    `squeue -h -t RUNNING -o ${shellQuote(`${NODE_JOB_FMT}|%N`)}; echo '---ALLOC---'; ` +
    `squeue -h -t RUNNING -O ${shellQuote(ALLOC_TRES_FMT)}`;
  const out = await runSsh(host, cmd);
  const [primary, allocBlock = ""] = splitOnSentinel(out, "---ALLOC---");
  // parseNodeJobRow reads fields 0..8, so the appended %N is ignored by it and
  // read separately here.
  const rows = parseRows(primary, (row) => ({
    job: parseNodeJobRow(row),
    nodes: expandHostlist(row.split("|")[9] ?? ""),
  }));
  const onNode = rows.filter((r) => r.nodes.includes(node)).map((r) => r.job);
  return joinAlloc(onNode, allocBlock);
}

function isInvalidNodeName(err: unknown): boolean {
  if (!(err instanceof SshError)) return false;
  return /invalid node name/i.test(`${err.info.raw} ${err.info.message}`);
}

function parseNodeJobRow(row: string): NodeJob {
  const p = row.split("|");
  return {
    jobId: p[0] ?? "",
    user: p[1] ?? "",
    name: p[2] ?? "",
    partition: p[3] ?? "",
    elapsed: p[4] ?? "",
    timeLimit: p[5] ?? "",
    nodeCount: p[6] ?? "",
    cpus: p[7] ?? "",
    tres: p[8] ?? "",
  };
}

// squeue's `%i` renders a still-pending array as `6754_[380-543%1]` — base id +
// bracketed task range + optional `%N` throttle. scontrol's job-id parser rejects
// that syntax outright ("Invalid job id specified"), so strip the bracketed tail
// and query the base array job id, which scontrol resolves to the pending array
// record. A running task (`6754_380`) and a plain job (`6754`) contain no bracket
// and pass through unchanged, so scontrol still gets that exact task/job.
export function scontrolJobId(jobId: string): string {
  return jobId.replace(/_\[.*$/, "");
}

export async function showJob(host: string, jobId: string): Promise<JobDetail> {
  const raw = await runSsh(host, `scontrol show job ${shellQuote(scontrolJobId(jobId))}`);
  const fields = tokenizeKv(raw);
  return { raw, fields };
}

export async function cancelJob(host: string, jobId: string): Promise<void> {
  await runSsh(host, `scancel ${shellQuote(jobId)}`);
}

// ---------- nodes ----------

// `scontrol show node` silently omits nodes slurmctld considers not-yet-real:
// FUTURE-state nodes, and cloud/dynamic nodes it can't resolve an address for
// (`Reason=NO NETWORK ADDRESS FOUND`). On a cloud-provisioned cluster that can
// be *every* node — the Info/Utilization views then render empty while the job
// views work fine, because squeue is unaffected. `--future` includes them, and
// their records are complete (CPUTot / RealMemory / Gres / Partitions / TRES),
// so everything downstream parses as usual; the node's `State` still says
// FUTURE where that's the case. The flag landed in Slurm 20.11, hence the
// fallback for older controllers — kept in one command so it stays one round
// trip on the clusters that do support it.
const SHOW_NODES_CMD = "scontrol show node --future --oneliner 2>/dev/null || scontrol show node --oneliner";

export async function listNodes(host: string): Promise<SlurmNode[]> {
  const out = await runSsh(host, SHOW_NODES_CMD);
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map(parseNodeLine);
}

function parseNodeLine(line: string): SlurmNode {
  const fields = tokenizeKv(line);
  return {
    name: fields.NodeName ?? "",
    state: fields.State ?? "",
    partitions: (fields.Partitions ?? "").split(",").filter(Boolean),
    cpuLoad: fields.CPULoad && fields.CPULoad !== "N/A" ? Number(fields.CPULoad) : null,
    cpuTot: numOr(fields.CPUTot, 0),
    cpuAlloc: numOr(fields.CPUAlloc, 0),
    realMemoryMB: numOr(fields.RealMemory, 0),
    freeMemoryMB: numOr(fields.FreeMem, 0),
    allocMemoryMB: numOr(fields.AllocMem, 0),
    gres: fields.Gres ?? "",
    gresUsed: fields.GresUsed ?? "",
    allocTres: fields.AllocTRES ?? fields.AllocTres ?? "",
    features: fields.AvailableFeatures ?? fields.Features ?? "",
    reason: fields.Reason ?? "",
  };
}

function numOr(v: string | undefined, fallback: number): number {
  if (!v) return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * Parse `Key=Value` tokens out of a whitespace-separated line, handling
 * quoted Reason="..." values. Ignores tokens without an `=`.
 */
function tokenizeKv(line: string): Record<string, string> {
  const out: Record<string, string> = {};
  let i = 0;
  const n = line.length;
  while (i < n) {
    while (i < n && /\s/.test(line[i])) i++;
    if (i >= n) break;
    const keyStart = i;
    while (i < n && line[i] !== "=" && !/\s/.test(line[i])) i++;
    if (line[i] !== "=") {
      // bare token, skip
      while (i < n && !/\s/.test(line[i])) i++;
      continue;
    }
    const key = line.slice(keyStart, i);
    i++; // skip '='
    let value: string;
    if (line[i] === '"') {
      i++;
      const start = i;
      while (i < n && line[i] !== '"') i++;
      value = line.slice(start, i);
      if (line[i] === '"') i++;
    } else {
      const start = i;
      while (i < n && !/\s/.test(line[i])) i++;
      value = line.slice(start, i);
    }
    if (!(key in out)) out[key] = value;
  }
  return out;
}

// ---------- log tail ----------

export function tailFile(host: string, filePath: string): ChildProcess {
  return spawnSsh(host, `tail -n 200 -F ${shellQuote(filePath)}`);
}

// One-shot read of the *bottom* of a log file for the embedded Output/Error
// detail panes. We never read the whole file — ML run logs are routinely
// gigabytes — so this is bounded twice: `tail -c` caps the bytes pulled over the
// wire (a CR-redraw progress bar can make a single "line" enormous, see the
// tailview-cr-buffer-leak note), then CR redraws are flattened to newlines and
// `tail -n` keeps the last `lines`. The newest content ends up at the bottom.
const LOG_TAIL_BYTES = 128 * 1024;

export async function readLogTail(host: string, filePath: string, lines: number): Promise<string> {
  const n = Math.max(1, Math.floor(lines));
  const cmd = `tail -c ${LOG_TAIL_BYTES} -- ${shellQuote(filePath)} | tr '\\r' '\\n' | tail -n ${n}`;
  return runSsh(host, cmd);
}

// ---------- live job metrics ----------

// Portable collector that joins a RUNNING job's allocation via `srun --overlap`
// and streams one tick per second: per-GPU utilization/memory from nvidia-smi
// (device-scoped to the job) plus job-wide CPU%/RAM% from the job cgroup
// (cgroup v2 primary, v1 fallback). Single-quoted JS strings keep the shell
// `${...}` expansions literal; see parseMetricStream for the output format.
const METRICS_SCRIPT = [
  "NCPU=${SLURM_CPUS_ON_NODE:-1}",
  "if [ -f /sys/fs/cgroup/cgroup.controllers ]; then",
  '  rel=$(sed -n "s/^0:://p" /proc/self/cgroup); job=${rel%%/step_*}; CG=/sys/fs/cgroup$job; MODE=v2',
  "else",
  '  crel=$(grep -m1 -E ":cpuacct:|:cpu,cpuacct:|:cpu:" /proc/self/cgroup | cut -d: -f3); cjob=${crel%%/step_*}',
  '  mrel=$(grep -m1 ":memory:" /proc/self/cgroup | cut -d: -f3); mjob=${mrel%%/step_*}',
  "  CPUF=/sys/fs/cgroup/cpu,cpuacct$cjob/cpuacct.usage; MEMC=/sys/fs/cgroup/memory$mjob/memory.usage_in_bytes; MEMM=/sys/fs/cgroup/memory$mjob/memory.limit_in_bytes; MODE=v1",
  "fi",
  'prev=""; ptime=""',
  "while true; do",
  '  now=$(date +%s%3N); echo "T $now"',
  '  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | sed "s/^/G /"',
  '  if [ "$MODE" = v2 ]; then',
  '    usage=$(grep usage_usec "$CG/cpu.stat" 2>/dev/null | cut -d" " -f2)',
  '    memc=$(cat "$CG/memory.current" 2>/dev/null); memm=$(cat "$CG/memory.max" 2>/dev/null)',
  "  else",
  '    raw=$(cat "$CPUF" 2>/dev/null); usage=$(( ${raw:-0} / 1000 ))',
  '    memc=$(cat "$MEMC" 2>/dev/null); memm=$(cat "$MEMM" 2>/dev/null)',
  "  fi",
  '  cpu="-"',
  '  if [ -n "$prev" ] && [ -n "$usage" ]; then',
  "    dt=$(( now - ptime )); dus=$(( usage - prev ))",
  '    cpu=$(awk -v dus=$dus -v dt=$dt -v n=$NCPU "BEGIN{printf \\"%.1f\\", (dus/1000.0)/dt/n*100}")',
  "  fi",
  "  prev=$usage; ptime=$now",
  '  echo "C $cpu $memc $memm"; echo "E"; sleep 1',
  "done",
].join("\n");

export function streamJobMetrics(host: string, jobId: string): ChildProcess {
  // Ship the script base64-encoded so its quoting survives the ssh → srun → bash
  // hops untouched (base64 has no shell-special characters).
  const b64 = Buffer.from(METRICS_SCRIPT).toString("base64");
  const inner = `echo ${b64} | base64 -d | bash`;
  const cmd = `srun --jobid=${shellQuote(jobId)} --overlap -n1 bash -c ${shellQuote(inner)}`;
  return spawnSsh(host, cmd);
}
