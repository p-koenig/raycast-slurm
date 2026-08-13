import Foundation

/// An `SshTransport` that answers from a canned `[host: [command: output]]` map instead of the
/// network. The counterpart of `mockRunSsh` in `src/lib/demo.ts`.
///
/// The map is injected rather than built in: the tests fill it from the golden fixtures'
/// `(host, cmd, input)` triples — which closes the loop transport → parse on exactly the data the
/// TypeScript produced — while the app will fill it from bundled resources in P3.
///
/// Lookup is on the **exact** command string, so a drifting command builder shows up as a missing
/// entry rather than as silently stale output.
public final class DemoTransport: SshTransport {

    /// One canned answer.
    public struct Entry: Sendable {
        public var host: String
        public var command: String
        public var output: String

        public init(host: String, command: String, output: String) {
            self.host = host
            self.command = command
            self.output = output
        }
    }

    private let responses: [String: [String: String]]
    private let log = CallLog()

    public init(responses: [String: [String: String]]) {
        self.responses = responses
    }

    public convenience init(entries: [Entry]) {
        var responses: [String: [String: String]] = [:]
        for entry in entries {
            responses[entry.host, default: [:]][entry.command] = entry.output
        }
        self.init(responses: responses)
    }

    public func run(host: String, command: String, timeout: Duration = Transport.defaultTimeout) async throws -> String {
        await log.record(host: host, command: command)
        return try output(host: host, command: command)
    }

    public func spawnStream(host: String, command: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await log.record(host: host, command: command)
                do {
                    // The whole canned body arrives as one chunk; consumers must not assume tick
                    // boundaries anyway (`MetricStream.parse` carries its own remainder).
                    let output = try self.output(host: host, command: command)
                    if !output.isEmpty { continuation.yield(output) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every command this transport was asked for, in call order — the assertion surface for
    /// "the client issued exactly the fixture command".
    public func recordedCalls() async -> [(host: String, command: String)] {
        await log.calls()
    }

    /// Unknown host or command → the same shape a cluster produces for a command it dislikes, so
    /// demo-mode gaps surface as a normal error row rather than as an empty list.
    private func output(host: String, command: String) throws -> String {
        guard let forHost = responses[host] else {
            throw SshError(
                SshErrorInfo(
                    kind: .remoteCmd,
                    host: host,
                    title: "\(host): command failed",
                    message: "No demo fixtures for host '\(host)'.",
                    raw: command
                )
            )
        }
        guard let output = forHost[command] else {
            throw SshError(
                SshErrorInfo(
                    kind: .remoteCmd,
                    host: host,
                    title: "\(host): command failed",
                    message: "No demo fixture for this command.",
                    raw: command
                )
            )
        }
        return output
    }
}

/// Call recorder. An actor because `DemoTransport` is `Sendable` and a fanout hits it from several
/// tasks at once.
private actor CallLog {

    private var recorded: [(host: String, command: String)] = []

    func record(host: String, command: String) {
        recorded.append((host: host, command: command))
    }

    func calls() -> [(host: String, command: String)] {
        recorded
    }
}
