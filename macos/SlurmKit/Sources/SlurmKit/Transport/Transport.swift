import Foundation

/// Namespace for cluster I/O.
///
/// The concrete types live alongside as top-level `public` declarations, the same convention the
/// Parse layer follows: `SshTransport`, `OpenSshTransport`, `SlurmClient`, `fetchPerCluster`,
/// `DemoTransport`. This enum keeps the shared defaults that both implementations answer to.
///
/// See macos/docs/ARCHITECTURE.md § "Transport design (Phase 2)".
public enum Transport {

    /// The per-command deadline. `runSsh`'s `opts.timeout ?? 15_000` (`src/lib/ssh.ts:145`).
    public static let defaultTimeout: Duration = .seconds(15)

    /// Output cap per command, matching `runSsh`'s `maxBuffer` of 16 MiB. A cluster-wide
    /// `squeue` on a busy machine is the reason there is a cap at all.
    public static let defaultMaxOutputBytes = 16 * 1024 * 1024
}

/// What every consumer of a cluster needs: run a command, or follow one that never ends.
///
/// Two implementations: `OpenSshTransport` (real `ssh`) and `DemoTransport` (fixtures). Views and
/// stores depend on this protocol only, which is what makes demo mode flow through the real
/// parsers instead of a parallel code path.
public protocol SshTransport: Sendable {

    /// Run `command` on `host` and return its stdout. Throws `SshError` for every failure mode.
    func run(host: String, command: String, timeout: Duration) async throws -> String

    /// Follow a long-lived command, yielding stdout as it arrives.
    ///
    /// Chunks are *not* re-framed into lines: `MetricStream.parse` owns tick framing and carries
    /// its own remainder (ARCHITECTURE.md names this `stream`; SPEC-P2 names it `spawnStream`, and
    /// the spec wins). Terminating the stream kills the remote process.
    func spawnStream(host: String, command: String) -> AsyncThrowingStream<String, any Error>
}

extension SshTransport {

    /// `runSsh(host, cmd)` with the default 15 s deadline.
    public func run(host: String, command: String) async throws -> String {
        try await run(host: host, command: command, timeout: Transport.defaultTimeout)
    }
}
