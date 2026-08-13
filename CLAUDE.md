# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Raycast extension (TypeScript + React) that drives `squeue` / `scontrol` / `scancel` over SSH against one or more Slurm clusters. There is no agent on the cluster — everything is parsed from the textual output of stock Slurm commands. The user picks clusters from `~/.ssh/config`; the extension never edits that file.

## Commands

```bash
npm run dev          # ray develop — live-reload the extension in Raycast
npm run build        # ray build -o dist
npm run lint         # ray lint (wraps @raycast/eslint-config)
npm run fix-lint     # ray lint --fix
npm run typecheck    # tsc --noEmit
npm run publish      # npx @raycast/api@latest publish

# Demo mode: intercepts all SSH calls and serves fixtures from src/lib/demo.ts.
# Mock output still flows through the real parsers, so wire-format drift surfaces immediately.
RAYCAST_SLURM_DEMO=1 npm run dev
```

Raycast commands themselves are declared in `package.json` under `commands[]` — each entry maps to a same-named `.tsx` file in `src/` (e.g. `manage-jobs` → `src/manage-jobs.tsx`). The `mode` field controls the UI surface (`view`, `menu-bar`).

## Architecture

### SSH transport (`src/lib/ssh.ts`)

All cluster I/O goes through OpenSSH with multiplexing enabled. A single ControlMaster connection is opened once and reused for subsequent commands; this is what makes the UI feel instant and what the **Select Clusters** view actually manages.

- `ControlPath` lives under `/tmp/raycast-slurm-<uid>/ssh-%C`. **Do not move it under `~/Library/Caches` or similar** — macOS caps `sun_path` at 104 bytes, and `%C` expands to a 40-char SHA1.
- `ControlPersist` defaults to `12h` (overridable via the `controlPersist` preference). `closeMaster()` is what "logout" in **Select Clusters** invokes (`⌘⇧X`).
- Non-interactive auth uses `BatchMode=yes`; when that fails with `SshAuthError`, the UI offers `openMasterInTerminal()` which opens a real Terminal window for password / 2FA, then the user comes back to Raycast.
- `requireHostInConfig()` validates the alias against `~/.ssh/config` before any connection attempt. Positive results are memoized for the process lifetime; negative results are not, so the user can fix the config and retry without restarting Raycast.

### SSH config parsing (`src/lib/ssh-config.ts`)

Uses the `ssh-config` parser plus a manual `Include` expander (the parser doesn't follow `Include` directives). Globs are resolved with `fast-glob`, paths starting with `~/` are expanded, and `Include` recursion is cycle-safe via a `visited` set. Wildcard hosts (`*`, `?`, `!`) are skipped — only concrete aliases become selectable.

`loadConfigState()` returns a tagged union (`ok` / `missing` / `empty` / `unreadable`) so the UI can render specific copy for each failure mode rather than a generic error.

### Per-cluster fanout (`src/lib/multi.ts`)

The `fetchPerCluster(hosts, fn)` helper is the standard pattern for any command that touches multiple clusters. It:

1. Runs `fn(host)` in parallel via `Promise.allSettled`.
2. Wraps each result in `ClusterResult<T>` = `{ host, ok: true, data } | { host, ok: false, error: SshErrorInfo }`.
3. Classifies failures with `classifySshError()` so the UI can render per-cluster error rows (via `ClusterAuthRow`) alongside successful clusters.

**Never let one cluster's failure abort the others.** All views (`manage-jobs`, `all-jobs`, `node-utilization`, `menu-bar`, `resources`) follow this pattern.

### SSH error classification (`src/lib/errors.ts`)

Stderr patterns are matched to `SshErrorKind` (`auth`, `host-key`, `unknown-host`, `host-not-in-config`, `refused`, `timeout`, `network`, `remote-cmd`, `unknown`). Each kind carries a structured `{ title, message, hint, raw }`. When extending this, prefer adding a new kind over inventing new copy at the call site — the UI already knows how to render kinds (e.g. `ClusterAuthRow` triggers "open in Terminal" for `auth`).

`SshAuthError` is a subclass kept for `instanceof` checks in `select-cluster.tsx`; new error kinds should use the base `SshError` plus the discriminator.

### Slurm parsing (`src/lib/slurm.ts`)

- **Two-call pattern for AllocTRES**: `squeue -o "%i|...|%b"` only gives the requested GPU shorthand (`%b`). To get the full `AllocTRES` string we issue a second `squeue -O ALLOC_TRES_FMT` in the same SSH command (separated by `echo '---ALLOC---'`) and join the maps to the primary `%i` column. The `-O` format and the fixed-width slice offsets in `parseAllocTres` must stay in lockstep, so both derive from `ALLOC_JOBID_WIDTH` / `ALLOC_TASKID_WIDTH` / `ALLOC_TRES_FMT` (`ArrayJobID:24,ArrayTaskID:24,tres-alloc:512`); the demo's `jobToAllocRow` pads to the same widths. **Array jobs** are why the map is *not* keyed on `-O JobID`: for a RUNNING array task that field prints the task's own underlying JobID (`6644_33` → `6718`), which `%i` never exposes — so a JobID-keyed lookup misses for every running array task and falls back to `%b`, which is `N/A` on clusters that request GPUs via `--gpus=N`, silently dropping the GPU/mem tag (worst in the node drill-down, whose `-t RUNNING` alloc call has no pending-array row to lean on). Instead `parseAllocTres` reconstructs the `%i` notation from `ArrayJobID` + `ArrayTaskID`: numeric task id → `6644_33` (running, exact match), `N/A` → ArrayJobID alone (non-array), range `28-50%2` → ArrayJobID (pending). `allocForJob()` then does exact-then-suffix-stripped lookup so a pending range (`%i` = `5818_[28-50%2]`) still resolves via its base ArrayJobID; all three join sites (`listAllJobs`, `listJobs`, `joinAlloc`) go through it.
- **Pipe-delimited primary format**: `%i|%P|%j|%T|%M|%l|%D|%C|%R|%b` (jobs) and `%i|...|%u|%b` (all jobs). Adding a column changes the index in `parseJobRow` / `parseAllJobRow` — keep both in sync.
- **Node listing needs `--future`**: `listNodes` runs `scontrol show node --future --oneliner` (falling back to the plain form for pre-20.11 controllers). Without the flag slurmctld hides FUTURE-state nodes *and* cloud/dynamic nodes it has no address for (`Reason=NO NETWORK ADDRESS FOUND`) — on a cloud-provisioned cluster that can be every node, so `scontrol show node` answers "No nodes in the system" while `scontrol show partition` still reports them and squeue works. Symptom: Resources + Node Utilization render empty for one cluster while the job views are fine.
- **Node drill-down falls back off `-w`**: on those same cloud clusters `squeue -w <node>` rejects every node (`squeue: error: Invalid node name cloud-202`) even when the node has running jobs, because `-w` resolves against the controller's usable node table. `listNodeJobs` catches that specific stderr and re-runs cluster-wide `-t RUNNING` with `%N` appended to the format, matching client-side via `expandHostlist`. The fallback is error-triggered only — the cluster-wide query is heavier, so clusters where `-w` works never pay for it.
- **`tokenizeKv`** parses `Key=Value` tokens from `scontrol show node --oneliner` output. It handles quoted `Reason="..."` values and keeps the **first** occurrence of any key — duplicates are intentionally ignored.
- **`shellQuote`** is used for any user-derived value (username, jobId, file path) inserted into a remote command string. Never interpolate raw strings.

### Format helpers (`src/lib/format.ts`)

GPU counts are extracted from four different Slurm representations: `gres/gpu:<model>=N` (TRES typed), `gres/gpu=N` (TRES generic), `gres/gpu:<model>:N` (per-node gres / `squeue %b` on pending jobs, e.g. `gres/gpu:A100:4`, MIG `gres/gpu:2g.10gb:1`, untyped `gres/gpu:1`), and `gpu:<model>:N` (GRES legacy). `gpuLabelFromTres`/`gpuInfoFromTres`/`gpuCountFromTres` try them in that order — the typed `=` form first, so AllocTRES (which contains both `gres/gpu=N` and `gres/gpu:<model>=N`) surfaces the model name. The colon form matters because a pending job's GPU comes only from `%b` (AllocTRES isn't populated yet). `prettifyGpuModel` converts `rtx_pro_6000` → `Rtx Pro 6000`.

### Active-host persistence (`src/lib/ssh-config.ts`)

`getActiveHosts()` reads `activeHosts` from `LocalStorage` (JSON array). There is a **one-time legacy migration** from the old single-host `activeHost` key — it reads, persists as `[activeHost]`, and removes the legacy key. Don't add new legacy keys; if you change the storage shape again, write a new migration step here.

### React conventions

- Data fetching is `useCachedPromise` from `@raycast/utils`, keyed on a stringified version of the inputs (e.g. `usersKey = "host1=user1|host2=user2"`). The key string is the dependency the cache compares on.
- Polling is plain `setInterval` inside a `useEffect` with `revalidate()` as the tick. Intervals: 10s for jobs (`manage-jobs`, `all-jobs`), 30s for menu bar.
- Command subtitles (the tag shown in Raycast's root search) are updated via `updateCommandMetadata({ subtitle })` after each fetch — this is how the menu bar / job list show live counts without being open.

## Conventions

- **Prettier**: `printWidth: 120`, double quotes, trailing commas everywhere. Defined in `.prettierrc`.
- **TS strict mode** is on; `isolatedModules: true`, JSX is `react-jsx`. Lib is `ES2023`, target `ES2022`, module `commonjs` (Raycast runtime).
- **`raycast-env.d.ts`** is generated by `ray develop` from `package.json`'s `preferences` / `commands` — do not edit by hand; change `package.json` and let `ray` regenerate it.
