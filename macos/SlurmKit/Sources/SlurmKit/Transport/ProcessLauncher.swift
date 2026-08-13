import Foundation

/// Spawning `ssh` and collecting its output — the part of `execFile`/`spawn` that Node gave the
/// extension for free.
///
/// Three hazards drive the shape of this file:
/// * **pipe deadlock** — stdout and stderr must be drained *concurrently*. Reading one to EOF
///   before touching the other wedges as soon as the process fills the 64 KiB pipe buffer of the
///   other. `readabilityHandler` gives concurrent draining without a thread per stream.
/// * **`Process` is not `Sendable`** — it is confined to `ProcessBox`, which serialises every
///   touch behind a lock and is `@unchecked Sendable` for that reason.
/// * **cancellation and deadlines must actually kill the child** — both paths send `SIGTERM`
///   (what Node's `execFile` timeout does) and stop waiting on the pipes after a short grace,
///   because a backgrounded grandchild can hold the write end open long after the direct child is
///   gone.
enum ProcessLauncher {

    struct Outcome: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        /// The deadline fired and we killed the process.
        var timedOut: Bool
        /// Output exceeded the cap; the process was killed and what we have is truncated.
        var overflowed: Bool
    }

    /// The process could not be started at all (bad path, permissions). Kept distinct from a
    /// non-zero exit so the caller can classify it as a local failure.
    struct SpawnError: Error, CustomStringConvertible {
        var executable: String
        var reason: String
        var description: String { "spawn \(executable) failed: \(reason)" }
    }

    /// How long to keep draining after the child is gone. EOF normally arrives with the exit, so
    /// this only ever costs a poll.
    private static let drainGraceAfterExit: Duration = .seconds(2)
    private static let drainGraceAfterKill: Duration = .milliseconds(250)

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(cap: maxOutputBytes)
        let box = ProcessBox(process)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish(.stdout)
            } else if collector.append(data, to: .stdout) {
                box.terminate()
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish(.stderr)
            } else if collector.append(data, to: .stderr) {
                box.terminate()
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw SpawnError(executable: executable, reason: String(describing: error))
        }

        let exitCode = await withTaskCancellationHandler {
            let deadline = Task {
                try await Task.sleep(for: timeout)
                box.markTimedOut()
                box.terminate()
            }
            let status = await box.waitForExit()
            deadline.cancel()
            return status
        } onCancel: {
            box.terminate()
        }

        await collector.waitForEOF(within: box.timedOut ? drainGraceAfterKill : drainGraceAfterExit)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        let (out, err, overflowed) = collector.snapshot()
        return Outcome(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: exitCode,
            timedOut: box.timedOut,
            overflowed: overflowed
        )
    }

    /// Spawn a long-lived process and hand back its stdout as it arrives, plus a handle that kills
    /// it. Used by `spawnStream` (the metrics streamer and, in v1.1, the log tail).
    ///
    /// Chunks are yielded as read, *not* split into lines: `MetricStream.parse` owns the
    /// line/tick framing and carries its own remainder, so re-framing here would only get in its
    /// way.
    static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @Sendable (Int32, String) -> Void,
        onChunk: @escaping @Sendable (String) -> Void
    ) throws -> ProcessBox {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stderrCollector = OutputCollector(cap: 64 * 1024)
        let box = ProcessBox(process)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                onChunk(String(decoding: data, as: UTF8.self))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                _ = stderrCollector.append(data, to: .stderr)
            }
        }
        box.onExit { status in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let (_, err, _) = stderrCollector.snapshot()
            onExit(status, String(decoding: err, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw SpawnError(executable: executable, reason: String(describing: error))
        }
        return box
    }
}

/// A `Process` behind a lock.
///
/// `Process` is not `Sendable` and its `terminationHandler` fires on an arbitrary queue, so every
/// access — launch state, termination, exit-status waiters — goes through here.
final class ProcessBox: @unchecked Sendable {

    private let lock = NSLock()
    private let process: Process
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var exitCallback: (@Sendable (Int32) -> Void)?
    private var didTimeOut = false

    init(_ process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] proc in
            self?.complete(proc.terminationStatus)
        }
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    /// `SIGTERM`, the signal Node's `execFile` timeout sends. Safe to call repeatedly and after the
    /// process is gone.
    func terminate() {
        lock.lock()
        let running = exitStatus == nil && process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status = exitStatus {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// One-shot exit callback for the streaming path, which has no task to suspend.
    func onExit(_ callback: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if let status = exitStatus {
            lock.unlock()
            callback(status)
        } else {
            exitCallback = callback
            lock.unlock()
        }
    }

    private func complete(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = waiters
        waiters = []
        let callback = exitCallback
        exitCallback = nil
        lock.unlock()
        for waiter in pending { waiter.resume(returning: status) }
        callback?(status)
        // `terminationHandler` is deliberately left in place: we are running inside it, and
        // clearing it here would release the closure that is currently executing. There is no
        // retain cycle to break — the handler captures `self` weakly.
    }
}

/// Lock-protected accumulation of a child's stdout/stderr, with Node's `maxBuffer` cap.
final class OutputCollector: @unchecked Sendable {

    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let cap: Int
    private var out = Data()
    private var err = Data()
    private var outDone = false
    private var errDone = false
    private var overflowed = false

    init(cap: Int) {
        self.cap = cap
    }

    /// Returns `true` when this append hit the cap — the caller kills the process, exactly as
    /// Node does when `maxBuffer` is exceeded.
    func append(_ data: Data, to stream: Stream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if overflowed { return false }
        let current = stream == .stdout ? out.count : err.count
        let room = cap - current
        if data.count > room {
            let slice = data.prefix(max(0, room))
            if stream == .stdout { out.append(slice) } else { err.append(slice) }
            overflowed = true
            return true
        }
        if stream == .stdout { out.append(data) } else { err.append(data) }
        return false
    }

    func finish(_ stream: Stream) {
        lock.lock()
        if stream == .stdout { outDone = true } else { errDone = true }
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outDone && errDone
    }

    func snapshot() -> (Data, Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err, overflowed)
    }

    /// Poll until both pipes report EOF, or the grace period runs out.
    ///
    /// Polling rather than a continuation on purpose: EOF is normally already true on the first
    /// check (the process exited), and a continuation woken from a signal handler would need
    /// cancellation bookkeeping to avoid a lost wakeup. A 5 ms poll cannot lose one.
    func waitForEOF(within grace: Duration) async {
        if isDone { return }
        let deadline = ContinuousClock.now.advanced(by: grace)
        while !isDone, ContinuousClock.now < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
