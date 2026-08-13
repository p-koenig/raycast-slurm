import Foundation
import Testing

@testable import SlurmKit

// `Parse/JobTransitions.swift` has no golden fixtures — there is no TypeScript original to export
// from, the notification engine is new in the macOS app. These are therefore hand-written unit
// tests, and they are the only thing standing between the feature and its two failure modes:
// silence (a job finishes and the user is never told) and duplicates.
//
// Every case is built from `job(...)`, so a test names only the fields it is about.

/// A `squeue` row with plausible filler for everything the transition engine ignores.
private func job(
    _ jobId: String,
    _ state: String,
    name: String = "train",
    elapsed: String = "1:02:03",
    partition: String = "gpu"
) -> Job {
    Job(
        jobId: jobId,
        partition: partition,
        name: name,
        state: state,
        elapsed: elapsed,
        timeLimit: "1-00:00:00",
        nodes: "1",
        cpus: "16",
        reasonOrNodeList: state == "RUNNING" ? "gpu01" : "(Resources)",
        tres: "cpu=16,mem=64G,gres/gpu=2"
    )
}

/// The engine is always called with `isBaseline: false` except in the baseline suite; this keeps
/// the call sites about the states under test.
private func diff(_ previous: [Job], _ current: [Job]) -> [JobTransition] {
    JobTransitions.diff(previous: previous, current: current, isBaseline: false)
}

@Suite("JobTransitions: started")
struct JobTransitionsStartedTests {

    @Test("PENDING → RUNNING emits started")
    func pendingToRunning() throws {
        let transitions = diff([job("145847", "PENDING")], [job("145847", "RUNNING")])
        #expect(transitions.count == 1)
        #expect(transitions.first?.kind == .started)
        #expect(transitions.first?.jobId == "145847")
    }

    @Test("started carries the CURRENT row, so its elapsed and node list are the fresh ones")
    func startedCarriesCurrent() throws {
        let transitions = diff(
            [job("145847", "PENDING", elapsed: "0:00")],
            [job("145847", "RUNNING", elapsed: "0:12")]
        )
        let transition = try #require(transitions.first)
        #expect(transition.job.elapsed == "0:12")
        #expect(transition.job.reasonOrNodeList == "gpu01")
    }

    @Test(
        "A job that does not change state emits nothing",
        arguments: ["PENDING", "RUNNING", "COMPLETING", "SUSPENDED", "COMPLETED"]
    )
    func noChange(state: String) {
        #expect(diff([job("1", state)], [job("1", state)]).isEmpty)
    }

    @Test("CONFIGURING → RUNNING also emits started (documented widening of SPEC-P4 §1)")
    func configuringToRunning() {
        let transitions = diff([job("1", "CONFIGURING")], [job("1", "RUNNING")])
        #expect(transitions.map(\.kind) == [.started])
    }

    @Test("PENDING → CONFIGURING is not yet a start")
    func pendingToConfiguring() {
        #expect(diff([job("1", "PENDING")], [job("1", "CONFIGURING")]).isEmpty)
    }

    @Test("A job seen for the first time already RUNNING emits nothing — no start was observed")
    func appearsRunning() {
        #expect(diff([job("1", "RUNNING")], [job("1", "RUNNING"), job("2", "RUNNING")]).isEmpty)
    }

    @Test("A newly submitted PENDING job emits nothing")
    func appearsPending() {
        #expect(diff([], [job("2", "PENDING")]).isEmpty)
    }
}

@Suite("JobTransitions: finished in queue")
struct JobTransitionsFinishedTests {

    @Test(
        "RUNNING → a terminal state emits finishedInQueue carrying that state",
        arguments: JobTerminalState.allCases
    )
    func runningToTerminal(state: JobTerminalState) throws {
        let transitions = diff([job("9", "RUNNING")], [job("9", state.rawValue)])
        #expect(transitions.map(\.kind) == [.finishedInQueue(state: state)])
    }

    @Test("finishedInQueue carries the CURRENT row, so elapsed is the final runtime")
    func finishedCarriesCurrent() throws {
        let transitions = diff(
            [job("9", "RUNNING", elapsed: "2:00:00")],
            [job("9", "COMPLETED", elapsed: "2:14:07")]
        )
        let transition = try #require(transitions.first)
        #expect(transition.job.elapsed == "2:14:07")
    }

    @Test("RUNNING → COMPLETING is not a finish: the job is still on the machine")
    func runningToCompleting() {
        #expect(diff([job("9", "RUNNING")], [job("9", "COMPLETING")]).isEmpty)
    }

    @Test("COMPLETING → COMPLETED is a finish (documented widening of SPEC-P4 §1)")
    func completingToCompleted() {
        let transitions = diff([job("9", "COMPLETING")], [job("9", "COMPLETED")])
        #expect(transitions.map(\.kind) == [.finishedInQueue(state: .completed)])
    }

    @Test("PENDING → CANCELLED is a finish: a job killed in the queue still ended")
    func pendingToCancelled() {
        let transitions = diff([job("9", "PENDING")], [job("9", "CANCELLED")])
        #expect(transitions.map(\.kind) == [.finishedInQueue(state: .cancelled)])
    }

    @Test("A job that stays in a terminal state emits nothing — it was reported on the poll before")
    func terminalToTerminal() {
        #expect(diff([job("9", "COMPLETED")], [job("9", "COMPLETED")]).isEmpty)
        #expect(diff([job("9", "FAILED")], [job("9", "CANCELLED")]).isEmpty)
    }

    @Test("A state no cluster documents is not terminal, so it produces no finish")
    func unknownState() {
        #expect(diff([job("9", "RUNNING")], [job("9", "SPECIAL_EXIT")]).isEmpty)
    }
}

@Suite("JobTransitions: disappeared")
struct JobTransitionsDisappearedTests {

    @Test(
        "A non-terminal job that vanishes emits disappeared with its last-seen state",
        arguments: ["RUNNING", "COMPLETING", "PENDING", "CONFIGURING", "SUSPENDED"]
    )
    func vanishes(state: String) throws {
        let transitions = diff([job("6644_33", state)], [])
        #expect(transitions.map(\.kind) == [.disappeared(lastState: state)])
        #expect(transitions.first?.jobId == "6644_33")
    }

    @Test("disappeared carries the PREVIOUS row — it is the only copy left")
    func carriesPrevious() throws {
        let transitions = diff([job("42", "RUNNING", name: "sd3-finetune", elapsed: "9:41:02")], [])
        let transition = try #require(transitions.first)
        #expect(transition.job.name == "sd3-finetune")
        #expect(transition.job.elapsed == "9:41:02")
    }

    @Test(
        "A job already seen in a terminal state emits nothing when it vanishes",
        arguments: JobTerminalState.allCases
    )
    func terminalVanishes(state: JobTerminalState) {
        #expect(diff([job("42", state.rawValue)], []).isEmpty)
    }

    @Test("scontrol's reason tail is normalised away, so CANCELLED by <uid> still counts as terminal")
    func cancelledWithReason() {
        #expect(diff([job("42", "CANCELLED by 41253")], []).isEmpty)
    }

    @Test("The whole list emptying reports every job that was still live")
    func everythingVanishes() {
        let previous = [job("1", "RUNNING"), job("2", "PENDING"), job("3", "COMPLETED")]
        let transitions = diff(previous, [])
        #expect(
            transitions.map(\.kind) == [
                .disappeared(lastState: "RUNNING"),
                .disappeared(lastState: "PENDING"),
            ]
        )
    }
}

@Suite("JobTransitions: baseline and empty polls")
struct JobTransitionsBaselineTests {

    @Test("A baseline poll emits nothing, however much changed")
    func baselineIsSilent() {
        let previous = [job("1", "PENDING"), job("2", "RUNNING"), job("3", "RUNNING")]
        let current = [job("1", "RUNNING"), job("2", "FAILED")]
        #expect(JobTransitions.diff(previous: previous, current: current, isBaseline: true).isEmpty)
        // The same inputs are loud when the poll is not a baseline — i.e. the guard, not the data,
        // is what silences it.
        #expect(JobTransitions.diff(previous: previous, current: current, isBaseline: false).count == 3)
    }

    @Test("The first poll after launch has no previous snapshot and so emits nothing")
    func firstPoll() {
        #expect(diff([], [job("1", "RUNNING"), job("2", "PENDING")]).isEmpty)
    }

    @Test("Two empty polls emit nothing")
    func bothEmpty() {
        #expect(diff([], []).isEmpty)
    }
}

@Suite("JobTransitions: multi-job polls")
struct JobTransitionsMixTests {

    @Test("One poll can carry every kind of transition at once, in previous order")
    func mixedPoll() {
        let previous = [
            job("10", "PENDING"),  // → started
            job("11", "RUNNING"),  // → finishedInQueue(.failed)
            job("12", "RUNNING"),  // → disappeared
            job("13", "RUNNING"),  // unchanged
            job("14", "COMPLETED"),  // vanishes, already reported
        ]
        let current = [
            job("13", "RUNNING"),
            job("11", "FAILED"),
            job("10", "RUNNING"),
            job("15", "PENDING"),  // brand new
        ]
        let transitions = diff(previous, current)
        #expect(transitions.map(\.jobId) == ["10", "11", "12"])
        #expect(
            transitions.map(\.kind) == [
                .started,
                .finishedInQueue(state: .failed),
                .disappeared(lastState: "RUNNING"),
            ]
        )
    }

    @Test("Array tasks are individual job ids — no aggregation in v1")
    func arrayTasks() {
        let previous = [job("6644_33", "RUNNING"), job("6644_34", "RUNNING"), job("6644_35", "RUNNING")]
        let current = [job("6644_34", "RUNNING")]
        let transitions = diff(previous, current)
        #expect(transitions.map(\.jobId) == ["6644_33", "6644_35"])
        #expect(transitions.allSatisfy { $0.kind == .disappeared(lastState: "RUNNING") })
    }

    @Test("A pending array range and one of its running tasks are unrelated ids")
    func arrayRangeAndTask() {
        let previous = [job("5818_[28-50%2]", "PENDING"), job("5818_27", "RUNNING")]
        let current = [job("5818_[29-50%2]", "PENDING"), job("5818_28", "RUNNING")]
        let transitions = diff(previous, current)
        // Neither previous id survives verbatim, so both read as gone; nothing is aggregated into
        // the array's base id.
        #expect(transitions.map(\.jobId) == ["5818_[28-50%2]", "5818_27"])
    }

    @Test("A duplicated previous row is reported once")
    func duplicatePrevious() {
        let transitions = diff([job("1", "RUNNING"), job("1", "RUNNING")], [])
        #expect(transitions.count == 1)
    }

    @Test("A job id appearing twice in current resolves to its first row")
    func duplicateCurrent() {
        let transitions = diff([job("1", "RUNNING")], [job("1", "FAILED"), job("1", "COMPLETED")])
        #expect(transitions.map(\.kind) == [.finishedInQueue(state: .failed)])
    }
}

@Suite("JobTerminalState")
struct JobTerminalStateTests {

    @Test("Every terminal state parses from its bare squeue token", arguments: JobTerminalState.allCases)
    func bareToken(state: JobTerminalState) {
        #expect(JobTerminalState(slurmState: state.rawValue) == state)
    }

    @Test(
        "Parsing is tolerant of the shapes scontrol and squeue actually print",
        arguments: [
            ("CANCELLED by 41253", JobTerminalState.cancelled),
            ("  COMPLETED  ", .completed),
            ("failed", .failed),
            ("Timeout", .timeout),
            ("PREEMPTED\n", .preempted),
        ]
    )
    func tolerantShapes(raw: String, expected: JobTerminalState) {
        #expect(JobTerminalState(slurmState: raw) == expected)
    }

    @Test(
        "Live and invented states are not terminal",
        arguments: ["RUNNING", "PENDING", "COMPLETING", "CONFIGURING", "SUSPENDED", "OUT_OF_MEMORY", "NODE_FAIL", ""]
    )
    func notTerminal(raw: String) {
        #expect(JobTerminalState(slurmState: raw) == nil)
        #expect(JobTransitions.isTerminal(raw) == false)
    }

    @Test("Only FAILED and TIMEOUT read as failures")
    func failureStates() {
        #expect(JobTerminalState.allCases.filter(\.isFailure) == [.failed, .timeout])
    }

    @Test(
        "normalizedState trims, upper-cases and cuts at the first space",
        arguments: [
            ("running", "RUNNING"),
            (" COMPLETING ", "COMPLETING"),
            ("CANCELLED by 41253", "CANCELLED"),
            ("\tFAILED\t", "FAILED"),
            ("", ""),
        ]
    )
    func normalize(raw: String, expected: String) {
        #expect(JobTransitions.normalizedState(raw) == expected)
    }
}
