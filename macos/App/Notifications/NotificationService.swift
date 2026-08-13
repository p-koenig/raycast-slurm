import AppKit
import Foundation
import SlurmKit
import UserNotifications

/// One notification, fully resolved: the copy plus the one delivery decision that depends on it.
///
/// Building this is separated from posting it so the copy is a value that can be read, logged and
/// reasoned about — and so `JobNotifier` never has to know what a `UNMutableNotificationContent`
/// is.
struct JobNotificationContent: Equatable, Sendable {
    /// Stable per (host, job, kind). `UNUserNotificationCenter` replaces an already-delivered
    /// notification with the same identifier, which is exactly what we want if the same edge is
    /// somehow reported twice: one entry in Notification Centre, not two.
    var identifier: String
    var title: String
    var body: String
    /// Groups a cluster's notifications together in Notification Centre.
    var thread: String
    /// `FAILED` / `TIMEOUT` — the states worth interrupting a Focus for (SPEC-P4 §4).
    var timeSensitive: Bool
}

/// The delivery copy, exactly as SPEC-P4 §4 specifies it.
enum JobNotificationCopy {

    static func started(job: Job, host: String) -> JobNotificationContent {
        JobNotificationContent(
            identifier: identifier(host: host, jobId: job.jobId, kind: "started"),
            title: "Job \(job.jobId) started",
            body: "\(job.name) on \(host)",
            thread: host,
            timeSensitive: false
        )
    }

    /// The finish notification, in both of its shapes.
    ///
    /// - Parameters:
    ///   - state: `nil` when the job vanished from `squeue` and the one `scontrol` lookup could
    ///     not resolve a final state. That is the "finished, no state" copy — never a guess.
    ///   - runTime: `scontrol`'s `RunTime` when we have it; the job's last-seen `elapsed` is used
    ///     as the fallback, and if neither parses as a duration the `— ran …` clause is dropped
    ///     rather than printed empty.
    static func finished(
        job: Job,
        host: String,
        state: JobTerminalState?,
        runTime: String? = nil
    ) -> JobNotificationContent {
        let identifier = identifier(host: host, jobId: job.jobId, kind: "finished")
        let subject = "\(job.name) on \(host)"

        // No state resolved: the stateless shape, and no runtime either — we would be quoting an
        // `elapsed` from a poll that is by definition older than the job's actual end.
        guard let state else {
            return JobNotificationContent(
                identifier: identifier,
                title: "Job \(job.jobId) finished",
                body: subject,
                thread: host,
                timeSensitive: false
            )
        }

        let elapsed = elapsedPhrase(runTime) ?? elapsedPhrase(job.elapsed)
        return JobNotificationContent(
            identifier: identifier,
            title: "Job \(job.jobId) \(label(state))",
            body: elapsed.map { "\(subject) — ran \($0)" } ?? subject,
            thread: host,
            timeSensitive: state.isFailure
        )
    }

    /// `Completed` / `Failed` / `Cancelled` / `Timeout` / `Preempted`.
    static func label(_ state: JobTerminalState) -> String {
        state.rawValue.prefix(1) + state.rawValue.dropFirst().lowercased()
    }

    /// `"2:14:07"` → `"2h 14m"`. `nil` for the sentinels Slurm prints when a job never ran
    /// (`"0:00"`, `"INVALID"`, `""`), so the body says nothing rather than "ran 0s".
    static func elapsedPhrase(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let seconds = SlurmFormat.parseSlurmDurationSeconds(raw.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        else { return nil }
        return SlurmFormat.formatDurationSeconds(seconds)
    }

    private static func identifier(host: String, jobId: String, kind: String) -> String {
        "slurmbar.\(host).\(jobId).\(kind)"
    }
}

/// The `UNUserNotificationCenter` side of the feature: authorization, posting, and what a click
/// does.
///
/// Nothing in here is touched until the user turns the master toggle on. That matters beyond
/// politeness — `UNUserNotificationCenter.current()` requires a registered bundle, and the
/// snapshot runner (`SLURMBAR_SNAPSHOT_DIR`) must be able to render every screen without any of
/// this existing. `JobNotifier` is never started in snapshot mode, so this class is never
/// constructed there either.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    enum Authorization: Equatable, Sendable {
        case notRequested
        case granted
        case denied
        /// The request itself failed — the usual cause on a development build is an unsigned or
        /// unregistered bundle, which is worth showing verbatim rather than reporting as "denied".
        case failed(String)
    }

    private var delegateInstalled = false

    /// Resolved lazily, never stored: see the class note.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Ask macOS for permission. SPEC-P4 §4: this is called when the master toggle is first turned
    /// on, never at launch.
    func requestAuthorization() async -> Authorization {
        installDelegate()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? .granted : .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The current system-level setting, which the user can change in System Settings behind our
    /// back. Read when the Settings tab appears so the toggle does not claim to work when it
    /// cannot.
    func currentAuthorization() async -> Authorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
    }

    func post(_ content: JobNotificationContent) async {
        installDelegate()

        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        payload.sound = .default
        payload.threadIdentifier = content.thread
        // `.timeSensitive` needs the matching entitlement to actually breach a Focus; without one
        // the system silently treats the notification as `.active`, which is the behaviour we want
        // anyway. Signing (and therefore entitlements) is Phase 5 — setting it now costs nothing
        // and starts working the moment the app is signed.
        payload.interruptionLevel = content.timeSensitive ? .timeSensitive : .active

        // `nil` trigger = deliver now.
        let request = UNNotificationRequest(identifier: content.identifier, content: payload, trigger: nil)
        do {
            try await center.add(request)
            Trace.log("notification: \(content.title) — \(content.body)")
        } catch {
            Trace.log("notification failed: \(error.localizedDescription)")
        }
    }

    /// What macOS says it is currently showing for this app. Only used by the launch-simulation
    /// affordance, where "the post call did not throw" is a weaker claim than "the system lists
    /// it as delivered".
    func deliveredDescriptions() async -> [String] {
        await center.deliveredNotifications().map {
            "\($0.request.identifier) | \($0.request.content.title) | \($0.request.content.body)"
        }
    }

    private func installDelegate() {
        guard !delegateInstalled else { return }
        delegateInstalled = true
        center.delegate = self
    }

    // MARK: - Delegate

    /// Show the banner even when SlurmBar happens to be the frontmost app. Without this macOS
    /// suppresses it, which reads as "notifications are broken".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// SPEC-P4 §4: a click activates the app.
    ///
    /// There is deliberately no deep link to the job. `MenuBarExtra` exposes no public API to open
    /// its popover programmatically, and the alternatives (synthesising a click at the status
    /// item's screen coordinates, or private `NSStatusItem` SPI) are exactly the kind of thing
    /// that breaks on a macOS point release. So: activate, and if the debug window is up, raise
    /// it — never pretend the popover opened.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { NotificationService.activateApp() }
    }

    static func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DebugWindow.bringForward()
    }
}
