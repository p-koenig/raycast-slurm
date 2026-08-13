import Foundation

/// The real transport: `/usr/bin/ssh` with OpenSSH connection multiplexing. Port of
/// `src/lib/ssh.ts`.
///
/// The flag list, its order, and the ControlPath are byte-identical to the Raycast extension's on
/// purpose — app and extension then share **one** multiplexed master per cluster instead of
/// authenticating twice.
///
/// Everything the tests need to inject (ssh binary, control directory, environment, ssh config,
/// demo-host predicate, output cap) lives in `Configuration`; the defaults are production values.
public final class OpenSshTransport: SshTransport {

    public struct Configuration: Sendable {

        public var sshBinary: String
        /// Holds the ControlPath socket. Created 0700 on demand.
        public var controlDirectory: String
        /// `ControlPersist`, from the preference. `12h` when unset (`controlPersist()`).
        public var controlPersist: String
        /// The child's environment *before* the locale override.
        public var environment: [String: String]
        /// The host gate's source of truth.
        public var sshConfig: SshConfig
        /// Demo-host predicate: demo aliases skip the config gate and the master lifecycle, the
        /// way `DEMO_MODE && isDemoHost(host)` does in the TS. Demo *data* is `DemoTransport`'s
        /// job, so `run` has no bypass here.
        public var isDemoHost: @Sendable (String) -> Bool
        public var maxOutputBytes: Int

        public init(
            sshBinary: String = OpenSshTransport.defaultSshBinary,
            controlDirectory: String = OpenSshTransport.defaultControlDirectory,
            controlPersist: String = "12h",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            sshConfig: SshConfig = SshConfig(),
            isDemoHost: @escaping @Sendable (String) -> Bool = { _ in false },
            maxOutputBytes: Int = Transport.defaultMaxOutputBytes
        ) {
            self.sshBinary = sshBinary
            self.controlDirectory = controlDirectory
            self.controlPersist = controlPersist.trimmingCharacters(in: .whitespaces).isEmpty
                ? "12h" : controlPersist.trimmingCharacters(in: .whitespaces)
            self.environment = environment
            self.sshConfig = sshConfig
            self.isDemoHost = isDemoHost
            self.maxOutputBytes = maxOutputBytes
        }
    }

    public static let defaultSshBinary = "/usr/bin/ssh"

    /// `/tmp/raycast-slurm-<uid>` — **never** relocate this.
    ///
    /// macOS caps unix-socket `sun_path` at 104 bytes and `%C` expands to a 40-character SHA-1, so
    /// the prefix has to stay short; `~/Library/Caches/...` overflows. It is also the extension's
    /// path verbatim, which is what lets both share a master.
    public static let defaultControlDirectory = "/tmp/raycast-slurm-\(getuid())"

    public let configuration: Configuration
    private let state = TransportState()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Flags

    public var controlPath: String { configuration.controlDirectory + "/ssh-%C" }

    /// `commonOpts()` — shared by every invocation *and* by the interactive Terminal fallback.
    public var commonOptions: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=\(configuration.controlPersist)",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
        ]
    }

    /// `baseOpts()` — `commonOpts()` plus non-interactive auth.
    public var baseOptions: [String] { commonOptions + ["-o", "BatchMode=yes"] }

    /// `sshEnv()`.
    ///
    /// Raycast (and any macOS `.app`) inherits a mangled CFLocale string that Linux glibc cannot
    /// parse; Apple's stock `ssh_config` forwards it via `SendEnv LANG LC_*`, and the resulting
    /// `setlocale` warning on stderr once masqueraded as a genuine `SshError`. Forcing a clean
    /// POSIX locale means what we forward is always valid.
    public var environment: [String: String] {
        var env = configuration.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        return env
    }

    // MARK: - Commands

    public func run(host: String, command: String, timeout: Duration = Transport.defaultTimeout) async throws -> String {
        try ensureControlDirectory()
        try await requireHostInConfig(host)
        let outcome = try await execute(
            arguments: baseOptions + [host, command],
            timeout: timeout,
            host: host
        )
        return outcome.stdout
    }

    /// Is a master socket already live for `host`?
    ///
    /// No `requireHostInConfig()` here on purpose: `-O check` is a local-only probe of the
    /// ControlPath socket, harmless for any alias, and this runs once per host on the cluster
    /// picker. Gating it would reparse the whole `~/.ssh/config` (Include expansion + `compute`
    /// per alias) once per host — O(N²) work that stalls the UI for seconds on larger configs.
    /// Any failure here just means "down".
    public func isMasterUp(host: String) async -> Bool {
        if configuration.isDemoHost(host) { return true }
        // The TS lets a failed `mkdir` reject out of `isMasterUp`; a non-throwing `Bool` is the
        // better shape for a probe whose every other failure already means "down", so an
        // uncreatable control directory reports the same thing.
        guard (try? ensureControlDirectory()) != nil else { return false }
        return await state.withHostLock(host) {
            let outcome = try? await execute(
                arguments: baseOptions + ["-O", "check", host],
                timeout: .seconds(5),
                host: host
            )
            return outcome != nil
        }
    }

    /// Open the multiplexed master (`ssh -fN`), so subsequent commands are instant.
    public func openMaster(host: String) async throws {
        if configuration.isDemoHost(host) { return }
        try ensureControlDirectory()
        try await requireHostInConfig(host)
        try await state.withHostLock(host) {
            _ = try await execute(arguments: baseOptions + ["-fN", host], timeout: .seconds(30), host: host)
        }
    }

    /// "Logout": tear the master down. Failures are swallowed — the socket may already be gone.
    public func closeMaster(host: String) async {
        if configuration.isDemoHost(host) { return }
        guard (try? ensureControlDirectory()) != nil else { return }
        await state.withHostLock(host) {
            _ = try? await execute(arguments: baseOptions + ["-O", "exit", host], timeout: .seconds(5), host: host)
        }
    }

    public func spawnStream(host: String, command: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            // One handle owns teardown, so a consumer that stops iterating before the process is
            // even spawned still kills it (the naive version loses that race and leaks an ssh).
            let handle = StreamHandle()
            let task = Task {
                do {
                    try ensureControlDirectory()
                    try await requireHostInConfig(host)
                    let box = try ProcessLauncher.stream(
                        executable: configuration.sshBinary,
                        arguments: baseOptions + [host, command],
                        environment: environment,
                        onExit: { status, stderr in
                            if status == 0 {
                                continuation.finish()
                            } else {
                                continuation.finish(
                                    throwing: toSshError(
                                        SshFailure(
                                            stderr: stderr,
                                            message: "Command failed with exit code \(status)",
                                            exitCode: status
                                        ),
                                        host: host
                                    )
                                )
                            }
                        },
                        onChunk: { continuation.yield($0) }
                    )
                    handle.attach(box)
                } catch {
                    continuation.finish(throwing: toSshError(error, host: host))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                handle.cancel()
            }
        }
    }

    /// The command shown to the user when `BatchMode` auth fails (2FA, password).
    ///
    /// `BatchMode=yes` is omitted so `ssh` can prompt in the terminal. Opening Terminal itself is
    /// App-layer work (`NSWorkspace`/`NSAppleScript`) — SlurmKit stays UI-free.
    public func interactiveOpenMasterCmd(host: String) -> String {
        "ssh \(commonOptions.joined(separator: " ")) -fN \(shellQuote(host))"
    }

    // MARK: - Host gate

    /// Hosts confirmed present in `~/.ssh/config` for the lifetime of this transport.
    ///
    /// Positive results only. A negative result is never memoized, so the user can fix
    /// `~/.ssh/config` and retry without restarting the app.
    private func requireHostInConfig(_ host: String) async throws {
        if configuration.isDemoHost(host) { return }
        if await state.isKnownHost(host) { return }

        let result = configuration.sshConfig.listHosts()
        switch result.state {
        case .missing(let path):
            throw SshError(
                SshErrorInfo(
                    kind: .hostNotInConfig,
                    host: host,
                    title: "No ~/.ssh/config",
                    message: "Cannot connect to '\(host)' — your SSH config file is missing.",
                    hint: "Create \(path) with at least one Host entry.",
                    raw: "\(path) does not exist"
                )
            )
        case .unreadable(let path, let reason):
            throw SshError(
                SshErrorInfo(
                    kind: .hostNotInConfig,
                    host: host,
                    title: "Couldn't read ~/.ssh/config",
                    message: reason,
                    hint: "Fix permissions or syntax in \(path).",
                    raw: reason
                )
            )
        case .ok, .empty:
            break
        }
        guard result.hosts.contains(where: { $0.name == host }) else {
            throw makeHostNotInConfigError(host: host)
        }
        await state.rememberHost(host)
    }

    // MARK: - Plumbing

    /// `ensureControlDir()` — 0700, created on demand.
    private func ensureControlDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: configuration.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Run one `ssh` invocation and turn everything that can go wrong into an `SshError`.
    @discardableResult
    private func execute(arguments: [String], timeout: Duration, host: String) async throws -> ProcessLauncher.Outcome {
        let outcome: ProcessLauncher.Outcome
        do {
            outcome = try await ProcessLauncher.run(
                executable: configuration.sshBinary,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                maxOutputBytes: configuration.maxOutputBytes
            )
        } catch let error as ProcessLauncher.SpawnError {
            throw toSshError(SshFailure(message: error.description), host: host)
        }

        // A cancelled task killed the process; surface that as cancellation, not as a timeout.
        if Task.isCancelled { throw CancellationError() }

        if outcome.overflowed {
            // Node's wording for the same condition, so the classifier and the UI see what they
            // saw in the extension.
            throw toSshError(
                SshFailure(stderr: outcome.stderr, message: "stdout maxBuffer length exceeded"),
                host: host
            )
        }
        if outcome.timedOut {
            throw toSshError(
                SshFailure(stderr: outcome.stderr, message: "Command timed out", timedOut: true),
                host: host
            )
        }
        if outcome.exitCode != 0 {
            // The message stays generic on purpose: it lands in the classifier's haystack, and a
            // full command line there could match `password:` or `publickey` by accident.
            throw toSshError(
                SshFailure(
                    stderr: outcome.stderr,
                    message: "Command failed with exit code \(outcome.exitCode)",
                    exitCode: outcome.exitCode
                ),
                host: host
            )
        }
        return outcome
    }
}

/// Teardown handle for `spawnStream`: the consumer may stop iterating before (or after) the
/// process exists, and either order must end with the process dead.
private final class StreamHandle: @unchecked Sendable {

    private let lock = NSLock()
    private var box: ProcessBox?
    private var cancelled = false

    func attach(_ box: ProcessBox) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.box = box
        lock.unlock()
        if alreadyCancelled { box.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let box = self.box
        lock.unlock()
        box?.terminate()
    }
}

/// Mutable transport state: the host-gate memo and per-host serialization of the master lifecycle.
///
/// `isMasterUp` / `openMaster` / `closeMaster` for one host never overlap — two `openMaster` calls
/// racing on the same ControlPath produce a spurious "control socket already exists" failure.
/// Different hosts proceed in parallel, and `run` is not serialized at all (the whole point of the
/// fanout is parallelism).
actor TransportState {

    private var knownHosts: Set<String> = []
    private var lockedHosts: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func isKnownHost(_ host: String) -> Bool { knownHosts.contains(host) }

    func rememberHost(_ host: String) { knownHosts.insert(host) }

    func withHostLock<T: Sendable>(_ host: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(host)
        defer { release(host) }
        return try await body()
    }

    private func acquire(_ host: String) async {
        while lockedHosts.contains(host) {
            await withCheckedContinuation { continuation in
                waiters[host, default: []].append(continuation)
            }
        }
        lockedHosts.insert(host)
    }

    private func release(_ host: String) {
        lockedHosts.remove(host)
        guard var queue = waiters[host], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        waiters[host] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
