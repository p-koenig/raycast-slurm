# SPEC P0 — Repository scaffold

Read `macos/docs/ARCHITECTURE.md` first. This phase creates the skeleton everything else lands in.

## Paths you may create/modify

- `macos/**` (except `macos/docs/` — read-only)
- `.github/workflows/macos-app.yml`
- `.gitignore` (append only)

Do NOT touch `src/`, `scripts/`, `fixtures/`, `package.json`.

## Deliverables

1. **`macos/SlurmKit/Package.swift`** — swift-tools-version 6.0, library target `SlurmKit`,
   test target `SlurmKitTests` using Swift Testing (`@Test` macros; do not add swift-testing as a
   dependency — it ships with the Swift 6 toolchain). `platforms: [.macOS(.v14)]`.
   Create the source tree from ARCHITECTURE.md (`Model/`, `Parse/`, `SshConfig/`, `Transport/`,
   `Demo/`) with one placeholder Swift file each (e.g. an empty enum namespace) so the package
   compiles, plus one trivial passing `@Test` in `SlurmKitTests` that also verifies fixture-root
   resolution: compute the repo root via `#filePath` navigation, assert the directory exists.
   Put that path helper in a shared test utility (`TestSupport.swift`) — P1b depends on it.

2. **`macos/project.yml`** — XcodeGen spec for app target `SlurmBar`:
   - bundle id `local.slurmbar.dev`, deployment target 14.0
   - `LSUIElement: true` in Info.plist properties
   - depends on local package `SlurmKit` (path reference)
   - `CODE_SIGN_IDENTITY: "-"`, `CODE_SIGNING_ALLOWED: NO` for now (signing deferred)
   - Sources: `macos/App`
   Create `macos/App/SlurmBarApp.swift` as a minimal compiling `MenuBarExtra` app
   (`.menuBarExtraStyle(.window)`, static label, "Hello SlurmBar" popover content).
   Full Xcode is NOT installed on this machine — do not attempt `xcodegen generate` or
   `xcodebuild`. The app target is validated in CI and in Phase 3; your gate is `swift build` /
   `swift test` for SlurmKit only. If `xcodegen` is not installed either, that is fine — the
   YAML is reviewed, not executed, in this phase.

3. **`.github/workflows/macos-app.yml`** — two jobs:
   - `fixtures` (ubuntu-latest): `npm ci`, `npm run export-fixtures`, `git diff --exit-code fixtures/`.
     The npm script does not exist yet (P1a creates it) — write the workflow now; it may fail
     until P1a lands, that is expected and acceptable.
   - `slurmkit` (macos-15): `swift test --package-path macos/SlurmKit`.
   Trigger: push + pull_request, with `paths:` filters covering `macos/**`, `fixtures/**`,
   `scripts/**`, `src/lib/**`.

4. **`.gitignore` additions**: `macos/*.xcodeproj`, `macos/SlurmKit/.build/`, `macos/build/`,
   `DerivedData/`, `.swiftpm/`.

5. **Extension-compat check**: run `npm run build` at repo root (via `rtk proxy npm run build`
   to see the true exit code) and confirm the Raycast extension still builds with the new
   top-level directories present. If it fails *because of the new directories*, report the
   failure mode — do not restructure the repo yourself. If it fails for a pre-existing reason
   unrelated to your changes (verify by stashing your changes mentally — the tree also carries
   the user's uncommitted v2 work), report that distinction explicitly.

## Acceptance

- `swift test --package-path macos/SlurmKit` exits 0 locally (Command Line Tools only).
- `npm run build` outcome reported with the distinction above.
- No files outside the allowed paths changed. No git commits.

## Report back

Files created, test/build output (real exit codes), any deviation + why.
