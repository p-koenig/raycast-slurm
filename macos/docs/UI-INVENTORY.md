# UI inventory — Raycast extension reference behavior

Produced by a code sweep of `src/*.tsx` + `src/lib/components/*.tsx` + `package.json` on
2026-07-25. This is the reference-behavior contract for SPEC-P3; file:line refs point at the
TypeScript. Where SPEC-P3 deviates (native idioms, scope cuts), SPEC-P3 wins.

## 0. Shared infrastructure (applies to every view)

**Host/session plumbing**
- `useActiveHosts()` — `src/lib/session.ts:27`. Reads `LocalStorage["activeHosts"]` (JSON string array) via `getActiveHosts` (`src/lib/ssh-config.ts:169`). Legacy migration from `"activeHost"`. In DEMO_MODE with nothing stored, defaults to `["phoenix","nimbus"]` (`ssh-config.ts:189`). Returns a stable array ref when contents unchanged.
- `useSlurmUsers(hosts)` — `session.ts:62`. Runs `whoami` per host in parallel (`detectUser`, 10 s timeout). Returns `{users, errors, isLoading}`.
- `fetchPerCluster<T>(hosts, fn)` — never throws; per-cluster ok/error union.

**Search** — `matchesQuery(haystack, query)` (`src/lib/search.ts:5`): lowercase, whitespace-split, **AND** over all terms, substring `includes`. Used only where the view disables built-in filtering.

**Error classification** — `classifySshError` (`src/lib/errors.ts:86`); kinds `auth | host-key | unknown-host | refused | timeout | network | remote-cmd | host-not-in-config | unknown`. Failure toast copy: title `"{context}: {info.title}"`, body `info.hint ?? info.message`.

**Preferences** (`package.json:13-22`) — exactly one, extension-wide: `controlPersist` ("Session Timeout", textfield, default `"12h"`), read only by the SSH layer. No view reads any preference.

**Commands manifest**: manage-jobs "My Slurm Jobs", resources "HPC Info", node-utilization "HPC Util", all-jobs "All Slurm Jobs", menu-bar "Slurm Menu Bar" (mode menu-bar, interval 1m), select-cluster "Select Clusters".

## 1. manage-jobs — "My Slurm Jobs" (`src/manage-jobs.tsx`)

**Data**: `listJobs(host, users[host])` per cluster via `fetchPerCluster` (`:58`). Gate: `ready = hosts.length > 0 && every host has a detected user`. **Poll: 10 s** while ready.

**Command metadata subtitle** (`:73-81`): `"{hosts.join(',')} — {formatCounts}"`; `formatCounts` (`:356`): first letter of state + count joined with `·`, ordered RUNNING, PENDING, COMPLETING then others; `"idle"` when empty.

**Structure**: search disabled-native (`filtering={false}`), custom search over full dataset; `ClusterFilterDropdown` (no `includeMine`); error rows first — one `ClusterAuthRow` per failing cluster, computed from **unfiltered** results (`:103`) so filters never hide failures; empty view "No jobs" / "No queued or running jobs on any active cluster." only when zero jobs, zero failures, not loading; one section per ok cluster, title = host, subtitle = `"{matches} jobs"`.

**Job row** (`:175-276`): title = jobId; subtitle = job name (char-budget-truncated via `fitSubtitleToRow`, budget 112); icon Hammer tinted `stateColor(state)`. Accessories in order: tag `partition` (secondary) → text `"{elapsed} / {timeLimit}"` → text `"{cpus} CPU"` → text `memFromTres(tres)` if present → text `gpuLabelFromTres(tres)` if present.

**Actions**: View Details (Enter) → JobDetailView **always owned**; Tail StdOut (⌘T) via `showJob().fields.StdOut` (missing → failure toast "No StdOut path") → TailView; Tail StdErr (same via StdErr); Copy Job ID (⌘.); Cancel Job (destructive, ⌃X) → confirm dialog `title:"Cancel job {id} on {host}?", message: job.name, primary "scancel"` → `cancelJob` → success toast `"Cancelled {id}"` + revalidate; error → classified toast `"Cancel {id}: …"`.

**Pagination**: PAGE_SIZE 100, search+filter on full dataset, flatten in cluster order, slice, regroup; reset on usersKey/filter/searchText change. **Search haystack**: host, jobId, partition, state, name, user, reasonOrNodeList.

**No-hosts state**: empty view "No active clusters" / "Select one or more clusters first." + action "Open Select Clusters".

**TailView** (`:287-327`): pushed detail running `tail -n 200 -F <path>` over ssh; CR/LF split via `consumeStreamChunk` (64 KB force-flush); stderr lines prefixed `[stderr] `; buffer capped at last 500 lines; kills process on unmount. Actions: Copy Path, Copy Buffered Output. **[v1.1 — not in P3 scope]**

## 2. all-jobs — "All Slurm Jobs" (`src/all-jobs.tsx`)

Near-clone of manage-jobs. Deltas: `listAllJobs(host)` (cluster-wide, has `%u` user); gate only `hosts.length > 0` (doesn't wait for whoami — users fetched solely to compute `owned` per row); no command-subtitle update; row adds a **first** accessory tag `job.user` in Blue; `owned = job.user === meUser` passed to JobDetailView (gates live metrics + log reading); same actions/shortcuts/pagination/empty states.

## 3. node-utilization — "HPC Util" (`src/node-utilization.tsx`)

**Data**: `listNodes(host)`, **poll 30 s**. Secondary: `listJobs` (my jobs) — not polled independently. `myNodeSets`: per host, expand `reasonOrNodeList` of my RUNNING jobs via `expandHostlist`.

**Structure**: custom search; `ClusterFilterDropdown` **with `includeMine`** ("My jobs only (all clusters)" → filter nodes to `myNodeSets[host]`); error rows from unfiltered results; empty view "No nodes match this filter"; sections per host, subtitle `"{n} nodes"`; pagination 100. Haystack: host, name, state, partitions, features.

**Node row** (`:173`): title = node name; subtitle = partitions joined `,`; icon Circle tinted `nodeStateColor(state)`; accessories = `nodeUtilTags(n)` + a Person icon tinted Yellow appended when the user has jobs on that node.

**`nodeUtilTags` rules** (`format.ts:388-418`) — core color logic:
1. `shortNodeState(state)` colored: down/drain/fail Red; alloc Blue; mix Purple; idle Green; reserved/maint Orange; else secondary.
2. `"cpu {load.toFixed(2)}/{tot}"` (`"cpu —/{tot}"` if null). ratio > 1.0 Red, > 0.7 Orange, else Green; null secondary.
3. `"mem {used}/{total} ({pct}%)"`, used = RealMemory − FreeMem, `formatBytesMB`. > 85% Red, else Blue.
4. GPU tag only when `gpuCountFromGres(gres) > 0`: `"gpu {alloc}/{total}"`, alloc = `gpuCountFromTres(allocTres) || gpuCountFromGres(gresUsed)`. alloc ≥ total Red, > 0 Orange, else Green.

**Actions**: Show Running Jobs (Enter) → NodeJobsView; Copy Node Name; Copy Reason (only when reason non-empty).

## 4. resources — "HPC Info" (`src/resources.tsx`)

**Data**: `listNodes(host)`, **poll 60 s**, no user detection. Built-in filtering (title/subtitle/keywords), **no pagination**, no custom empty view.

**Grouping** (`:165`): key = `[sortedPartitions, cpuTot, realMemoryMB, gres, features]`; sort gpuCount desc → memMB desc → cpuTot desc. Section subtitle `"{nodes} nodes · {shapes} shapes"`.

**Row**: title = shape (`"{gpuCount}× {MODEL} · {cpu}c · {mem}"` or `"{cpu}c · {mem}"`); subtitle = partitions or "(no partition)"; icon ComputerChip/HardDrive Blue; accessory tag `"{count}×"` Blue. `gpuModelFromGres`: parse `gpu:<model>:<n>`, else guess from features list [a100,h100,v100,a40,rtx3090,rtx2080ti], else "gpu".

**Actions**: View Details → GroupDetail (markdown: title, cluster, partitions, CPUs/node, RAM/node, GRES, features, node list); Copy Node Names; Copy Shape Description.

## 5. menu-bar — "Slurm Menu Bar" (`src/menu-bar.tsx`)

**Data**: `listJobsBrief` (cheap single-squeue variant, tres never read). Refresh: 1 m background + 20 s while open.

**Collapsed item**:
- No active hosts: icon Plug secondary, title "Slurm", tooltip "No active clusters"; dropdown = single "Select Clusters…" item.
- Otherwise: icon CircleFilled tinted `pickTint`, title `formatTitle(counts)`; `formatTitle` (`:151`): `"idle"` if R+P+CG zero, else `["R{n}","P{n}","CG{n}"]` omitting zeros, joined `·`. `pickTint` (`:163`) strict order: any cluster error → Red; FAILED/TIMEOUT present → Red; RUNNING → Green; PENDING → Yellow; else secondary.

**Dropdown**: one section per cluster (incl. failing): ok → "Summary — {formatTitle}" + up to 5 jobs per state subsection (RUNNING/PENDING/COMPLETING, omitted if zero, header `"{Label} ({total})"`), job item title `"  {jobId} — {name}"`, subtitle `"{partition} · {elapsed}/{timeLimit}"` → opens manage-jobs. error → title/hint item (LockUnlocked Yellow for auth, ExclamationMark Red otherwise) + "Reauthenticate in Terminal"/"Open in Terminal" action. Footer: Open My Jobs, Select Clusters…, Refresh.

## 6. select-cluster — "Select Clusters" (`src/select-cluster.tsx`)

**Data**: `listHosts()` (ssh-config parse + Include expansion; skips `* ? !` aliases; sorted), `getActiveHosts()`, per-row `isMasterUp` (5 s local probe). No polling.

**Config-error screens** replace the list: missing → "No ~/.ssh/config" / "Create {path} with at least one Host entry to start."; unreadable → reason; empty → "No hosts in ~/.ssh/config". All with a Reload action.

**Structure**: sections `Stale ({n})` (persisted-active names no longer in config) → `Active ({n})` → `Available`; active hosts first in persisted order, then alphabetical.

**Stale row**: "No longer in ~/.ssh/config", accessory tag Stale Orange; action Remove from Active List (destructive) → toast.

**Cluster row**: icon CheckCircle Green if active else Circle secondary; accessories: tag "Active" Green (if active) → green Dot with tooltip "Connection running" (if masterUp) → tag user (if set) → text hostName (always).

**Actions**: (1) Enter toggles — active → deselect, keep connection, toast "Deselected {host}" / "Connection kept running"; inactive → add + if masterUp toast "Activated"; else animated "Connecting…" → `openMaster` → success "Connected: {host}" / SshAuthError → success-style toast "Auth required — opening Terminal for {host}" + `openMasterInTerminal` / other error → classified toast. (2) Open in Terminal (⌘⇧T) → interactive master + activate. (3) Close Connection & Deselect (⌘⇧X, destructive) → `closeMaster` + remove + toast "Connection closed". (4) Reload SSH Config (⌘R). (5) Copy Host Alias (⌘.). No confirmation dialogs in this view.

## 7. ClusterAuthRow (shared error row)

- title = `info.title`; subtitle = `info.hint ?? info.message`.
- Icon by kind: auth LockUnlocked/Yellow; host-key Warning/Red; host-not-in-config QuestionMarkCircle/Orange; unknown-host, refused XMarkCircle/Red; timeout Clock/Orange; network WifiDisabled/Red; remote-cmd, unknown ExclamationMark/Red.
- Accessory: auth → tag "Reauth ⌘⇧R" Yellow; else tag "Retry ⌘R" secondary.
- Actions: auth → "Reauthenticate {host}" (⌘⇧R, Terminal) then refetch; non-auth → Retry (⌘R, refetch only) + "Open Terminal for {host}" (⌘⇧T); always → Open Select Clusters, Copy Error Details (`info.raw`).

## 8. ClusterFilter (shared dropdown)

Values: `all` / `mine` / `cluster:{host}` / `cluster:{host}:{partition}`. Layout: "All clusters · all partitions"; optional "My jobs only (all clusters)"; then per-cluster section: "All on {host}" + one item per partition (sorted). Failing clusters still get a section header. Selecting a cluster **drops other clusters' items entirely** — which is why error rows are computed from unfiltered results.

## 9. JobDetailView (shared)

**Data**: `showJob(host, jobId)` (`scontrol show job`, array-bracket tail stripped) fetched **once**, not polled.

**Layout**: 5-pane rail with detail panes: Info, Schedule, Utilization, Output (stdout), Error (stderr). First three carry no actions.

**TRES resolution rule** (`:95`): `firstMeaningfulTres(AllocTRES, ReqTRES, TRES)` skipping `""`, `"(null)"`, `"N/A"` — a pending job's AllocTRES is the truthy string `"(null)"`, which would defeat plain `||`.

**Info pane**: markdown `# Job {id}` + bold name; metadata: User (`UserId` with `(uid)` stripped); GPUs → green tag `"{count} × {PrettyModel}"` (or `"{count} GPU"`) if `gpuInfoFromTres` matched else "GPUs / none"; RAM (`prettifyMem`, "336G" → "336 GB") or "—"; CPUs = NumCPUs or "—".

**Schedule pane**: PENDING → Status tag Yellow, Reason (`shortReason`, "None" → "—"), Est. Start (`"{shortDateTime} · {relative}"` or "not yet estimated"), Partition. Else: Status tag tinted `stateColor`; Progress (running only, `progressBar(progress,18)` + pct); Elapsed; Remaining (running + limited only); Started; "Ends (est.)" when running else "Ended"; Time Limit or "unlimited". Driven by `buildJobTime` (`format.ts:177`) + 1 Hz clock **only while RUNNING**.

**Utilization pane gates in order**: no fields → loading; not RUNNING → "Live metrics are only available while the job is **running**."; not owned → "Live metrics are only available for **your own** jobs."; else live view.

**LiveUtilization**: `streamJobMetrics` (srun --overlap, 1 tick/s), parsed by `parseMetricStream`; stderr → error state with fenced message; sample retention cap **300**; run averages from unbounded `RunStats` accumulator (cap never truncates them). Rows: Status RUNNING tag; per GPU (latest tick with GPUs): `"GPU {i}"` = `"{PrettyName} · {N} GB"`, then Utilization + VRAM rows; no GPUs → "GPUs / none allocated"; then CPU + RAM rows. **`metricRow`** = two pills: `"run {pct}%"` (session avg) and `"{winSec}s {pct}%"` (trailing window, winSec = min(30, secs since open)); "—" when null. **`utilColor`**: null secondary, ≥ 90 Red, ≥ 70 Orange, else Green — each pill independently.

**Demo mode**: no process spawned; `mockMetricSample` pushed at 1 Hz; returns null (perpetual loading) for jobs not owned by demo user or not RUNNING.

**Log panes** (stdout/stderr): path = `firstMeaningfulTres(fields.StdOut|StdErr)`; `canRead = owned && path`; fetch `readLogTail(host, path, 500)`; **poll 10 s** while canRead. States in order: no fields → loading; not owned → "Log files can only be read for **your own** jobs."; no path → "No output/error file is set…"; error → fenced; else fenced tail, empty → "(empty — nothing written yet)". Actions conditional: Copy Output (canRead && tail), Copy File Path (path), Refresh (canRead).

## 10. NodeJobsView (per-node drill-down)

**Data**: `listNodeJobs(host, node)` — **poll 10 s** (faster than parent's 30 s). Errors surface only via the error row (default toast suppressed).

**Structure**: Section "Node" repeats the parent node row verbatim (same chips) with Refresh + copy actions; Section "Running Jobs" subtitle `"{n} jobs · {m} users"` (singularized), omitted when empty; empty row "No running jobs" / "Nothing is allocated on this node right now.". **Sort** `sortByFootprint`: GPU count desc → CPU desc → jobId — biggest consumer first, explaining the node's `gpu x/y` chip top-down.

**Job row**: title jobId; subtitle name; icon Hammer green; accessories: tag user — **Yellow when owned, Blue otherwise** → `"{elapsed} / {timeLimit}"` → `"{cpus} CPU"` → mem → GPU label → **multi-node caveat tag**: when `Number(nodeCount) > 1`, secondary tag `"{nodeCount} nodes"` — AllocTRES is job-wide, so figures cover the whole allocation, not this node's share (`slurm.ts:330-337`). **This flag must survive into the native app.** Actions: View Details (owned computed), Copy Job ID (⌘.), Copy User.

## 11. Navigation graph

```
root
├─ my-jobs ──► JobDetail (owned=true); TailView [v1.1]
├─ all-jobs ─► JobDetail (owned = user match); TailView [v1.1]
├─ nodes ────► NodeJobsView ──► JobDetail (owned computed)
├─ info ─────► GroupDetail
├─ select-cluster (leaf)
└─ menu-bar label (opens the popover)
```
Cross-jumps (Raycast `launchCommand`) become in-app tab switches.

## 12. Cross-cutting state rules

**Polling**: my-jobs 10 s; all-jobs 10 s; nodes 30 s; info 60 s; menu-bar 20 s open / 1 m background; NodeJobsView 10 s; JobDetail log panes 10 s; Schedule 1 Hz (running only); LiveUtilization 1 Hz. JobDetail's scontrol fetch is one-shot.

**Job state colors** (`format.ts:6-21`): RUNNING Green, PENDING Yellow, COMPLETING Purple, COMPLETED Blue, CANCELLED secondary, FAILED Red, TIMEOUT Red, PREEMPTED Orange, SUSPENDED Orange, CONFIGURING Yellow, unknown secondary.

**Pagination** exists only to protect the Raycast worker from OOM (my-jobs/all-jobs/nodes, page 100).

**Search ownership**: my-jobs/all-jobs/nodes search the full dataset with `matchesQuery`; info/select-cluster/NodeJobsView use built-in filtering.

**Error rows always from unfiltered results.**

**Demo mode**: marker file `~/.raycast-slurm-demo` or env; demo hosts phoenix/nimbus, user r.shaw; 220 ms artificial delay for realistic loading states; `isMasterUp` always true; master/terminal ops no-op; mock data flows through the real parsers.
