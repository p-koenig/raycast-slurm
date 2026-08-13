# SPEC P1b — SlurmKit Model + Parse port (golden-tested)

Read `macos/docs/ARCHITECTURE.md` first — especially "Parity strategy" and "Semantics that MUST
survive the port". Prerequisites: P0 scaffold and P1a fixtures are on disk.

## Paths you may create/modify

- `macos/SlurmKit/Sources/SlurmKit/Model/**`
- `macos/SlurmKit/Sources/SlurmKit/Parse/**`
- `macos/SlurmKit/Tests/SlurmKitTests/**`

Everything else — including `fixtures/`, `scripts/`, `src/` — is read-only. If a fixture looks
wrong, report it; do not regenerate or hand-edit fixtures.

## Deliverables

1. **Model types** (Codable + Equatable + Sendable, CodingKeys matching the TS field names
   exactly): `Job`, `SlurmNode`, `JobDetail` (fields map), `QueueEntry`, `RunningEntry`,
   `PartitionActivity`, `NodeJob`, `MetricSample`, `GpuSample`. Optionality mirrors TS
   (`user: String?`, `cpuLoad: Double?`, `cpu/ram: Double?`). Numeric TS fields are JS numbers →
   use `Double` where TS can produce non-integers (`cpuLoad`, metric values), `Int` where TS
   values are integral by construction (`cpuTot`, `cpuAlloc`, memory MB fields, `memTotalMiB` is
   integral from nvidia-smi but flows through `Number` — check fixture values and pick the type
   that round-trips them; when in doubt `Double` with integer-tolerant decoding).

2. **Parse functions**, source-mirrored from `src/lib/` (read the TS before porting each):
   - `slurm.ts` → `SqueueParse` (job/allJob/pending/running/nodeJob row parsers,
     `splitOnSentinel`, `parseAllocTres` with the 24/24/512 fixed-width contract as shared
     constants, `allocForJob`, `joinAlloc`, partition-activity assembly incl. timeLeft sort with
     UNLIMITED sinking), `ScontrolParse` (`tokenizeKv` first-key-wins + quoted values,
     `parseNodeLine`, `scontrolJobId`), full-output entry points mirroring `listJobs` /
     `listAllJobs` / `listNodeJobs` / `listPartitionActivity` parsing (take raw stdout, return
     models — no I/O in this package).
   - `hostlist.ts` → `Hostlist.expand` (width-preserving zero-pad, bracket-aware split,
     malformed ranges skipped).
   - `format.ts` → `SlurmFormat` (every function in the fixture `format-scalars` list; port
     `stateColor`/`nodeStateColor` as semantic categories only — no UI color types in SlurmKit).
   - `metrics.ts` → `MetricStream.parse(buffer:)` returning `(samples, rest)` plus `RunStats`
     accumulate/runAvg/windowAvg/windowSeconds/gpuKey logic.
   - `shell.ts` → `shellQuote` (same regex charset, same escaping).
   - Command-string builders: a `SlurmCommands` namespace producing the exact remote command
     strings (`listJobs(user:)`, `listAllJobs()`, `nodeJobs(node:)`,
     `partitionActivity(partition:)`, `showJob(jobId:)`, `cancel(jobId:)`, `listNodes()`,
     `detectUser()`) — validated against fixture `cmd` fields. Keep `ALLOC_TRES_FMT` and the
     width constants single-sourced between builder and parser, as the TS does.

3. **Golden tests** (Swift Testing): a generic runner that loads each `fixtures/<kind>.json`
   via the P0 `TestSupport` repo-root helper, iterates cases as parameterized tests
   (`@Test(arguments:)` where practical), decodes `expected` into the model, runs the port on
   `input`, asserts `==`. For command builders, string equality against `cmd`. Failure output
   must name the fixture case.

   Fixture reality notes (P1a generated; binding):
   - `format-scalars` cases are `{ "name", "input": { "fn": "<name>", "input": <value> }, "expected" }`
     — the discriminator is nested inside `input`. 16 fns including `shellQuote`.
   - Cases may carry an optional `"note"` string — decode-tolerate and ignore it.
   - The two `*-brief` cases in `jobs-user` faithfully record demo-mode noise: the brief command
     returns the two-block body, so the TS parser also parses the `---ALLOC---` sentinel and
     fixed-width alloc rows into junk `Job`s. Your port must reproduce this exactly — it is a
     parser-tolerance vector, not a fixture bug.

4. **Direct unit tests** (non-fixture) for behavior no fixture can reach:
   - `timeLeftSeconds` sinking: partition-activity running sort must send `UNLIMITED`, `""`,
     and unparsable time-left values to the END of the list (TS `timeLeftSeconds` →
     `MAX_SAFE_INTEGER`). The demo corpus has no UNLIMITED job, so test the sort directly with
     constructed rows.
   - `MetricStream` T-timestamp fallback (invalid `T` line → current time) — assert it doesn't
     crash and produces a sane timestamp; fixtures never exercise it.

## Porting rules

- Semantics over idiom: write natural Swift, but where JS semantics leak into behavior
  (`Number("")`, falsy guards, regex nuances), replicate the behavior explicitly and add a
  one-line comment stating the constraint (e.g. `// "" and non-numeric → fallback, matching TS numOr`).
- No Foundation regex objects in hot per-row paths where simple scanning suffices — `tokenizeKv`
  should stay a character scan like the TS original.
- Public API surface: everything the App/Transport layers will need is `public`; internals stay
  internal but `@testable`-reachable.

## Acceptance

- `macos/scripts/test-slurmkit.sh` exits 0 with EVERY fixture case passing — no skipped kinds,
  no filtered cases. Report total case counts per kind. (Use the wrapper, not bare
  `swift test`: this machine is CLT-only and bare `swift test` fails with "no such module
  'Testing'" — a P0-documented environment quirk, not something to fix in Package.swift. Do
  NOT run `npm run build` — it needlessly rewrites tracked dist/ artifacts.)
- No changes outside the allowed paths. No git commits.

## Report back

Case counts per kind (all passing), any fixture you believe is wrong (with evidence), any
deviation + why.
