import Foundation

// The diff engine behind job notifications (SPEC-P4 §1).
//
// It is deliberately a pure function over two `squeue` snapshots for **one host, my-jobs scope**:
// everything that makes notifications hard — authorization, delivery, whether this poll counts as
// a baseline, resolving a vanished job's real final state via `scontrol` — lives in the App layer.
// What lives here is the one part that is worth unit testing exhaustively, because getting it
// wrong is either silence (a job finishes and the user is never told) or a burst of duplicates.

/// A Slurm state that means the job is over.
///
/// Exactly the five states `squeue %T` can still be showing for a stopped job. Anything else a
/// cluster invents (`OUT_OF_MEMORY`, `NODE_FAIL`, …) is *not* in this set on purpose: those never
/// linger in `squeue` in practice, so they reach the user through the `disappeared` path, and the
/// App layer's `scontrol` lookup either recognises the state or falls back to a stateless
/// "finished" — which is better than inventing copy for a state we have never observed.
public enum JobTerminalState: String, Codable, Equatable, Sendable, CaseIterable {
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case timeout = "TIMEOUT"
    case preempted = "PREEMPTED"

    /// Parse a raw Slurm state.
    ///
    /// Tolerant of the two shapes the same state arrives in: `squeue %T` prints a bare token
    /// (`CANCELLED`), while `scontrol`'s `JobState` appends a reason (`CANCELLED by 41253`).
    /// Both must resolve to the same case, because the App layer feeds this both.
    public init?(slurmState raw: String) {
        self.init(rawValue: JobTransitions.normalizedState(raw))
    }

    /// Whether this reads as "something went wrong", which is the App layer's cue to ask for a
    /// `.timeSensitive` interruption level.
    public var isFailure: Bool { self == .failed || self == .timeout }
}

/// One thing that happened to one job between two polls.
///
/// The job travels with the transition so the App layer can build its copy (name, elapsed) without
/// a second lookup. Which snapshot it comes from is part of the contract — see each `Kind`.
public struct JobTransition: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// The job left the queue and is now on the machine. `job` is the **current** row.
        case started
        /// The job reached a terminal state while still listed. `job` is the **current** row, so
        /// its `elapsed` is the final runtime.
        case finishedInQueue(state: JobTerminalState)
        /// The job is simply gone. `job` is the **previous** row — there is nothing else left —
        /// and `lastState` is its normalised state as last seen.
        ///
        /// This is the common completion path, not an edge case: `squeue` drops finished jobs
        /// within seconds, so at a 10–30 s poll cadence most jobs are never observed in a terminal
        /// state at all.
        case disappeared(lastState: String)
    }

    public var kind: Kind
    public var job: Job

    public init(kind: Kind, job: Job) {
        self.kind = kind
        self.job = job
    }

    public var jobId: String { job.jobId }
}

public enum JobTransitions {

    /// States that mean "queued, not yet on the machine".
    ///
    /// `CONFIGURING` is here alongside `PENDING` because it is the state a job passes through
    /// while its nodes boot; a poll that lands on it would otherwise swallow the job's only
    /// `started` edge (see the widening note on `diff`).
    public static let waitingStates: Set<String> = ["PENDING", "CONFIGURING"]

    /// Diff two consecutive polls of one host's my-jobs list.
    ///
    /// - Parameters:
    ///   - previous: the last snapshot for this host, or `[]` if there is none.
    ///   - current: the snapshot that just landed.
    ///   - isBaseline: `true` when this poll must not produce notifications — the first success
    ///     after launch, after the host recovers from an error, or after the machine woke.
    ///     The App layer owns that decision; the engine only honours it (SPEC-P4 §2).
    /// - Returns: at most one transition per job id, in `previous` order.
    ///
    /// The three rules, stated once:
    ///
    /// * **started** — was waiting, is now `RUNNING`.
    /// * **finishedInQueue** — was not terminal, is now terminal.
    /// * **disappeared** — was not terminal, is now absent.
    ///
    /// Together they guarantee the invariant the feature actually needs: **every job produces
    /// exactly one finish notification**, whichever way it leaves.
    ///
    /// *Widening vs. SPEC-P4 §1, deliberate:* the spec words the finish rule as `RUNNING →`
    /// terminal and the started rule as `PENDING → RUNNING`. Taken literally, both leave silent
    /// holes — a job seen as `COMPLETING` and then as `COMPLETED` matches neither the finish rule
    /// (it was not `RUNNING`) nor the disappear rule (its last state was terminal), so it is never
    /// reported at all; likewise a job seen as `CONFIGURING` never "starts". Keying the rules on
    /// the terminal/waiting *predicates* rather than on single states closes both holes and is a
    /// strict superset of the spec's cases.
    public static func diff(previous: [Job], current: [Job], isBaseline: Bool) -> [JobTransition] {
        guard !isBaseline else { return [] }

        var currentById: [String: Job] = [:]
        currentById.reserveCapacity(current.count)
        // First occurrence wins, matching `tokenizeKv`'s convention. `squeue` does not repeat a
        // job id, so this only ever decides a pathological case.
        for job in current where currentById[job.jobId] == nil { currentById[job.jobId] = job }

        var seen: Set<String> = []
        var transitions: [JobTransition] = []

        for before in previous {
            guard seen.insert(before.jobId).inserted else { continue }
            let was = normalizedState(before.state)

            guard let after = currentById[before.jobId] else {
                // Gone. A row we already saw in a terminal state was reported by the finish rule
                // on the previous poll, so re-reporting it here would double up.
                if !isTerminal(was) {
                    transitions.append(JobTransition(kind: .disappeared(lastState: was), job: before))
                }
                continue
            }

            let now = normalizedState(after.state)
            if waitingStates.contains(was), now == "RUNNING" {
                transitions.append(JobTransition(kind: .started, job: after))
            } else if !isTerminal(was), let terminal = JobTerminalState(rawValue: now) {
                transitions.append(JobTransition(kind: .finishedInQueue(state: terminal), job: after))
            }
        }

        // Jobs present only in `current` are new submissions. There is no edge to report: the user
        // submitted them, and a job that appears already `RUNNING` was never observed to start.
        return transitions
    }

    /// The canonical form of a Slurm state token: trimmed, upper-cased, and cut at the first space
    /// so `scontrol`'s `CANCELLED by 41253` compares equal to `squeue`'s `CANCELLED`.
    public static func normalizedState(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return trimmed }
        return String(trimmed[trimmed.startIndex..<separator])
    }

    public static func isTerminal(_ state: String) -> Bool {
        JobTerminalState(slurmState: state) != nil
    }
}
