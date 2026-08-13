import Foundation

/// A cancellable repeating task, main-actor bound.
///
/// The extension polls with `setInterval` inside a `useEffect`; the native equivalent is a
/// `Task` that sleeps in a loop, because that suspends cleanly and cancels deterministically —
/// which is the whole requirement here. SPEC-P3 §11: every timer stops when the popover closes
/// and when the screen sleeps, so nothing wakes a laptop to run `squeue`.
///
/// The interval is read through a closure on every iteration, so changing a poll interval in
/// Settings takes effect on the next tick without restarting the loop.
@MainActor
final class PollLoop {

    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// (Re)start the loop. Any previous loop is cancelled first, so calling this on every state
    /// change is safe and is how the callers use it.
    ///
    /// - Parameters:
    ///   - seconds: interval, re-read each iteration.
    ///   - fireImmediately: run `body` once before the first sleep. What you want when a view
    ///     appears; not what you want when only the cadence changed.
    func start(
        seconds: @escaping @MainActor () -> Double,
        fireImmediately: Bool = true,
        _ body: @escaping @MainActor () async -> Void
    ) {
        task?.cancel()
        task = Task { @MainActor in
            if fireImmediately {
                await body()
            }
            while !Task.isCancelled {
                let interval = seconds()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return  // cancelled mid-sleep
                }
                if Task.isCancelled { return }
                await body()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
