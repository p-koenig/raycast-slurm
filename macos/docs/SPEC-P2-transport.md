# SPEC P2 — SshConfig, Transport, SlurmClient, Demo transport

Read `macos/docs/ARCHITECTURE.md` first (Transport design section). Prerequisites on disk: P0
scaffold, P1a fixtures, P1b Model/Parse (golden-green). Reference TS: `src/lib/ssh.ts`,
`src/lib/ssh-config.ts`, `src/lib/errors.ts`, `src/lib/multi.ts`.

## Paths you may create/modify

- `macos/SlurmKit/Sources/SlurmKit/SshConfig/**`
- `macos/SlurmKit/Sources/SlurmKit/Transport/**`
- `macos/SlurmKit/Sources/SlurmKit/Demo/**`
- `macos/SlurmKit/Tests/SlurmKitTests/**` — new test files only; P1b's existing tests are
  read-only and must still pass.

Everything else is read-only. `Package.swift` needs no changes (zero dependencies stays true).

## Absolute safety rule

You must NOT open any real SSH connection or contact any real host. All transport tests run
against a stub `ssh` executable (a shell script you write into a temp dir). The real-cluster
smoke test is a human gate performed later — not yours.

## Deliverables

1. **SshConfig** (port of `ssh-config.ts`, replacing the npm `ssh-config` + `fast-glob` deps):
   - `ConfigState` tagged enum: `ok(parsed)` / `missing(path)` / `empty(path)` / `unreadable(path, reason)`.
   - Include expansion mirroring `inlineIncludes`: recursive, cycle-safe (`visited` set on
     resolved absolute paths), unreadable-include → contributes empty string (NOT an error),
     tilde expansion, relative patterns resolved against the ssh dir, quoted tokens, glob
     support (use POSIX `glob(3)` or FileManager matching; dotfiles must match; files only).
   - Minimal ssh_config parser sufficient for what the TS uses: `Host` blocks with
     space-separated aliases (quoted aliases too), keyword/value lines (`Key Value` and
     `Key=Value` forms), comments/blank lines skipped.
   - `compute(alias)` with OpenSSH semantics: walk blocks in order; a block applies if any of
     its positive patterns glob-match (`*`/`?`) the alias AND no negated (`!`) pattern matches;
     for each keyword the FIRST obtained value wins; `IdentityFile` accumulates into an array.
   - `listHosts()`: concrete aliases only (skip any alias containing `*`, `?`, `!`), first-seen
     dedupe, each resolved via `compute` into the `Host` model (`name`, `hostName` defaulting
     to alias, `user?`, `port?`, `identityFile?`), sorted case-insensitively by name.
   - The ssh directory/config path MUST be injectable (init parameter defaulting to `~/.ssh`)
     so tests run against temp dirs. Active-host persistence is NOT ported — that is App-layer
     UserDefaults (P3).

2. **Error classification** (port of `errors.ts` minus the toast): `SshErrorKind` enum with
   raw values exactly matching the TS strings; `SshErrorInfo` struct (Codable/Equatable);
   `classifySshError` with the identical regex table, benign-stderr stripping (all four
   patterns), 200-char first-line truncation, host suffixing; `SshErrorInfo`-carrying
   `SshError: Error`. Classification input is a `(stderr, message, exitCode?, timedOut)`
   shape — map the TS `code`/`signal` checks (`ETIMEDOUT`, `SIGTERM`) onto the timeout flag.

3. **OpenSshTransport** (port of `ssh.ts`):
   - Flags byte-identical and in the same order as `commonOpts()`/`baseOpts()`; ControlPath
     `/tmp/raycast-slurm-<uid>/ssh-%C` with 0700 dir creation; `ControlPersist` injectable
     (default `12h`); env = inherited + `LC_ALL=C`, `LANG=C`.
   - `run(host:command:timeout:)` (default 15 s, output cap 16 MiB — on breach kill the process
     and throw), `isMasterUp` (`-O check`, 5 s, NO host gate — preserve the documented
     perf reason as a comment), `openMaster` (`-fN`, 30 s), `closeMaster` (`-O exit`, swallow
     failures), `spawnStream(host:command:)` for long-lived processes (P4 uses it), and
     `interactiveOpenMasterCmd(host:)` (no BatchMode; uses ported `shellQuote`). Terminal
     opening itself is App-layer — do not implement it here.
   - `requireHostInConfig` semantics: positive-only memoization, demo-host bypass hook, the
     three error shapes from `ssh.ts:69-97`.
   - Per-host serialization of master lifecycle via an actor. The ssh binary path, control
     dir, and environment must be injectable for tests.
   - Careful with `Process`: read stdout/stderr concurrently (pipes deadlock if drained
     serially), handle termination + timeout with structured concurrency, and make `run`
     cancellation-safe (cancelling the task kills the process).

4. **SlurmClient**: per-host façade combining `SlurmCommands` (P1b) + transport + Parse:
   `detectUser()`, `listJobs(user:)`, `listJobsBrief(user:)`, `listAllJobs()`,
   `listPartitionActivity(partition:)`, `listNodeJobs(node:)`, `showJob(jobId:)`
   (returns `JobDetail` with `raw` + tokenized fields), `cancelJob(jobId:)`, `listNodes()`,
   `readLogTail(path:lines:)` (command parity with `readLogTail` incl. the `tail -c`/`tr`/`tail -n`
   pipeline — UI lands v1.1 but the client method lands now), `streamJobMetrics(jobId:)`
   (base64-ships the P1b-ported METRICS_SCRIPT; must reproduce the fixture `metrics-script`
   cmd byte-for-byte).

5. **Fanout**: `fetchPerCluster(hosts:_:)` — TaskGroup, input-order-preserving result array of
   `ClusterResult<T>` (`ok(host,data)` / `failed(host,SshErrorInfo)`), never throws, one
   cluster's failure never affects another. Port `successes`/`failures` helpers.

6. **DemoTransport**: implements the transport protocol from an injected `[host: [cmd: output]]`
   map, plus a loader that builds that map from the P1a fixture files' `(host, cmd, input)`
   triples (test-side via `TestSupport`; app-side bundling is P3's concern). Unknown command →
   throw a `remote-cmd` SshError.

## Tests (all via the stub ssh + temp dirs; never the network)

- SshConfig: temp-dir configs exercising Include glob + recursion + cycle, quoted include,
  tilde (inject a fake home), `Key=Value` form, wildcard-skip in listHosts, `Host *` defaults
  merging into compute, negation, first-value-wins, IdentityFile accumulation, and all four
  ConfigStates.
- Classifier: canned stderr per kind (auth incl. 2FA phrasing, host-key, DNS, refused,
  timeout incl. flag-driven, network, remote-cmd via real slurm-ish stderr, unknown), the
  setlocale line being stripped (the bug memorialized in `errors.ts:51-63`), benign-only
  stderr → not remote-cmd.
- Transport: stub `ssh` script that records argv to a file and plays scripted
  stdout/stderr/exit-code/delay — assert exact argv (flags order, ControlPath, BatchMode),
  env (`LC_ALL=C`), success passthrough, nonzero-exit → classified error, timeout →
  timeout-kind error and the process actually killed, output-cap breach handled.
- SlurmClient: DemoTransport loaded from real fixtures; every client method returns models
  equal to the fixture `expected` (this closes the loop transport→parse on the same golden
  data), and issues exactly the fixture `cmd`.
- Fanout: mixed success/failure hosts, order preserved, error classified.

## Acceptance

- `macos/scripts/test-slurmkit.sh` exits 0: ALL P1b tests still green + all new suites.
  Report suite/case counts. (CLT-only machine: bare `swift test` fails — use the wrapper.)
- `swift build --package-path macos/SlurmKit` exits 0.
- No changes outside allowed paths; no git commits; no real network/ssh use.

## Report back

Suites + case counts, real exit codes, any TS behavior you had to interpret (with your
reading), any deviation + why.
