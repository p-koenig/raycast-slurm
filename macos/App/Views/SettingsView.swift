import ServiceManagement
import SlurmKit
import SwiftUI

/// The `Settings` scene (SPEC-P3 §14). Reachable from the popover's gear via `SettingsLink`.
struct SettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 460, height: 320)
    }
}

private struct GeneralSettings: View {

    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                TextField("Session timeout", text: $preferences.controlPersist)
                    .help("OpenSSH ControlPersist — how long a multiplexed connection stays alive when idle.")
                Text(
                    "Passed to ssh as `ControlPersist`. A longer value means fewer 2FA prompts; "
                        + "changes apply to connections opened after a restart."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Polling") {
                Stepper(
                    "Jobs: every \(preferences.jobsPollSeconds)s",
                    value: $preferences.jobsPollSeconds,
                    in: Preferences.pollRange
                )
                Stepper(
                    "Nodes: every \(preferences.nodesPollSeconds)s",
                    value: $preferences.nodesPollSeconds,
                    in: Preferences.pollRange
                )
                Text("Polling only runs while the popover is open. The menubar count refreshes every 30s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try model.preferences.setLaunchAtLogin(enabled)
                            launchError = nil
                        } catch {
                            // Registration refuses unsigned bundles, which is every local Debug
                            // build until Phase 5 brings Developer ID. Say so rather than
                            // silently leaving the toggle on.
                            launchError = error.localizedDescription
                            launchAtLogin = model.preferences.launchAtLogin
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(Palette.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.preferences.launchAtLogin }
    }
}

/// Job-state notifications (SPEC-P4 §5).
///
/// Three switches and no per-host granularity: the useful question is "tell me when my jobs
/// start / finish", and a per-cluster matrix would be a settings screen nobody finishes reading.
private struct NotificationSettings: View {

    @Environment(AppModel.self) private var model

    /// Mirrors `preferences.notificationsEnabled`, but is the thing the checkbox is actually
    /// bound to. The preference is only written once macOS grants authorization, so a denied
    /// request has to be able to snap this back — which it cannot do if the checkbox writes
    /// straight through.
    @State private var enabled = false
    @State private var explanation: String?
    @State private var simulated = false

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                // A `Binding` rather than `$enabled` + `.onChange`: `.onChange` also fires when
                // `.task` syncs this from the preference, which would ask macOS for authorization
                // merely because the user opened Settings. A binding's setter runs only when the
                // checkbox is actually clicked.
                Toggle(
                    "Notify me about my jobs",
                    isOn: Binding(
                        get: { enabled },
                        set: { on in
                            enabled = on
                            Task { await apply(on) }
                        }
                    )
                )
                Text(
                    "Job states are compared between polls. The first check after launch, after a "
                        + "cluster recovers from an error, and after your Mac wakes never notifies — "
                        + "otherwise you would get a burst about jobs that finished while you were away."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let explanation {
                    Label(explanation, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle("When a job starts", isOn: $preferences.notifyOnStart)
                Toggle("When a job finishes", isOn: $preferences.notifyOnFinish)
                Text(
                    "Finished covers completed, failed, cancelled, timed out and preempted — including "
                        + "the usual case where Slurm drops the job from squeue before any of those is "
                        + "ever visible."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            // SPEC-P4 §6: the hidden demo hook. It is the only way to see a real notification
            // without a cluster, so it is deliberately wired to the real delivery path.
            if model.demoMode {
                Section {
                    Button(simulated ? "Notification sent" : "Simulate transition") {
                        simulated = true
                        Task { await model.notifier.simulateTransition() }
                    }
                    .disabled(!enabled)
                    Text("Demo mode only. Runs a fabricated RUNNING → FAILED job through the real engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.notifier.refreshAuthorization()
            enabled = model.preferences.notificationsEnabled
            explanation = Self.explain(model.notifier.authorization, enabled: enabled)
        }
    }

    private func apply(_ on: Bool) async {
        guard on else {
            model.notifier.disable()
            explanation = nil
            return
        }
        // Authorization is requested here — on first enable, not at launch (SPEC-P4 §4).
        let outcome = await model.notifier.enable()
        enabled = model.preferences.notificationsEnabled
        explanation = Self.explain(outcome, enabled: enabled)
    }

    private static func explain(_ authorization: NotificationService.Authorization, enabled: Bool) -> String? {
        switch authorization {
        case .granted, .notRequested:
            return nil
        case .denied:
            return "macOS is blocking notifications for SlurmBar. Turn them on in System Settings › "
                + "Notifications › SlurmBar, then switch this back on."
        case .failed(let message):
            return "Couldn't ask for notification permission: \(message)"
        }
    }
}

private struct AdvancedSettings: View {

    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Toggle("Demo mode", isOn: $preferences.demoModeDefault)
                Text(
                    "Serves the bundled sample clusters instead of connecting over SSH. "
                        + "Takes effect on the next launch. The SLURMBAR_DEMO=1 environment variable "
                        + "forces it on regardless."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if model.demoMode {
                    Label("Demo mode is active in this session.", systemImage: "theatermasks")
                        .font(.caption)
                        .foregroundStyle(Palette.blue)
                }
            }

            Section {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    Clipboard.copy(diagnostics())
                    copied = true
                }
                Text("Version, active clusters, poll intervals and the ControlPath — no credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
            SlurmBar \(info["CFBundleShortVersionString"] as? String ?? "?") \
            (\(info["CFBundleVersion"] as? String ?? "?"))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            demo: \(model.demoMode)
            activeHosts: \(model.clusters.activeHosts.joined(separator: ", "))
            usableHosts: \(model.clusters.usableHosts.joined(separator: ", "))
            configState: \(model.clusters.configState.kind)
            controlPersist: \(model.preferences.controlPersist)
            controlPath: \(OpenSshTransport.defaultControlDirectory)/ssh-%C
            poll: jobs \(model.preferences.jobsPollSeconds)s, nodes \(model.preferences.nodesPollSeconds)s
            notifications: \(model.preferences.notificationsEnabled) \
            (start \(model.preferences.notifyOnStart), finish \(model.preferences.notifyOnFinish), \
            auth \(model.notifier.authorization))
            """
    }
}
