# SPEC P3 — SwiftUI app: MenuBarExtra, views, stores, settings, demo mode

Read in order: `ARCHITECTURE.md` (App design), `UI-INVENTORY.md` (reference behavior — the
contract for copy, colors, gates, and state rules), this file (native translation decisions —
where it deviates from the inventory, this file wins). Prerequisites: P0–P2 green.

**Machine prerequisite: full Xcode installed** (`xcodebuild -version` succeeds). If it is not,
STOP immediately and report — do not attempt workarounds.

## Paths you may create/modify

- `macos/App/**`
- `macos/project.yml` (extend, don't rewrite: resources, Info.plist keys, entitlements)
- `macos/SlurmKit/Sources/SlurmKit/Parse/JobTime.swift` (NEW — see §Ports) and NEW test files
  under `macos/SlurmKit/Tests/SlurmKitTests/`
- `macos/scripts/**` (build helper additions)
- `.github/workflows/macos-app.yml` (add app build job)

Everything else read-only. Never `git commit`/`git add`. Never contact a real host — all
interactive verification runs in demo mode.

## Native translation decisions (binding)

1. **One window model.** Raycast's six commands collapse into: the `MenuBarExtra(.window)`
   popover (~440×580) with a segmented top-level switcher — **My Jobs / All Jobs / Nodes /
   Info** — plus a toolbar row: cluster-filter menu, search field, Clusters button (opens the
   Select Clusters view as a pushed screen), Refresh, Settings (gear → `Settings` scene).
   Each tab hosts a `NavigationStack` for drill-downs (JobDetail, NodeJobs, GroupDetail).
   Raycast `launchCommand` jumps become tab switches + stack pushes.
2. **Menubar label** = `formatTitle` counts (`"R3·P2"` / `"idle"` / `"Slurm"` when no hosts)
   next to a `circle.fill` symbol. Try `pickTint` as the symbol's foregroundStyle; macOS may
   render menubar content as template — if color is stripped (verify visually in demo mode),
   encode severity by symbol instead: `exclamationmark.circle.fill` (error/red states),
   `circle.fill` (running), `circle.dotted` (idle/none). Report which path shipped.
3. **No pagination.** SwiftUI `List` is lazy; render all rows. Keep: full-dataset `matchesQuery`
   search semantics, cluster-order flattening, per-section match counts, error rows from
   unfiltered results.
4. **Toasts → transient in-popover banner** (bottom overlay, auto-dismiss 3 s, tap to dismiss),
   reusing the inventory's exact copy. Destructive confirm (cancel job) →
   `confirmationDialog` with the inventory's title/message/button.
5. **Keyboard**: popover supports arrow-key list navigation + Return (default action), ⌘F
   focuses search, and the inventory's shortcuts where feasible (⌘. copy id, ⌃X cancel,
   ⌘⇧R reauth, ⌘R refresh/reload, ⌘⇧T terminal, ⌘⇧X close connection). Context menus
   (right-click) carry every row action.
6. **Terminal fallback without Apple Events**: write a temp executable `.command` file
   containing `interactiveOpenMasterCmd(host)` (SlurmKit) and `NSWorkspace.open` it with
   Terminal. No `NSAppleEventsUsageDescription`, no automation prompt. Delete stale temp files
   on launch.
7. **JobDetail** = pushed screen with a segmented sub-switcher: **Info / Schedule / Utilization /
   Output / Error**, same pane gates and copy as the inventory (incl. the `firstMeaningfulTres`
   `"(null)"` rule and the owned/running gates verbatim).
8. **Utilization pane is the hero — exceed the inventory here.** Keep the run/window pill rows
   (`utilColor` thresholds, 30 s window growth) AND add Swift Charts sparklines: one per GPU
   (util % + VRAM % overlaid or stacked), one CPU, one RAM — last 300 samples, 0–100 fixed
   y-axis, subtle area fill, no legends beyond the pill labels. Live metrics stream via
   `SlurmClient.streamJobMetrics` + `MetricStream.parse` with carried remainder; cap the
   accumulated text buffer (64 KiB) and retained samples (300); RunStats accumulator is
   unbounded by design. Kill the child process when the pane, screen, or popover closes.
9. **Output/Error panes**: one-shot `readLogTail` + 10 s poll while readable, monospaced
   scroll view, same gate order and empty-state copy. The live `tail -F` TailView is **v1.1 —
   do not build it**.
10. **Colors**: map inventory colors to assets with light/dark variants — green/yellow/red/
    orange/blue/purple/secondary. State→color via SlurmKit's `JobStateCategory`/
    `NodeStateCategory` mapped in ONE App-layer file (`StateColors.swift`).
11. **Stores** (`@Observable @MainActor`): `AppModel` (tab, banner queue, demo flag),
    `ClusterStore` (config hosts, active hosts in `UserDefaults` key `activeHosts` as JSON
    string array — fresh store, no Raycast migration; stale-host logic per inventory §6),
    `JobsStore` (per-host `ClusterResult<[Job]>`, 10 s poll while popover open; label counts
    from `listJobsBrief` every 30 s while closed), `NodesStore` (30 s / info tab 60 s),
    per-screen models for NodeJobs (10 s) and JobDetail. All polling suspends when the popover
    closes (except the 30 s label tick) and on screen sleep; every poll tick is
    `fetchPerCluster`-shaped.
12. **Select Clusters**: pushed screen mirroring inventory §6 — config-error screens, Stale/
    Active/Available sections, per-row master probe, toggle flow with the exact toast
    sequence (incl. the deliberate success-styled "Auth required — opening Terminal" case).
13. **Demo mode**: `SLURMBAR_DEMO=1` env or hidden `UserDefaults` flag. `DemoTransport` loaded
    from the P1a fixture JSONs **bundled as app resources** (add `fixtures/` as a resource
    folder reference in project.yml so rebuilds track regenerated fixtures). Inject ~220 ms
    artificial latency. Unknown command: if it matches a known builder shape (squeue/scontrol/
    whoami prefix) return empty output; otherwise throw `remote-cmd`. Demo metrics: synthesize
    plausible ticks at 1 Hz feeding the REAL `MetricStream.parse` (port the spirit of
    `mockMetricSample`).
14. **Settings scene**: General — ControlPersist (text, default 12h, fed to transport),
    launch at login (`SMAppService.mainApp` toggle), poll-interval overrides (jobs/nodes,
    bounded 5–120 s); Advanced — demo mode toggle, Copy diagnostics. Notifications tab lands
    in P4 — leave a placeholder.
15. **App identity**: keep codename SlurmBar / `local.slurmbar.dev`; `LSUIElement` stays true.

## Ports into SlurmKit (allowed paths above)

`Parse/JobTime.swift`: `parseSlurmDateTime`, `buildJobTime` (progress/elapsed/remaining/
started/ends, nowMs-parameterized — unit-test with fixed nowMs incl. UNLIMITED and pending
branches), `prettifyMem`, `stripUid` (UserId `(uid)` tail), `firstMeaningfulTres`. Native
`RelativeDateTimeFormatter`/`Date.FormatStyle` replace the TS string formatters in the App
layer; `progressBar` is NOT ported (native `ProgressView`).

## Build & CI

- `macos/scripts/generate-project.sh`: install-check xcodegen (brew) + `xcodegen generate`.
- `macos/scripts/build-app.sh`: `xcodebuild -project macos/SlurmBar.xcodeproj -scheme SlurmBar
  -configuration Debug build` (ad-hoc signing as configured). Add a `slurmbar-app` CI job
  (macos-15) running both scripts.
- SlurmKit tests still green via `macos/scripts/test-slurmkit.sh`.

## Acceptance

- `test-slurmkit.sh` exit 0 (incl. new JobTime tests); `build-app.sh` exit 0.
- **Snapshot mode (build this; it is the verification mechanism).** Driving a real menubar
  popover from a shell is flaky, so the app supports two debug affordances:
  (a) `SLURMBAR_DEBUG_WINDOW=1` — additionally hosts the popover root view in a regular
  resizable window (for humans);
  (b) `SLURMBAR_SNAPSHOT_DIR=<dir>` (implies demo mode) — headless verification: boot the demo
  stores, await first data for both demo hosts, then render via SwiftUI `ImageRenderer`
  (2x scale) each key screen to PNG in that dir and exit 0: the four tabs; JobDetail Info +
  Schedule + Utilization (running owned job, with ≥10 synthesized samples so charts draw) +
  the not-owned Utilization gate + a pending job's Info (the `"(null)"` rule); NodeJobs with a
  multi-node caveat row; Select Clusters. Non-zero exit if any render fails.
- Run snapshot mode, copy the PNGs to `macos/docs/screenshots/`, then INSPECT each image
  yourself (read the files) and verify against the inventory: label/count logic, section
  structure, job row accessory order, state colors, gate copy, the caveat tag, green
  connection dots. List each screenshot + what it evidences in the report.
- No real SSH. No commits.

## Report back

What shipped per §1–§15 (one line each), menubar-tint finding (§2), screenshot list, real exit
codes, deviations + why.
