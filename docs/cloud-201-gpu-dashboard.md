# cloud-201: hidden nodes + the "GPU Cluster" dashboard

Session notes, 2026-08-03. Two fixes landed; one feature is **parked** pending server-side work.

---

## Part 1 — shipped: cloud-201 showed no partitions in Info / Utilization

### Root cause

cloud-201 (`ClusterName=digit-genai`, Slurm 25.11.3) hides its compute nodes from
`scontrol show node`. All four carry:

```
Reason=NO NETWORK ADDRESS FOUND [slurm@2026-08-03T10:39:09]
```

and one (`cloud-203`) is additionally `State=FUTURE`. `scontrol show node` silently omits
FUTURE-state nodes and cloud/dynamic nodes it can't resolve an address for, so the login node
answers `No nodes in the system` — while `scontrol show partition` still reports
`Nodes=cloud-[202-205]`, `TotalNodes=4` and `squeue` is unaffected. Hence: job views fine,
Info + Utilization blank. Not a permissions issue (`PrivateData=none`).

Partitions in both views are derived per-node from `Partitions=`, so zero nodes ⇒ zero partitions.

### Fix — `src/lib/slurm.ts`, `listNodes` (`SHOW_NODES_CMD`)

```
scontrol show node --future --oneliner 2>/dev/null || scontrol show node --oneliner
```

`--future` includes them; the records are complete (CPUTot / RealMemory / Gres / Partitions /
CfgTRES / AllocTRES) so everything downstream parses unchanged. The flag exists since Slurm
20.11; the `||` covers older controllers in one round trip.

Verified: cloud-201 0 → 4 nodes; KISSKI (Slurm 26.05.1) 1679 → 1679, i.e. no phantom nodes.

## Part 2 — shipped: `squeue: error: Invalid node name cloud-203`

Same root cause, second symptom. `squeue -w <node>` resolves against the controller's *usable*
node table, so on cloud-201 the Utilization → Node drill-down failed for **every** node, including
`cloud-202`, which plainly has running jobs.

### Fix — `src/lib/slurm.ts`, `listNodeJobs`

`-w` stays primary. On a failure whose stderr matches `Invalid node name` (`isInvalidNodeName`
against the classified `SshError`), fall back to `listNodeJobsByNodeList`: cluster-wide
`squeue -t RUNNING` with `%N` appended to the format, filtered client-side via `expandHostlist`.
Error-triggered only — the cluster-wide query is the heavy one, and clusters where `-w` works
never pay for it.

Both quirks are documented in `CLAUDE.md` under "Slurm parsing".

---

## Part 3 — PARKED: all-user GPU utilization from the cluster dashboard

### The service

`https://cloud-201.rz.tu-clausthal.de` — a custom "GPU Cluster" web app (nginx 1.31.2 on
139.174.16.201, i.e. cloud-201 itself). Pages: Nodes / Running jobs / Queue / Statistics.
`static/app.js` fetches `` `/api/${page}` `` and nothing else. **No auth.** Exactly four endpoints;
everything else 404s (probed: `/api`, `/api/summary`, `/api/gpus`, `/api/history`,
`/api/node/<name>`, `/api/jobs/<id>`, `/api/health`, `/metrics`).

| Endpoint | Contents |
|---|---|
| `/api/nodes` | **the one we want** — per node, per GPU: `{index, util, mem_used_mib, mem_total_mib, temp_c, power_w, user, job_id, missing}`; node-level `name, state, partitions[], gpu_model, cpus_alloc, cpus_total, cpu_load, mem_alloc_mib, mem_total_mib, reachable` |
| `/api/jobs` | running jobs; keys: `job_id, name, user, account, partition, state, cpus, mem_mib, gpus, gpu_type, time_limit_min, submit_time, eligible_time, array_job_id, array_task_id, array_task_string, nodes, start_time, gpu_alloc` — `gpu_alloc` is `{"cloud-204": [2]}`, i.e. which GPU **indices** on which node |
| `/api/queue` | pending jobs + `reason`, `priority`, `node_count` |
| `/api/statistics` | `windows` (24h / 7d / 30d): `avg_gpus_allocated, avg_job_wait_sec, started_jobs, avg_vram_used_mib, avg_vram_used_pct, avg_gpu_util_pct, avg_pending_jobs, active_users, samples`; plus `weekdays`, `coverage_start` |

Per-GPU `temp_c` / `power_w` are one-minute peaks (per the UI's own tooltip).

### Why it's parked

`/api/nodes` currently returns `{"nodes": [], "summary": {"gpus_total": 0, "avg_util": null, …}}`
— it enumerates nodes from Slurm and so hits **the same hidden-node problem as Part 1**. Its
background sampler is independent and still running (`samples` 8614 → 8618 over 45 s;
`avg_gpu_util_pct` 26.4 % over 24 h), so only the live view is affected. Server side is under
active development, so the shapes above may move.

### When picking this back up

1. Re-probe: `ssh cloud-201 'curl -sk https://cloud-201.rz.tu-clausthal.de/api/nodes'` —
   if `nodes[]` is populated, the blocker is gone.
2. Re-verify the key names in the table above against `static/app.js` (`renderNodes`), which is
   the de-facto schema doc.
3. Check whether `/api/nodes` recovered on its own or whether the RZ fixed
   `NO NETWORK ADDRESS FOUND` — if the latter, our `--future` fix stays useful anyway.

### Proposed approach (not implemented, not yet agreed)

- **Transport**: `curl -sS --max-time 8` over the existing multiplexed SSH connection, like every
  other cluster call. (The API also answers directly from the Mac — 200 — but SSH means the
  feature works wherever the rest of the extension does, with no new network assumption.)
- **Scoping**: feature-detect, don't hardcode the alias. One probe per host per process, memoized
  like `requireHostInConfig`'s `knownHosts`; incapable hosts are never retried that session.
- **Boundary**: new `src/lib/gpu-dashboard.ts`, `fetchGpuUtil(host) → { byNode, byJob } | null`.
  `null` = no dashboard = render exactly what we render today. Every parse assumption about a
  service we don't control lives in this one file.
- **The join**: `/api/nodes` `job_id` is a plain integer; our job lists key on squeue `%i`
  notation, which disagrees for running array tasks — same trap as the AllocTRES join.
  `/api/jobs` carries `array_job_id` / `array_task_id`, so build the numeric → `%i` translation
  from there and reuse the existing convention.
- **Aggregation**: per job, mean util across its GPUs, VRAM summed → `4×h200 · 87% · 41/94 GiB`.
- **Surfaces**, strongest first: Node Utilization node rows (per-GPU meters) → node drill-down job
  rows (all users) → job detail. All Jobs / Manage Jobs left out unless wanted — highest traffic,
  and it adds a fetch to the 10 s poll.
- **Existing `srun --overlap` streamer**: keep. It's the only path on KISSKI/DWS. Prefer dashboard
  numbers where both exist; don't rip anything out.
- **Demo mode**: fixture for the new curl command so the parser stays exercised under
  `RAYCAST_SLURM_DEMO=1`.
- **Failure modes**: no dashboard / `nodes: []` / malformed JSON all degrade to today's behavior.

### Open decisions

1. **Data source.** `/api/nodes` only (clean, supported, blank until the RZ fixes node
   addressing) — or `/api/nodes` with a fallback that scrapes the GPU exporters directly and does
   the attribution join itself (works today and through this class of outage, but duplicates their
   logic).
   Exporter details, if that route is taken: `nvidia_gpu_exporter` on `http://<node>:9835/metrics`,
   confirmed 200 from the login node for cloud-202/204/205. Metrics are keyed by GPU **uuid**;
   `nvidia_smi_index{uuid=…}` maps uuid → index, which is what `gpu_alloc` uses.
   `nvidia_smi_utilization_gpu_ratio`, `nvidia_smi_memory_used_bytes`.
2. **Surfaces.** Which of the four above.
