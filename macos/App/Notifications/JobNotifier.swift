import AppKit
import Foundation
import Observation
import SlurmKit

/// Job-state notifications (SPEC-P4).
///
/// The split is the point: `SlurmKit.JobTransitions` decides *what changed* and is a pure function
/// with a full unit suite; this class owns everything stateful and untestable around it — the
/// per-host snapshots, the baseline rules, the single `scontrol` lookup that resolves a vanished
/// job's final state, and the hand-off to `UNUserNotificationCenter`.
///
/// It is fed by **both** my-jobs polls: the 10 s one while the popover is open and the 30 s
/// `listJobsBrief` label tick while it is closed. That is not an optimisation — the popover is
/// closed essentially always, so the background tick is the path that actually delivers
/// notifications.
@Observable
@MainActor
final class JobNotifier {

    private let preferences: Preferences
    private let transport: any SshTransport
    private let service = NotificationService()
    private let demoMode: Bool

    /// The last successful my-jobs snapshot per host, and which hosts have one that may be
    /// diffed. The two are separate because a host can have a snapshot that is no longer
    /// trustworthy (it errored, or the machine slept) — the snapshot is dropped and the host
    /// leaves `baselined`, so its next success is a baseline again.
    private var snapshots: [String: [Job]] = [:]
    private var baselined: Set<String> = []

    private var wakeObservers: [NSObjectProtocol] = []
    private var started = false

    /// What macOS currently thinks, surfaced in the Settings tab so a toggle that cannot work
    /// says why.
    private(set) var authorization: NotificationService.Authorization = .notRequested

    init(preferences: Preferences, transport: any SshTransport, demoMode: Bool) {
        self.preferences = preferences
        self.transport = transport
        self.demoMode = demoMode
    }

    // MARK: - Lifecycle

    /// Called from `AppModel.start()`, which the snapshot runner deliberately never invokes — so
    /// rendering screenshots never touches `UNUserNotificationCenter`.
    func start() {
        guard !started else { return }
        started = true
        observeWake()
        guard preferences.notificationsEnabled else { return }
        Task { self.authorization = await self.service.currentAuthorization() }
    }

    /// SPEC-P4 §2: forget every snapshot, so the next poll per host is a baseline and produces
    /// nothing. Called on wake, on enable, and whenever the master toggle is off.
    func resetBaselines() {
        snapshots.removeAll()
        baselined.removeAll()
    }

    /// A machine that has been asleep for a day would otherwise diff against a day-old snapshot
    /// and fire a burst of notifications about jobs the user has long since forgotten.
    ///
    /// Both notifications are observed because they are different events: `didWake` is the machine
    /// resuming, `screensDidWake` is the display coming back — and `AppModel` suspends its poll
    /// loops on `screensDidSleep`, so that is the edge which restarts polling. Registering here
    /// (synchronously, on the same notification) means the reset lands before the restarted poll's
    /// first tick, which runs in a `Task`.
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetBaselines() }
            }
        }
    }

    // MARK: - The master toggle

    /// Turning notifications on. SPEC-P4 §4: authorization is requested here, on first enable —
    /// not at launch, and not speculatively.
    ///
    /// Returns the outcome so the Settings tab can flip its own toggle back and explain itself;
    /// the preference is only written when macOS actually said yes.
    @discardableResult
    func enable() async -> NotificationService.Authorization {
        let outcome = await service.requestAuthorization()
        authorization = outcome
        preferences.notificationsEnabled = (outcome == .granted)
        // Either way we start from a clean slate: on success so that enabling does not replay
        // everything that happened while it was off, on failure so nothing is left behind.
        resetBaselines()
        return outcome
    }

    func disable() {
        preferences.notificationsEnabled = false
        resetBaselines()
    }

    /// Re-read the system setting (the user can revoke permission in System Settings at any time).
    func refreshAuthorization() async {
        authorization = await service.currentAuthorization()
        // Permission revoked behind our back: stop claiming the feature is on.
        if authorization == .denied, preferences.notificationsEnabled {
            preferences.notificationsEnabled = false
            resetBaselines()
        }
    }

    // MARK: - The poll hook

    /// Consume one my-jobs poll. Synchronous on purpose: the snapshot bookkeeping happens before
    /// the first `await`, so two overlapping polls can never diff against the same `previous` and
    /// emit the same transition twice.
    func handle(_ results: [ClusterResult<[Job]>]) {
        guard preferences.notificationsEnabled else {
            // While the toggle is off we keep no history whatsoever.
            if !snapshots.isEmpty || !baselined.isEmpty { resetBaselines() }
            return
        }

        for result in results {
            switch result {
            case .failed(let host, _):
                // SPEC-P4 §2: a host that errored gets a fresh baseline when it recovers. Its old
                // snapshot describes a moment we can no longer place in time.
                snapshots[host] = nil
                baselined.remove(host)

            case .ok(let host, let jobs):
                let previous = snapshots[host] ?? []
                let isBaseline = !baselined.contains(host)
                snapshots[host] = jobs
                baselined.insert(host)

                let transitions = JobTransitions.diff(previous: previous, current: jobs, isBaseline: isBaseline)
                guard !transitions.isEmpty else { continue }
                Task { await self.deliver(transitions, host: host) }
            }
        }

        // Deselecting a cluster must not leave a snapshot behind that fires a burst of
        // "disappeared" notifications the next time it is selected.
        let live = Set(results.map(\.host))
        snapshots = snapshots.filter { live.contains($0.key) }
        baselined.formIntersection(live)
    }

    // MARK: - Delivery

    private func deliver(_ transitions: [JobTransition], host: String) async {
        for transition in transitions {
            switch transition.kind {
            case .started:
                guard preferences.notifyOnStart else { continue }
                await service.post(JobNotificationCopy.started(job: transition.job, host: host))

            case .finishedInQueue(let state):
                guard preferences.notifyOnFinish else { continue }
                // The row is right there in the terminal state; no lookup needed.
                await service.post(
                    JobNotificationCopy.finished(job: transition.job, host: host, state: state)
                )

            case .disappeared:
                guard preferences.notifyOnFinish else { continue }
                let final = await resolveFinalState(host: host, job: transition.job)
                await service.post(
                    JobNotificationCopy.finished(
                        job: transition.job,
                        host: host,
                        state: final.state,
                        runTime: final.runTime
                    )
                )
            }
        }
    }

    /// SPEC-P4 §3: **one** `scontrol show job` for a job that vanished from `squeue`.
    ///
    /// `scontrol` keeps a finished job visible for `MinJobAge` (a few minutes on both of our
    /// clusters), which is comfortably longer than a poll interval — so most of the time this
    /// upgrades a bare "finished" into "Completed"/"Failed" with a real runtime. When it does not,
    /// we notify without a state and **never retry**: a job `scontrol` has already forgotten will
    /// not come back, and a host that is down would otherwise turn one lost job into an endless
    /// retry loop against a cluster that cannot answer.
    private func resolveFinalState(host: String, job: Job) async -> (state: JobTerminalState?, runTime: String?) {
        do {
            let detail = try await SlurmClient(host: host, transport: transport).showJob(jobId: job.jobId)
            let state = detail.fields["JobState"].flatMap { JobTerminalState(slurmState: $0) }
            return (state, detail.fields["RunTime"])
        } catch {
            Trace.log("final state for \(job.jobId) on \(host) unresolved: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    // MARK: - Demo hook

    /// SPEC-P4 §6: the hidden "Simulate transition" button in demo mode.
    ///
    /// It fabricates the two `squeue` snapshots either side of a job failing and pushes them
    /// through the **real** engine and the **real** delivery path — `JobTransitions.diff`, the
    /// copy builder, `UNUserNotificationCenter`. Nothing about the notification that appears is
    /// special-cased, which is the entire point: it is how a human (and an agent with no cluster)
    /// verifies the feature end to end.
    ///
    /// The `RUNNING → FAILED` edge is chosen because it exercises the most: a terminal state
    /// label, the `— ran …` clause, and the `.timeSensitive` interruption level.
    func simulateTransition() async {
        let host = demoMode ? (Demo.hosts.first?.name ?? "phoenix") : "demo"
        let sample = Job(
            jobId: "145789",
            partition: "gpu",
            name: "sd3-finetune",
            state: "RUNNING",
            elapsed: "2:14:07",
            timeLimit: "1-00:00:00",
            nodes: "1",
            cpus: "16",
            reasonOrNodeList: "gpu01",
            tres: "cpu=16,mem=64G,gres/gpu:a100=2"
        )
        var failed = sample
        failed.state = "FAILED"

        let transitions = JobTransitions.diff(previous: [sample], current: [failed], isBaseline: false)
        await deliver(transitions, host: host)
    }

    /// `SLURMBAR_SIMULATE_NOTIFICATION=1` — the same button, pressed from a shell.
    ///
    /// It exists for one reason: the "Simulate transition" button lives in the `Settings` scene,
    /// which cannot be driven from a command line, and delivery is the one part of this app that
    /// a snapshot cannot evidence. So this turns the master toggle on exactly as the checkbox
    /// does (`enable()`, authorization prompt and all) and then presses the button. Nothing is
    /// stubbed: the notification that appears came through `UNUserNotificationCenter`.
    ///
    /// Progress goes to stderr unconditionally — the whole point is to be readable from the
    /// process that launched the app.
    func runLaunchSimulation() async {
        func report(_ message: String) {
            FileHandle.standardError.write(Data("[slurmbar] simulate: \(message)\n".utf8))
        }

        let authorization = await enable()
        report("authorization = \(authorization)")
        guard authorization == .granted else {
            report("not delivering — macOS did not authorize notifications")
            return
        }
        await simulateTransition()
        report("posted")

        // Read the system's own delivered list back. `post` not throwing only proves the request
        // was accepted; this proves macOS delivered it.
        let delivered = await service.deliveredDescriptions()
        report("delivered = \(delivered.count)")
        for entry in delivered { report("  \(entry)") }
    }
}
