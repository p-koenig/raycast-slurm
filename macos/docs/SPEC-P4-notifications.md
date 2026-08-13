# SPEC P4 — Job-state notifications

Read `ARCHITECTURE.md` (App design → notifications) and `UI-INVENTORY.md` §12 (poll intervals)
first. Prerequisite: P3 green. P3 absorbed the metrics/charts work, so this phase is exactly
the notification engine plus its settings.

## Paths you may create/modify

- `macos/App/**`
- `macos/SlurmKit/Sources/SlurmKit/Parse/JobTransitions.swift` (NEW) + NEW test files under
  `macos/SlurmKit/Tests/SlurmKitTests/`
- `macos/project.yml` (only if a capability/Info.plist key is genuinely required)

No real SSH; demo mode + unit tests only. No git commits.

## Design (binding)

1. **Pure diff engine in SlurmKit** (`JobTransitions.swift`): given the previous and current
   `[Job]` for one host (my-jobs scope only), emit transitions:
   - `started` — jobId present in both, state PENDING→RUNNING.
   - `finishedInQueue(state)` — present in both, RUNNING→ any of COMPLETED / FAILED /
     CANCELLED / TIMEOUT / PREEMPTED (carry the state).
   - `disappeared(lastState)` — present before, absent now, and last-seen state was RUNNING or
     COMPLETING. This is the COMMON completion path: squeue drops finished jobs between polls,
     so most jobs never show a terminal state. PENDING jobs that disappear also emit this
     (cancelled elsewhere / completed within one poll).
   Array tasks are individual jobIds (`6644_33`) — no aggregation in v1. Pure function,
   fully unit-tested (each transition, no-change, first-poll, multi-job mixes).
2. **Baseline rule**: no notifications from the first successful poll per host after app
   launch, after that host recovers from an error, or after system wake — the engine takes
   `isBaseline: Bool`; the App layer decides when a poll is a baseline. Unit-test that a
   baseline emits nothing.
3. **Final-state resolution for `disappeared`**: the App layer tries ONE `showJob` (scontrol
   keeps finished jobs visible for a few minutes) to resolve the real final state; on any
   failure, notify with "finished" and no state. Never retry.
4. **Delivery** (App layer, `UNUserNotificationCenter`):
   - started: "Job {id} started" / body "{name} on {host}".
   - finished with state: "Job {id} {statelabel}" (Completed/Failed/Cancelled/Timeout/
     Preempted) / body "{name} on {host} — ran {elapsed}" when elapsed is known.
   - finished unknown: "Job {id} finished" / body "{name} on {host}".
   - Failure-ish states (FAILED/TIMEOUT) use `.timeSensitive` interruption level if
     authorization allows; others default.
   - Authorization requested on first enable of the master toggle, not at launch. Handle
     denial by flipping the toggle off with an inline explanation.
   - Notification click: activate the app (`NSApp.activate`). There is NO public API to open
     a MenuBarExtra popover programmatically — do not fake it; if `SLURMBAR_DEBUG_WINDOW=1`
     is active, bring that window forward.
5. **Settings → Notifications tab** (replaces the P3 placeholder): master toggle (default
   OFF — notifications are opt-in), "when a job starts" (default ON), "when a job finishes"
   (default ON). Per-host granularity is out of scope.
6. **Demo hook**: in demo mode, a hidden "Simulate transition" button in the Notifications tab
   fires a fake finished-notification through the real delivery path (this is how you and the
   human verify end-to-end without a cluster).

## Acceptance

- `macos/scripts/test-slurmkit.sh` exit 0 (all prior + new JobTransitions suites; report counts).
- `macos/scripts/build-app.sh` exit 0.
- Snapshot-mode run still exits 0 (no P3 regression), and a demo-mode launch with the master
  toggle on delivers the simulated notification (verify via `log stream` or screenshot of the
  banner if feasible; report what you observed).

## Report back

Transition-engine test counts, delivery copy as shipped, real exit codes, deviations + why.
