/**
 * Golden fixture exporter — the cross-language parity contract for the macOS port.
 *
 * Runs the REAL extension parsers (src/lib/*) in demo mode and writes
 * fixtures/<kind>.json: the raw wire input, the exact remote command string the
 * lib issued, and the TS-parsed result. macos/SlurmKit's golden tests feed each
 * `input` through the ported Swift parser and require the decoded value to equal
 * `expected`; command builders are asserted against `cmd`.
 *
 * Run it with `npm run export-fixtures` — that sets RAYCAST_SLURM_DEMO=1 (routes
 * every runSsh through demo.ts), RAYCAST_SLURM_FIXTURE_LOG=1 (enables demo.ts's
 * call log + frozen clock) and TZ=UTC (demo.ts renders scontrol timestamps in
 * local time). Output must be byte-identical between runs; CI gates on
 * `git diff --exit-code fixtures/`.
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { DEMO_USER, mockCallLog } from "../src/lib/demo";
import {
  listAllJobs,
  listJobs,
  listJobsBrief,
  listNodeJobs,
  listNodes,
  listPartitionActivity,
  scontrolJobId,
  showJob,
  streamJobMetrics,
  type Job,
  type NodeJob,
  type PartitionActivity,
  type SlurmNode,
} from "../src/lib/slurm";
import {
  formatBytesMB,
  formatDurationSeconds,
  formatPercent,
  formatSlurmDuration,
  gpuCountFromGres,
  gpuCountFromTres,
  gpuInfoFromTres,
  gpuLabelFromTres,
  memFromTres,
  parseSlurmDurationSeconds,
  prettifyGpuModel,
  shortNodeState,
  shortReason,
} from "../src/lib/format";
import { expandHostlist } from "../src/lib/hostlist";
import { parseMetricStream } from "../src/lib/metrics";
import { shellQuote } from "../src/lib/shell";

const FIXTURE_VERSION = 1;

// ---------- serialization (determinism) ----------

// Byte-stability is the acceptance gate, so every object key is sorted and the
// document ends with exactly one newline. Locale-independent comparator on
// purpose: String.prototype.localeCompare varies with the ICU build.
function cmpStr(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function sortKeysDeep(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeysDeep);
  if (v && typeof v === "object") {
    const src = v as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(src).sort(cmpStr)) {
      if (src[k] === undefined) continue;
      out[k] = sortKeysDeep(src[k]);
    }
    return out;
  }
  return v;
}

type FixtureCase = {
  name: string;
  host?: string;
  cmd?: string;
  input?: unknown;
  expected: unknown;
  note?: string;
};

const REPO_ROOT = process.cwd();
const FIXTURE_DIR = path.join(REPO_ROOT, "fixtures");

function writeKind(kind: string, cases: FixtureCase[]): void {
  const names = new Set<string>();
  for (const c of cases) {
    if (names.has(c.name)) throw new Error(`${kind}: duplicate case name ${JSON.stringify(c.name)}`);
    names.add(c.name);
    if (c.expected === undefined) throw new Error(`${kind}/${c.name}: expected is undefined`);
  }
  const doc = sortKeysDeep({ version: FIXTURE_VERSION, kind, cases });
  fs.writeFileSync(path.join(FIXTURE_DIR, `${kind}.json`), JSON.stringify(doc, null, 2) + "\n", "utf8");
  console.log(`fixtures/${kind}.json  ${cases.length} case(s)`);
}

// ---------- capture ----------

// Every high-level lib call is exactly one runSsh round trip; demo.ts's call log
// hands us the wire input plus the command string the lib actually built, so
// neither is re-derived here.
async function capture<T>(name: string, host: string, run: () => Promise<T>): Promise<{ c: FixtureCase; value: T }> {
  const before = mockCallLog.length;
  const value = await run();
  const calls = mockCallLog.slice(before);
  if (calls.length !== 1) {
    throw new Error(`${name}: expected exactly 1 ssh call, got ${calls.length} — demo call log is not usable`);
  }
  return { c: { name, host, cmd: calls[0].cmd, input: calls[0].out, expected: value }, value };
}

// ---------- harvested scalar inputs ----------

const tresStrings = new Set<string>();
const gresStrings = new Set<string>();
const durationStrings = new Set<string>();
const hostlistStrings = new Set<string>();
const nodeStateStrings = new Set<string>();
const reasonStrings = new Set<string>();
const jobIdStrings = new Set<string>();

function harvestJobs(jobs: Job[]): void {
  for (const j of jobs) {
    tresStrings.add(j.tres);
    durationStrings.add(j.elapsed);
    durationStrings.add(j.timeLimit);
    hostlistStrings.add(j.reasonOrNodeList);
    jobIdStrings.add(j.jobId);
  }
}

function harvestNodeJobs(rows: NodeJob[]): void {
  for (const r of rows) {
    tresStrings.add(r.tres);
    durationStrings.add(r.elapsed);
    durationStrings.add(r.timeLimit);
    jobIdStrings.add(r.jobId);
  }
}

function harvestPartitionActivity(pa: PartitionActivity): void {
  for (const e of pa.pending) {
    tresStrings.add(e.tres);
    durationStrings.add(e.timeLimit);
    jobIdStrings.add(e.jobId);
  }
  for (const e of pa.running) {
    tresStrings.add(e.tres);
    durationStrings.add(e.timeLimit);
    durationStrings.add(e.timeLeft);
    jobIdStrings.add(e.jobId);
  }
}

function harvestNodes(nodes: SlurmNode[]): void {
  for (const n of nodes) {
    gresStrings.add(n.gres);
    gresStrings.add(n.gresUsed);
    tresStrings.add(n.allocTres);
    nodeStateStrings.add(n.state);
    reasonStrings.add(n.reason);
    hostlistStrings.add(n.name);
  }
}

function sorted(set: Set<string>): string[] {
  return [...set].sort(cmpStr);
}

// ---------- format-scalars ----------

function scalarCase(fn: string, input: unknown, expected: unknown): FixtureCase {
  return { name: `${fn} ${JSON.stringify(input)}`, input: { fn, input }, expected };
}

function buildFormatScalars(): FixtureCase[] {
  const cases: FixtureCase[] = [];
  const add = (fn: string, inputs: unknown[], run: (v: never) => unknown) => {
    const seen = new Set<string>();
    for (const input of inputs) {
      const key = JSON.stringify(input);
      if (seen.has(key)) continue;
      seen.add(key);
      cases.push(scalarCase(fn, input, run(input as never)));
    }
  };

  // Every GPU string shape documented in CLAUDE.md, plus whatever the demo
  // corpus actually produced.
  const handTres = [
    // typed TRES ("gres/gpu:<model>=N") — AllocTRES carries both forms
    "cpu=64,mem=512G,node=1,gres/gpu=4,gres/gpu:rtx_pro_6000=4",
    "cpu=8,gres/gpu:a100=0",
    // generic TRES ("gres/gpu=N")
    "cpu=16,mem=128G,gres/gpu=2",
    "cpu=16,mem=128G,gres/gpu=0",
    // per-node gres / squeue %b ("gres/gpu:<model>:N")
    "gres/gpu:A100:4",
    "gres/gpu:2g.10gb:1", // MIG profile
    "gres/gpu:1", // untyped
    "gres/gpu:0",
    // GRES legacy ("gpu:<model>:N")
    "gpu:a100:2",
    "gpu:8",
    "gpu:a100:4(S:0-1)",
    "gpu:rtx2080ti:2",
    // memory shapes
    "cpu=1,mem=1024M",
    "cpu=1,mem=1536M",
    "cpu=1,mem=100M",
    "cpu=1,mem=512",
    "cpu=1,mem=1T",
    "cpu=1,mem=64G,node=1",
    "mem=0M",
    // sentinels / junk
    "",
    "N/A",
    "(null)",
    "cpu=4,node=1",
    "billing=8,cpu=8",
  ];
  const tresInputs = [...sorted(tresStrings), ...handTres];
  const gresInputs = [
    ...sorted(gresStrings),
    "gpu:a100:4(S:0-1)",
    "gpu:8",
    "gpu:rtx2080ti:2",
    "gpu:h100:0",
    "(null)",
    "",
    "gres/gpu:1",
  ];

  add("gpuCountFromTres", tresInputs, (v: string) => gpuCountFromTres(v));
  add("memFromTres", tresInputs, (v: string) => memFromTres(v));
  add("gpuLabelFromTres", tresInputs, (v: string) => gpuLabelFromTres(v));
  add("gpuInfoFromTres", tresInputs, (v: string) => gpuInfoFromTres(v));
  add("gpuCountFromGres", gresInputs, (v: string) => gpuCountFromGres(v));

  const handDurations = [
    "1-04:23:11",
    "23:45",
    "UNLIMITED",
    "unlimited",
    "not-a-duration",
    "",
    "0:00",
    "00:00:00",
    "7-00:00:00",
    "1-12:30", // day prefix with only two clock parts
    "1-2-3", // three dash segments -> not a day prefix
    "5", // single component
    "1:2:3:4", // four components
    "x-01:00:00",
    "12:00:00",
    "0-00:00:30",
  ];
  const durationInputs = [...sorted(durationStrings), ...handDurations];
  add("parseSlurmDurationSeconds", durationInputs, (v: string) => parseSlurmDurationSeconds(v));
  add("formatSlurmDuration", durationInputs, (v: string) => formatSlurmDuration(v));

  add(
    "formatDurationSeconds",
    [0, -1, 1, 30, 59, 60, 61, 599, 3599, 3600, 3661, 8045, 86_399, 86_400, 90_061, 604_800],
    (v: number) => formatDurationSeconds(v),
  );

  add(
    "formatBytesMB",
    [0, -5, 1, 511, 512, 1023, 1024, 1536, 102_400, 257_024, 1_015_808, 1_048_576, 2_621_440],
    (v: number) => formatBytesMB(v),
  );

  add(
    "formatPercent",
    [
      [0, 0],
      [50, 100],
      [1, 3],
      [3, 3],
      [5, 0],
      [655_360, 1_015_808],
      [7, 8],
    ],
    (v: [number, number]) => formatPercent(v[0], v[1]),
  );

  const handHostlists = [
    "gpu[01-02,05],cpu7",
    "rack[1-2]node[3-4]", // nested-looking suffix: only the first group expands
    "dgx[01-02]a", // suffix after the range
    "gpu[a-b]", // malformed range, silently skipped
    "gpu[01-02,]", // trailing empty range entry
    "gpu[3]", // single value, no dash
    "n[001-003]",
    "gpu01",
    "",
    "(Resources)",
    "gpu[01-02],gpu[05-06]",
  ];
  add("expandHostlist", [...sorted(hostlistStrings), ...handHostlists], (v: string) => expandHostlist(v));

  add(
    "shortNodeState",
    [...sorted(nodeStateStrings), "MIXED+DRAIN", "ALLOCATED,RESERVED", "IDLE+CLOUD+POWERED_DOWN", "DOWN*", ""],
    (v: string) => shortNodeState(v),
  );

  add("shortReason", [...sorted(reasonStrings), "None", "", "hardware fault GPU0", null], (v: string | undefined) =>
    shortReason(v ?? undefined),
  );

  add(
    "prettifyGpuModel",
    ["rtx_pro_6000", "a100", "h100", "l40s", "2g.10gb", "", "RTX_A6000", "_leading"],
    (v: string) => prettifyGpuModel(v),
  );

  // Not in the ARCHITECTURE fn list, but shellQuote is in "semantics that MUST
  // survive the port" and every captured `cmd` depends on it; this is its only
  // direct fixture home.
  add(
    "shellQuote",
    [
      "",
      "r.shaw",
      "gpu-long",
      "145851_[3-64%1]",
      "%i|%P|%j|%T|%M|%l|%D|%C|%R|%b",
      "ArrayJobID:24,ArrayTaskID:24,tres-alloc:512",
      "/home/r.shaw/logs/train.out",
      "cpu,dev",
      "a b",
      "o'brien",
      "it's a 'test'",
      "$(rm -rf /)",
      "back\\slash",
      "-p",
    ],
    (v: string) => shellQuote(v),
  );

  add(
    "scontrolJobId",
    [...sorted(jobIdStrings), "6754_[380-543%1]", "6754_380", "6754", "145851_[3-64%1]", "9_[1-2]", "9_[1-2]_x"],
    (v: string) => scontrolJobId(v),
  );

  return cases;
}

// ---------- metric-stream ----------

function buildMetricStream(): FixtureCase[] {
  const cases: FixtureCase[] = [];
  const add = (name: string, buffer: string, note?: string) =>
    cases.push({ name, input: buffer, expected: parseMetricStream(buffer), note });

  add(
    "two-complete-ticks-plus-partial",
    [
      "T 1767225600000",
      "G 0, NVIDIA A100-SXM4-80GB, 94, 61440, 81920",
      "G 1, NVIDIA A100-SXM4-80GB, 88, 49152, 81920",
      "C 62.5 34359738368 68719476736",
      "E",
      "T 1767225601000",
      "G 0, NVIDIA A100-SXM4-80GB, 97, 63897, 81920",
      "G 1, NVIDIA A100-SXM4-80GB, 91, 40960, 81920",
      "C 71.3 35433480192 68719476736",
      "E",
      "T 1767225602000",
      "G 0, NVIDIA A100-SXM4-80GB, 90, 61440, 81920",
      "",
    ].join("\n"),
    "trailing incomplete tick must be carried in `rest`, not parsed",
  );

  add(
    "unsorted-gpus-and-degenerate-fields",
    [
      "T 1767225610000",
      "G 2, NVIDIA H100 80GB HBM3, 55, 40779, 81559",
      "G 0, NVIDIA H100 80GB HBM3, 97, 61169, 81559",
      "G 1, NVIDIA H100 80GB HBM3, 12, 8155, 81559",
      "G 3, NVIDIA H100 80GB HBM3, 40, 100, 0", // total <= 0 -> dropped
      "G x, NVIDIA H100 80GB HBM3, 40, 100, 81559", // non-finite index -> dropped
      "G 4, NVIDIA H100 80GB HBM3, [N/A], 100, 81559", // non-finite util -> dropped
      "C - 1024 0", // cpu "-" -> null; memMax 0 -> ram null
      "E",
      "",
    ].join("\n"),
    "gpus sorted by index per tick; malformed G lines dropped; `-` cpu and zero memMax become null",
  );

  add(
    "cpu-only-tick-no-gpus",
    ["T 1767225620000", "C 87.0 17179869184 34359738368", "E", ""].join("\n"),
    "CPU-only job: nvidia-smi emits nothing, gpus is empty",
  );

  add(
    "no-sentinel-yet",
    ["T 1767225630000", "G 0, NVIDIA L40S, 66, 23034, 46068", "C 42.0 1024 4096"].join("\n"),
    "no `E` line: zero samples, whole buffer carried as rest",
  );

  return cases;
}

// ---------- metrics-script ----------

// METRICS_SCRIPT is module-private in slurm.ts (extension source is read-only for
// this phase), so it is recovered two independent ways and the results must agree:
//   1. at the transport boundary — child_process.spawn is stubbed for one call so
//      streamJobMetrics builds its real `srun ... | base64 -d | bash` command
//      without spawning anything;
//   2. from the source text of slurm.ts.
// Disagreement or a failed extraction aborts the export rather than emitting a guess.
function captureStreamCommand(host: string, jobId: string): string {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const cp = require("node:child_process") as { spawn: (...args: unknown[]) => unknown };
  const real = cp.spawn;
  let captured: string | null = null;
  cp.spawn = (_bin: unknown, args: unknown) => {
    const argv = args as string[];
    captured = argv[argv.length - 1];
    return {} as unknown;
  };
  try {
    streamJobMetrics(host, jobId);
  } finally {
    cp.spawn = real;
  }
  if (captured == null) throw new Error("metrics-script: streamJobMetrics did not reach child_process.spawn");
  return captured;
}

function metricsScriptFromSource(): string {
  const file = path.join(REPO_ROOT, "src", "lib", "slurm.ts");
  const src = fs.readFileSync(file, "utf8");
  const startMarker = "const METRICS_SCRIPT = [";
  const start = src.indexOf(startMarker);
  if (start < 0) throw new Error(`metrics-script: '${startMarker}' not found in ${file}`);
  const endMarker = '].join("\\n");';
  const end = src.indexOf(endMarker, start);
  if (end < 0) throw new Error(`metrics-script: '${endMarker}' not found after METRICS_SCRIPT in ${file}`);
  const body = src.slice(start + startMarker.length, end);
  let lines: unknown;
  try {
    lines = new Function(`"use strict"; return [${body}];`)();
  } catch (err) {
    throw new Error(`metrics-script: METRICS_SCRIPT array literal did not evaluate: ${String(err)}`);
  }
  if (!Array.isArray(lines) || lines.length === 0 || lines.some((l) => typeof l !== "string")) {
    throw new Error("metrics-script: METRICS_SCRIPT did not evaluate to a non-empty array of string literals");
  }
  return (lines as string[]).join("\n");
}

function buildMetricsScript(): FixtureCase[] {
  const cmd = captureStreamCommand("phoenix", "145789");
  const m = /echo ([A-Za-z0-9+/=]+) \| base64 -d \| bash/.exec(cmd);
  if (!m) throw new Error(`metrics-script: could not find the base64 payload in ${JSON.stringify(cmd)}`);
  const b64 = m[1];
  const fromSource = Buffer.from(metricsScriptFromSource(), "utf8").toString("base64");
  if (b64 !== fromSource) {
    throw new Error(
      "metrics-script: the script captured at the transport boundary does not match the one extracted from " +
        "src/lib/slurm.ts — refusing to emit a guess",
    );
  }
  return [
    {
      name: "streamJobMetrics-payload",
      host: "phoenix",
      cmd,
      expected: { b64 },
      note: "base64 of METRICS_SCRIPT; Phase 4 must ship byte-identical bytes through the same srun invocation",
    },
  ];
}

// ---------- main ----------

async function main(): Promise<void> {
  if (process.env.RAYCAST_SLURM_DEMO !== "1") {
    throw new Error("RAYCAST_SLURM_DEMO=1 is required (run via `npm run export-fixtures`)");
  }
  if (process.env.RAYCAST_SLURM_FIXTURE_LOG !== "1") {
    throw new Error("RAYCAST_SLURM_FIXTURE_LOG=1 is required (run via `npm run export-fixtures`)");
  }
  // demo.ts renders scontrol timestamps with local-time getters; UTC keeps the
  // exported job-detail fixtures machine-independent.
  if (new Date().getTimezoneOffset() !== 0) {
    throw new Error("TZ=UTC is required for reproducible job-detail fixtures (run via `npm run export-fixtures`)");
  }
  if (!fs.existsSync(path.join(REPO_ROOT, "package.json"))) {
    throw new Error(`run from the repository root (cwd=${REPO_ROOT})`);
  }

  fs.mkdirSync(FIXTURE_DIR, { recursive: true });
  for (const f of fs.readdirSync(FIXTURE_DIR)) {
    if (f.endsWith(".json")) fs.unlinkSync(path.join(FIXTURE_DIR, f));
  }

  // ----- jobs-user -----
  const jobsUser: FixtureCase[] = [];
  for (const host of ["phoenix", "nimbus"]) {
    const r = await capture(`${host}-mine`, host, () => listJobs(host, DEMO_USER));
    harvestJobs(r.value);
    jobsUser.push(r.c);
  }
  for (const host of ["phoenix", "nimbus"]) {
    const r = await capture(`${host}-mine-brief`, host, () => listJobsBrief(host, DEMO_USER));
    jobsUser.push({
      ...r.c,
      note:
        "listJobsBrief (menu bar) issues a single squeue without the '---ALLOC---' sentinel, but demo.ts keys its " +
        "responses on the command prefix and returns the two-block body anyway. The expected value is therefore " +
        "what parseJobRow really produces for the sentinel line and the fixed-width alloc rows — a pipe-free row " +
        "becomes jobId=<whole line>. Kept as a parser-tolerance vector; the command string is the parity-relevant part.",
    });
  }
  writeKind("jobs-user", jobsUser);

  // ----- jobs-all -----
  const jobsAll: FixtureCase[] = [];
  for (const host of ["phoenix", "nimbus"]) {
    const r = await capture(`${host}-all`, host, () => listAllJobs(host));
    harvestJobs(r.value);
    jobsAll.push(r.c);
  }
  writeKind("jobs-all", jobsAll);

  // ----- node-jobs -----
  const nodeJobs: FixtureCase[] = [];
  const nodeTargets: [string, string, string][] = [
    ["phoenix", "gpu01", "phoenix-gpu01-multinode"], // 145782 spans gpu[01-02] -> nodeCount 2
    ["phoenix", "gpu14", "phoenix-gpu14-running-array-task"], // 145843_7 joins via ArrayJobID+ArrayTaskID
    ["phoenix", "gpu05", "phoenix-gpu05-idle-empty"], // idle node -> no rows at all
    ["phoenix", "gpu03", "phoenix-gpu03-single-tenant"],
    ["nimbus", "gpu02", "nimbus-gpu02"],
    ["nimbus", "cpu03", "nimbus-cpu03-no-gpu"],
  ];
  for (const [host, node, name] of nodeTargets) {
    const r = await capture(name, host, () => listNodeJobs(host, node));
    harvestNodeJobs(r.value);
    nodeJobs.push(r.c);
  }
  writeKind("node-jobs", nodeJobs);

  // ----- partition-activity -----
  const partitionActivity: FixtureCase[] = [];
  const partitionTargets: [string, string, string][] = [
    ["phoenix", "gpu", "phoenix-gpu-pending-and-running"],
    ["phoenix", "gpu-long", "phoenix-gpu-long-running-only"],
    ["phoenix", "debug", "phoenix-debug-both-empty"],
    ["phoenix", "", "phoenix-empty-partition-arg"], // shellQuote("") -> ''
    ["nimbus", "cpu-long", "nimbus-cpu-long-pending-and-running"],
    ["nimbus", "gpu", "nimbus-gpu"],
    ["nimbus", "cpu,dev", "nimbus-multi-partition"],
  ];
  for (const [host, partition, name] of partitionTargets) {
    const r = await capture(name, host, () => listPartitionActivity(host, partition));
    harvestPartitionActivity(r.value);
    partitionActivity.push(r.c);
  }
  writeKind("partition-activity", partitionActivity);

  // ----- nodes -----
  const nodes: FixtureCase[] = [];
  for (const host of ["phoenix", "nimbus"]) {
    const r = await capture(`${host}-nodes`, host, () => listNodes(host));
    harvestNodes(r.value);
    nodes.push(r.c);
  }
  writeKind("nodes", nodes);

  // ----- job-detail -----
  const jobDetail: FixtureCase[] = [];
  const detailTargets: [string, string, string][] = [
    ["phoenix", "145789", "phoenix-running-plain"],
    ["phoenix", "145843_7", "phoenix-running-array-task"],
    ["phoenix", "145851_[3-64%1]", "phoenix-pending-array-range"], // scontrolJobId strips the bracket
    ["phoenix", "145847", "phoenix-pending-plain"], // empty AllocTRES, EndTime=Unknown
    ["phoenix", "145855", "phoenix-completing"],
    ["phoenix", "145782", "phoenix-running-multinode"],
    ["phoenix", "999999", "phoenix-not-found"],
    ["nimbus", "92341", "nimbus-running-cpu-only"],
    ["nimbus", "92358", "nimbus-pending-cpu-only"],
  ];
  for (const [host, jobId, name] of detailTargets) {
    const r = await capture(name, host, () => showJob(host, jobId));
    jobIdStrings.add(jobId);
    // `raw` is dropped: it is byte-identical to `input`.
    jobDetail.push({ ...r.c, expected: { fields: r.value.fields } });
  }
  writeKind("job-detail", jobDetail);

  // ----- derived / hand-authored kinds -----
  writeKind("format-scalars", buildFormatScalars());
  writeKind("metric-stream", buildMetricStream());
  writeKind("metrics-script", buildMetricsScript());

  // Sanity: scontrolJobId is what turns a squeue `%i` into the id we captured.
  if (scontrolJobId("145851_[3-64%1]") !== "145851") {
    throw new Error("scontrolJobId no longer strips the bracketed array tail");
  }
}

main().catch((err) => {
  console.error(`export-fixtures failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
