import Foundation
import Observation
import ServiceManagement

/// User-facing settings, backed by `UserDefaults`.
///
/// The Raycast extension has exactly one preference (`controlPersist`, read only by the SSH
/// layer). The app adds poll-interval overrides and the demo toggle, because a menubar app that
/// polls in the background has to let the user turn the volume down. Everything here is a value
/// with a default — there is no "unset" state for a view to handle.
@Observable
@MainActor
final class Preferences {

    /// Bounds from SPEC-P3 §14. A 5 s floor keeps a user from DoSing their own login node; the
    /// 120 s ceiling stops "polling" from silently becoming "never".
    static let pollRange: ClosedRange<Int> = 5...120

    enum Key {
        static let controlPersist = "controlPersist"
        static let jobsPollSeconds = "jobsPollSeconds"
        static let nodesPollSeconds = "nodesPollSeconds"
        static let demoMode = "demoMode"
        static let activeHosts = "activeHosts"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyOnStart = "notifyOnJobStart"
        static let notifyOnFinish = "notifyOnJobFinish"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.controlPersist = (defaults.string(forKey: Key.controlPersist) ?? "").isEmpty
            ? "12h" : defaults.string(forKey: Key.controlPersist)!
        self.jobsPollSeconds = Self.clamped(defaults.object(forKey: Key.jobsPollSeconds) as? Int ?? 10)
        self.nodesPollSeconds = Self.clamped(defaults.object(forKey: Key.nodesPollSeconds) as? Int ?? 30)
        self.demoModeDefault = defaults.bool(forKey: Key.demoMode)
        // Opt-in, per SPEC-P4 §5: an app that asks for notification permission before the user has
        // asked for notifications is the thing everybody turns off and never turns back on.
        self.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        // …but once it is on, both kinds are on: `object(forKey:)` distinguishes "never set" from
        // "set to false", which `bool(forKey:)` cannot.
        self.notifyOnStart = defaults.object(forKey: Key.notifyOnStart) as? Bool ?? true
        self.notifyOnFinish = defaults.object(forKey: Key.notifyOnFinish) as? Bool ?? true
    }

    // MARK: - Notifications

    /// The master toggle (SPEC-P4 §5). Written by `JobNotifier` only after macOS has actually
    /// granted authorization — never straight from the Settings checkbox, which would leave the
    /// app claiming a permission it does not have.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    var notifyOnStart: Bool {
        didSet { defaults.set(notifyOnStart, forKey: Key.notifyOnStart) }
    }

    var notifyOnFinish: Bool {
        didSet { defaults.set(notifyOnFinish, forKey: Key.notifyOnFinish) }
    }

    /// `ControlPersist`, fed straight to the transport. Blank falls back to `12h` there too, so a
    /// user who clears the field gets the default rather than a broken ssh invocation.
    var controlPersist: String {
        didSet { defaults.set(controlPersist, forKey: Key.controlPersist) }
    }

    /// My Jobs / All Jobs poll cadence while the popover is open. Inventory default: 10 s.
    var jobsPollSeconds: Int {
        didSet {
            jobsPollSeconds = Self.clamped(jobsPollSeconds)
            defaults.set(jobsPollSeconds, forKey: Key.jobsPollSeconds)
        }
    }

    /// Nodes poll cadence. Inventory default: 30 s (the Info tab derives 2× from this).
    var nodesPollSeconds: Int {
        didSet {
            nodesPollSeconds = Self.clamped(nodesPollSeconds)
            defaults.set(nodesPollSeconds, forKey: Key.nodesPollSeconds)
        }
    }

    /// The hidden demo flag. `SLURMBAR_DEMO=1` in the environment wins over it and is what CI and
    /// the snapshot runner use; this toggle is for a human poking at the app.
    var demoModeDefault: Bool {
        didSet { defaults.set(demoModeDefault, forKey: Key.demoMode) }
    }

    // MARK: - Launch at login

    /// `SMAppService.mainApp` — the modern, entitlement-free login item API.
    ///
    /// It refuses to register an unsigned bundle, which is every local Debug build until Phase 5
    /// brings Developer ID. The toggle therefore reports its error rather than silently lying.
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Active hosts

    /// The persisted active-cluster list: a JSON string array under `activeHosts`.
    ///
    /// Deliberately a **fresh store** — no migration from the extension's Raycast `LocalStorage`
    /// (ARCHITECTURE.md § App design). The two keep their own selections on purpose; they do
    /// share the ssh ControlMaster, which is the part that actually matters.
    func loadActiveHosts() -> [String] {
        guard let raw = defaults.string(forKey: Key.activeHosts),
            let data = raw.data(using: .utf8),
            let hosts = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return hosts
    }

    func saveActiveHosts(_ hosts: [String]) {
        guard let data = try? JSONEncoder().encode(hosts), let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: Key.activeHosts)
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, pollRange.lowerBound), pollRange.upperBound)
    }
}
