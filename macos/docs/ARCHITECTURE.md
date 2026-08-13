# SlurmBar — native macOS menubar app (codename)

Architecture owner: Fable 5. Implementation: Opus 5 agents working phase-by-phase against the
SPEC-*.md files in this directory. This document is the source of truth for structure and
semantics; specs reference it rather than restating it.

## Decisions of record

- **v1 scope**: multi-cluster job list, job detail, cancel, node utilization + node drill-down,
  live menubar counts, job-finished notifications, live GPU/CPU/RAM metrics with Swift Charts.
  Log tail view is v1.1. Mac App Store: never (sandbox is incompatible with ControlMaster + ~/.ssh/config).
- **Repo**: monorepo. The Raycast extension stays at repo root, untouched except where a spec
  explicitly says otherwise (currently: one env-gated call-log hook in `src/lib/demo.ts`).
- **macOS floor**: 14.0 (Sonoma). `@Observable` view models, `MenuBarExtra(.window)`, Swift Charts.
- **Signing**: deferred. Local dev builds are ad-hoc signed (`CODE_SIGN_IDENTITY=-`). Developer ID +
  notarization + Sparkle + Homebrew cask land in Phase 5 once the paid program membership exists.
- **Naming**: deferred. Codename `SlurmBar`, bundle id placeholder `local.slurmbar.dev`. Both are
  renamed before any public release; nothing may depend on them semantically.

## Repository layout

```
raycast-slurm/
├─ src/                        # Raycast extension (TypeScript) — the reference implementation
├─ scripts/export-fixtures.ts  # runs the TS parsers over demo fixtures → fixtures/*.json
├─ fixtures/                   # generated golden test vectors — the cross-language contract
└─ macos/
   ├─ docs/                    # this file + phase specs
   ├─ project.yml              # XcodeGen spec; generated .xcodeproj is gitignored
   ├─ SlurmKit/                # SPM package, zero UI dependencies, builds with `swift test` alone
   │  ├─ Package.swift         # platforms: [.macOS(.v14)], swift-tools 6.0+
   │  ├─ Sources/SlurmKit/
   │  │  ├─ Model/             # Job, SlurmNode, JobDetail, QueueEntry, RunningEntry,
   │  │  │                     # PartitionActivity, NodeJob, MetricSample, GpuSample,
   │  │  │                     # ClusterResult, SshErrorKind, SshErrorInfo
   │  │  ├─ Parse/             # parsers + format helpers (pure functions)
   │  │  ├─ SshConfig/         # ~/.ssh/config parser with Include expansion
   │  │  ├─ Transport/         # SshTransport protocol, OpenSshTransport actor, SlurmClient
   │  │  └─ Demo/              # DemoTransport serving fixtures through the real parsers
   │  └─ Tests/SlurmKitTests/  # golden fixture tests (Swift Testing, @Test macros)
   └─ App/                     # SwiftUI app target (needs full Xcode)
      ├─ SlurmBarApp.swift     # MenuBarExtra scene, .menuBarExtraStyle(.window)
      ├─ ViewModels/           # @Observable, @MainActor
      ├─ Views/                # JobList, JobDetail, NodeGrid, NodeJobs, MetricsCharts,
      │                        # ClusterPicker, Settings
      └─ Resources/
```

## Parity strategy (the load-bearing idea)

The TS extension is the reference implementation. Its parsers encode years of wire-format
learning (AllocTRES array-job join, four GPU string formats, KISSKI quirks). The Swift port is
kept honest mechanically, not by review:

1. `scripts/export-fixtures.ts` runs the *actual TS code* in demo mode over the `demo.ts`
   corpus and emits `fixtures/*.json`: raw wire input + the TS-parsed result + the exact remote
   command string the TS lib issued.
2. Swift golden tests feed each `input` through the ported parser, decode `expected` into the
   same Codable model, and require `==`. Comparison is on decoded values, never on JSON bytes
   (avoids Double formatting noise).
3. Swift tests also assert that `SlurmClient` builds a byte-identical remote command string for
   each captured `cmd` — command construction is part of the contract, not just parsing.
4. CI re-runs the exporter and fails on `git diff fixtures/` — fixtures can never go stale
   against the TS side.

### Fixture file format

One file per kind, `fixtures/<kind>.json`:

```json
{
  "version": 1,
  "kind": "jobs-user",
  "cases": [
    { "name": "kisski-running-array", "host": "demo-kisski",
      "cmd": "squeue -h -u r.shaw -o '…'; echo '---ALLOC---'; squeue -h -u r.shaw -O '…'",
      "input": "<raw stdout incl. sentinel>",
      "expected": [ { "jobId": "6644_33", "partition": "gpu", "…": "…" } ] }
  ]
}
```

Kinds (expected shape = TS type serialized with its exact camelCase field names; TS
`null` → JSON `null` → Swift `Optional`):

| kind | input | expected |
|---|---|---|
| `jobs-user` | listJobs stdout (primary + `---ALLOC---` block) | `Job[]` (no `user`) |
| `jobs-all` | listAllJobs stdout | `Job[]` (with `user`) |
| `node-jobs` | listNodeJobs stdout | `NodeJob[]` |
| `partition-activity` | 4-section stdout (`---PALLOC---`/`---RUN---`/`---RALLOC---`) | `PartitionActivity` |
| `nodes` | `scontrol show node --oneliner` stdout | `SlurmNode[]` |
| `job-detail` | `scontrol show job` stdout | `{ "fields": {…} }` (omit `raw` — it equals input) |
| `format-scalars` | per-case `{ "fn": "<name>", "input": … }` | fn-specific JSON |
| `metric-stream` | raw streamer buffer | `{ "samples": [...], "rest": "…" }` |
| `metrics-script` | — | `{ "b64": "…" }` of METRICS_SCRIPT (Phase 4 byte-parity) |

`format-scalars` covers: `parseSlurmDurationSeconds`, `formatSlurmDuration`,
`formatDurationSeconds`, `gpuCountFromGres`, `gpuCountFromTres`, `memFromTres`,
`gpuLabelFromTres`, `gpuInfoFromTres`, `prettifyGpuModel`, `shortNodeState`, `shortReason`,
`formatBytesMB`, `formatPercent`, `expandHostlist`, `scontrolJobId`.

### Semantics that MUST survive the port (source: src/lib/*.ts)

- **AllocTRES join** (`slurm.ts:40-70`): fixed-width slicing at 24/24 char offsets derived from
  `ALLOC_TRES_FMT`; key reconstruction (numeric taskId → `base_task`, `N/A` → base, range → base);
  `allocForJob` exact-then-suffix-stripped lookup; empty alloc entries leave `%b` in place.
- **JS `Number` semantics** in `parseNodeLine`/`numOr`: `Number("") === 0` but `numOr` guards
  falsy first → fallback; `"N/A"` CPULoad → `nil`; non-finite → fallback. Port behavior, not
  the idiom — write explicit Swift, verified by fixtures.
- **`tokenizeKv`** (`slurm.ts:426`): quoted `Reason="…"` values; bare tokens skipped; **first**
  occurrence of a key wins.
- **`expandHostlist`** (`hostlist.ts`): zero-padded range expansion preserving the *start* token's
  width (`gpu[01-02]` → `gpu01,gpu02`); top-level comma split ignores commas inside `[...]`;
  malformed ranges are silently skipped.
- **`scontrolJobId`** (`slurm.ts:371`): strip `_[…` tail only; running tasks/plain ids pass through.
- **`splitOnSentinel`**: sentinel absent → `(whole, "")`.
- **`shellQuote`** (`shell.ts`): safe-charset passthrough regex, `''` for empty, `'\''` escaping.
- **Metric stream** (`metrics.ts:30`): parse up to last `E` line, remainder is carried; GPU line
  dropped unless `idx`/`util` finite and `total > 0`; `cpu` `"-"` → `nil`; gpus sorted by index
  per tick; `T` timestamp fallback to now (fixtures never exercise the fallback).
- **Benign stderr stripping + error kinds** (`errors.ts`): identical regex set, identical
  `SshErrorKind` values, first-line truncation at 200 chars.
- **LC_ALL=C / LANG=C** on every ssh spawn (`ssh.ts:60` — see the setlocale incident).
- **ControlPath** `/tmp/raycast-slurm-<uid>/ssh-%C` (mode 0700 dir) — **identical to the
  extension's**, so app and extension share one multiplexed master per cluster. Never relocate
  (104-byte sun_path cap).

## Transport design (Phase 2)

```swift
protocol SshTransport: Sendable {
  func run(host: String, command: String, timeout: Duration) async throws -> String
  func spawnStream(host: String, command: String) -> ...  // raw chunks; MetricStream owns framing
}
```

(As built in P2: the host model is `SshHost` — `Foundation.Host` would shadow — and
`ClusterResult` lives in `Transport/` beside `SshErrorInfo`, not in `Model/`.)

- `OpenSshTransport`: spawns `/usr/bin/ssh` via `Process`; flags mirror `ssh.ts` exactly
  (`ControlMaster=auto`, shared ControlPath, `ControlPersist` from settings default `12h`,
  `ServerAliveInterval=30`, `ConnectTimeout=10`, `BatchMode=yes`). Master lifecycle
  (`isMasterUp` via `-O check`, `openMaster -fN`, `closeMaster -O exit`) serialized per host by
  an actor. Errors classified into `SshErrorInfo` (same kinds/patterns as `errors.ts`).
- 2FA fallback: build the interactive command (no BatchMode) and open Terminal via
  `NSWorkspace`/`NSAppleScript` — mirrors `openMasterInTerminal`.
- Host gate: `requireHostInConfig` semantics from `ssh.ts:69` — positive memoization only,
  demo hosts bypass, `-O check` skips the gate (documented perf reason).
- `SlurmClient` (parse-layer consumer): builds the exact command strings from `slurm.ts`
  (`listJobs`, `listJobsBrief`, `listAllJobs`, `listPartitionActivity`, `listNodeJobs`,
  `showJob`, `cancelJob`, `listNodes`, `detectUser`, `readLogTail` [v1.1], `streamJobMetrics`)
  and runs outputs through Parse. Command builders are golden-tested against fixture `cmd`.
- Fanout: `fetchPerCluster` as a `TaskGroup` returning `[ClusterResult<T>]`; one cluster's
  failure never aborts another (mirrors `multi.ts`).
- `DemoTransport`: implements `SshTransport` by serving fixture inputs keyed by command string;
  activated by `SLURMBAR_DEMO=1` env or a hidden UserDefault. Demo mode must flow through the
  real parsers, exactly like the extension's demo mode.

## App design (Phase 3)

- `MenuBarExtra` with `.menuBarExtraStyle(.window)`; label is a live `Text` with running/pending
  counts across active clusters (mirrors the extension's `updateCommandMetadata` subtitle).
- `@Observable @MainActor` stores: `ClusterStore` (active hosts, per-host connection state),
  `JobsStore` (per-cluster jobs + poll loop), `NodesStore`. Polling: 10 s while the popover is
  open, 30 s label-only when closed; timers suspend when the screen sleeps.
- Views: JobList (grouped per cluster, per-cluster error rows with kind-specific copy/actions),
  JobDetail (scontrol fields + metrics charts), NodeGrid (+ per-node drill-down = `listNodeJobs`
  with the multi-node AllocTRES caveat flag), ClusterPicker (reads ~/.ssh/config via
  SlurmKit/SshConfig; connect = openMaster, logout = closeMaster, 2FA via Terminal), Settings
  (ControlPersist, poll intervals, notification toggles).
- Active hosts persisted in `UserDefaults` (fresh store; no migration from Raycast LocalStorage —
  conscious decision, the extension keeps its own).
- Notifications (Phase 4): diff job states between polls; fire `UserNotifications` on
  RUNNING→terminal transitions with job name + state; deep-link opens the popover.
- State colors: `Parse` exposes semantic state → `JobStateCategory`; mapping to SwiftUI `Color`
  lives in the App layer (the TS `Color` import is the only UI leak in `format.ts` — do not
  port it into SlurmKit).

## Metrics (Phase 4)

Port `METRICS_SCRIPT` byte-for-byte (fixture `metrics-script` asserts the base64 matches),
ship it base64 through `srun --jobid=<id> --overlap -n1 bash -c '…'` exactly as
`streamJobMetrics` does. Stream parsing via `Parse.MetricStream` with the carried-remainder
contract. Buffer caps and CR handling follow the tailview-cr-buffer-leak lessons: cap the
accumulated buffer, never let a single "line" grow unbounded. Charts: Swift Charts sparklines
(GPU util %, GPU mem %, CPU %, RAM %) + windowed/run averages via ported `RunStats` logic.

## Testing & CI

- `swift test` in `macos/SlurmKit` runs with Command Line Tools alone — no Xcode needed until
  the App target (Phase 3). Tests locate `fixtures/` via `#filePath`-relative navigation to the
  repo root (no SPM resource copying, no symlinks).
- Transport tests use a stub `ssh` executable (shell script fixture) injected via a
  binary-path override on `OpenSshTransport`.
- GitHub Actions (`.github/workflows/macos-app.yml`): job A on ubuntu — `npm ci`, run the
  fixture exporter, `git diff --exit-code fixtures/`; job B on macos-15 — `swift test` in
  `macos/SlurmKit` (Phase 3 adds `xcodegen && xcodebuild build` for the app target). The
  workflow does not gate on the extension's own lint/build — that is the extension's concern.

## Phases and gates

| Phase | Deliverable | Gate |
|---|---|---|
| P0 scaffold | layout, Package.swift, project.yml, CI, `ray build` compatibility check | extension still builds; `swift test` (empty) green |
| P1a fixtures | exporter + `fixtures/*.json` | exporter deterministic (two runs, zero diff); fixtures cover every kind incl. array-job cases |
| P1b parsers | Model + Parse port + golden tests | 100% fixture cases pass via `swift test` |
| P2 transport | SshConfig, Transport, SlurmClient, fanout | stub-ssh unit tests green; manual smoke on both real clusters |
| P3 UI | MenuBarExtra app, all views, settings, demo mode | side-by-side demo-mode parity walkthrough vs the extension |
| P4 metrics+notif | streamer, charts, notifications | live run on KISSKI/DWS |
| P5 release | signing, notarize, Sparkle, cask, README | blocked on Developer Program enrollment |

## Rules for implementing agents

- Do **not** `git commit` — leave all changes in the working tree for review.
- Touch only the paths your spec lists. The extension source is read-only except where a spec
  explicitly grants an edit.
- Verify commands by real exit codes; if output looks like a success banner but behavior says
  otherwise, re-run via `rtk proxy <cmd>` (the RTK hook can mask failures).
- Deviations from spec are allowed only with a written note in your final report explaining why.
