# SPEC P1a — Golden fixture exporter

Read `macos/docs/ARCHITECTURE.md` first (Parity strategy + fixture format sections are the
contract). This phase produces `fixtures/*.json` by running the REAL TypeScript parsers in demo
mode — the fixtures are only trustworthy if the actual extension code generates them.

## Paths you may create/modify

- `scripts/**` (new)
- `fixtures/**` (generated output)
- `package.json` (devDependencies + one npm script only)
- `src/lib/demo.ts` — ONE minimal addition (below). No other extension source may change.

## Approach

1. **Call-log hook in `demo.ts`**: add an exported, env-gated capture — when
   `RAYCAST_SLURM_FIXTURE_LOG=1`, `mockRunSsh` pushes `{ host, cmd, out }` onto an exported
   `mockCallLog: {host, cmd, out}[]` array before returning. A few lines, inert in normal use.
   This is what lets the exporter record the exact wire input AND the exact command string the
   lib issued, without duplicating command construction.

2. **Stubs for Raycast imports**: the lib pulls `@raycast/api` / `@raycast/utils`
   (getPreferenceValues, LocalStorage, runAppleScript, showFailureToast, Color, useCachedPromise).
   Create `scripts/stubs/raycast-api.ts` and `scripts/stubs/raycast-utils.ts` with minimal
   implementations (getPreferenceValues → `{}`, LocalStorage → in-memory Map, Color → string
   enum-like object, everything else throw-if-called). Bundle the exporter with esbuild using
   `--alias:@raycast/api=…` / `--alias:@raycast/utils=…` (add `esbuild` as a devDependency),
   then run the bundle with node. Wire it as `npm run export-fixtures`. Set
   `RAYCAST_SLURM_DEMO=1` and `RAYCAST_SLURM_FIXTURE_LOG=1` in the script's env.

3. **`scripts/export-fixtures.ts`**: for each demo host (`DEMO_HOSTS`) call the high-level lib
   functions — `listJobs(host, DEMO_USER)`, `listJobsBrief`, `listAllJobs`, `listNodes`,
   `listNodeJobs` (pick nodes that actually carry demo jobs, including at least one multi-node
   job), `listPartitionActivity` (partitions present in the demo data), `showJob` (a running
   array task, a pending array range, a plain job), and record per call: the call-log entries
   (input + cmd) and the returned value (expected). Emit one JSON file per kind exactly as the
   ARCHITECTURE fixture-format table specifies.
   - `job-detail` expected: `{ "fields": … }` only (drop `raw`).
   - `format-scalars`: enumerate inputs by harvesting every distinct `tres`/`gres` string from
     the demo data, plus hand-picked edge cases for each of the four GPU formats documented in
     the repo CLAUDE.md (typed `=`, generic `=`, colon per-node incl. MIG `2g.10gb` and untyped,
     GRES legacy), durations (`1-04:23:11`, `23:45`, `UNLIMITED`, garbage), hostlists
     (`gpu[01-02,05],cpu7`, nested-suffix, malformed range), `scontrolJobId` (all three shapes).
     Call the real TS functions for `expected`.
   - `metric-stream`: build 2–3 buffers from `mockMetricSample`-style data or hand-written
     ticks (complete ticks + one trailing incomplete tick) and run the real `parseMetricStream`.
   - `metrics-script`: base64 of `METRICS_SCRIPT` — it is not exported; export it from
     `slurm.ts`? NO — extension source beyond demo.ts is read-only. Instead capture it at the
     transport boundary: call `streamJobMetrics`? That spawns ssh — also no. Resolution: read
     `src/lib/slurm.ts` as TEXT in the exporter, extract the METRICS_SCRIPT array literal via
     the existing structure (lines between `const METRICS_SCRIPT = [` and `].join("\n")`),
     evaluate the string literals, join, base64. Brittle-but-honest is acceptable here; if the
     extraction fails, fail the export loudly rather than emitting a guess.

4. **Determinism**: sort object keys when serializing, 2-space indent, trailing newline, no
   timestamps. Running the exporter twice must produce byte-identical output (CI relies on
   `git diff --exit-code fixtures/`). If any demo fixture path is time-dependent (e.g. demo data
   deriving elapsed from Date.now()), pin it — inspect `demo.ts` and, if needed, have the
   exporter set a fixed clock via an env the demo already supports; if demo.ts genuinely
   depends on wall time, extend the call-log hook's env gate to also freeze the relevant
   computation (report this if it happens; keep the diff minimal).

## Coverage requirements (hard)

- At least one RUNNING array task, one PENDING array range (with `%N` throttle), one plain job,
  and one job whose alloc entry is empty (falls back to `%b`) across `jobs-user`/`jobs-all`.
- `nodes` includes a node with quoted `Reason="…"`, a node with `CPULoad=N/A` or missing, and
  GPU nodes with `Gres`/`GresUsed`.
- `node-jobs` includes a job spanning multiple nodes (`nodeCount > 1`).
- `partition-activity` includes a non-empty pending AND running section, with UNLIMITED
  time-limit sorting exercised.
- Every kind from the ARCHITECTURE table exists as a file, even if some have few cases.

## Acceptance

- `npm run export-fixtures` exits 0; second run produces zero `git diff` in `fixtures/`.
- Coverage requirements met (list them in your report with the case names).
- `git diff src/` shows ONLY the demo.ts call-log hook.
- `npm run build` still exits 0 (via `rtk proxy` to see the true code). No git commits.

## Report back

Fixture files + case counts, coverage checklist, the exact demo.ts diff, any deviation + why.
