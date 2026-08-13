import AppKit
import SlurmKit
import SwiftUI

/// SlurmBar — a menubar app for Slurm clusters over plain SSH.
///
/// `LSUIElement` is true (see macos/project.yml), so there is no Dock icon and no main window:
/// the `MenuBarExtra` popover is the entire UI surface, plus a `Settings` scene. Two debug
/// affordances exist because driving a menubar popover from a shell is unreliable:
///
/// * `SLURMBAR_DEBUG_WINDOW=1` also hosts the popover's root view in an ordinary resizable
///   window, for a human to poke at.
/// * `SLURMBAR_SNAPSHOT_DIR=<dir>` renders every key screen to PNG and exits — the mechanism
///   this phase is verified with. It implies demo mode; it never opens an SSH connection.
/// * `SLURMBAR_SIMULATE_NOTIFICATION=1` turns notifications on (authorization prompt included)
///   and fires one simulated job transition through the real `UNUserNotificationCenter` path,
///   reporting each step on stderr. Added in P4 for the same reason as the two above: the
///   affordance it stands in for — the Notifications tab's "Simulate transition" button — is in
///   the `Settings` scene, which no shell can reach.
@main
struct SlurmBarApp: App {

    /// Without this the process exits the moment it has no open window. A `MenuBarExtra`-only
    /// app has none by definition, so the default "quit after last window closed" behaviour
    /// terminates it during launch.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @State private var model: AppModel

    private let showsDebugWindow: Bool
    private let snapshotDirectory: String?

    init() {
        Trace.log("init")
        // A crash between writing a connect script and handing it to Terminal would otherwise
        // leave the file in the temp directory forever.
        TerminalLauncher.cleanUpStaleScripts()

        let environment = ProcessInfo.processInfo.environment
        let snapshotDirectory = environment["SLURMBAR_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        self.snapshotDirectory = snapshotDirectory
        let debugWindow = environment["SLURMBAR_DEBUG_WINDOW"] == "1"
        self.showsDebugWindow = debugWindow

        // Snapshot mode implies demo mode: rendering screenshots must never touch a real host.
        let preferences = Preferences()
        let demo = environment["SLURMBAR_DEMO"] == "1" || snapshotDirectory != nil || preferences.demoModeDefault
        let model = AppModel(demoMode: demo, preferences: preferences)
        _model = State(initialValue: model)

        if let snapshotDirectory {
            Task { @MainActor in
                await SnapshotRunner.run(directory: snapshotDirectory, model: model)
            }
        } else {
            model.start()
            if debugWindow {
                Task { @MainActor in DebugWindow.show(model: model) }
            }
            // The third debug affordance (SPEC-P4 §6): press the Notifications tab's "Simulate
            // transition" button from the command line, because the `Settings` scene is not
            // scriptable and delivery is the one thing a snapshot cannot evidence.
            if environment["SLURMBAR_SIMULATE_NOTIFICATION"] == "1" {
                Task { @MainActor in await model.notifier.runLaunchSimulation() }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        // `.window`, not `.menu`: the popover hosts lists, per-cluster error rows and Swift
        // Charts sparklines, none of which fit in an NSMenu.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

    }
}

/// The `SLURMBAR_DEBUG_WINDOW=1` affordance, hosted in AppKit rather than as a SwiftUI `Window`
/// scene.
///
/// A `Window` scene cannot be used here: in an `LSUIElement` app SwiftUI opens it at launch, the
/// accessory app cannot actually show it, and SwiftUI then treats that as "the last window
/// closed" and terminates the process during launch — taking the menubar item with it. (This is
/// SwiftUI's own termination policy; an `NSApplicationDelegate`'s
/// `applicationShouldTerminateAfterLastWindowClosed` does not override it.) Building the window
/// by hand sidesteps the policy entirely.
@MainActor
enum DebugWindow {

    private nonisolated(unsafe) static var window: NSWindow?

    static func show(model: AppModel) {
        NSApplication.shared.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: RootView().environment(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "SlurmBar (debug)"
        window.setContentSize(NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Self.window = window
    }

    /// What clicking a notification can actually do (SPEC-P4 §4). A `MenuBarExtra` popover cannot
    /// be opened programmatically, so activating the app is the honest maximum — except when the
    /// debug window is up, in which case there is a real window to raise.
    static func bringForward() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Keeps a windowless agent alive and gives the snapshot runner a place to stand.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Refuse every termination request the user did not make.
    ///
    /// This is not paranoia. `MenuBarExtra` gives up its status item whenever Control Center
    /// decides the menu bar is full — on a notched display with a few agents running, that is
    /// *during launch* — and SwiftUI reads "my only scene went away" as "quit", so the process
    /// dies seconds after starting with no diagnostic. The console trail is
    /// `NSStatusItemChangeVisibilityAction` immediately followed by `terminate:`.
    ///
    /// Staying alive is strictly better: the popover is reachable again the moment the menu bar
    /// has room, and `Quit SlurmBar` still works because it sets `userRequestedQuit` first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppLifetime.userRequestedQuit {
            Trace.log("terminate: user requested")
            return .terminateNow
        }
        Trace.log("terminate: cancelled (not user-initiated)")
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.log("applicationDidFinishLaunching")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Trace.log("applicationWillTerminate")
    }
}

/// Who is allowed to end the process.
enum AppLifetime {
    nonisolated(unsafe) static var userRequestedQuit = false

    @MainActor
    static func quit() {
        userRequestedQuit = true
        NSApplication.shared.terminate(nil)
    }
}

/// Opt-in stderr tracing for the launch path, enabled with `SLURMBAR_TRACE=1`.
///
/// A menubar agent has nowhere to print, and `os_log` needs a second tool to read; when the app
/// was exiting silently during launch this was the only thing that located it.
enum Trace {
    nonisolated(unsafe) static let enabled = ProcessInfo.processInfo.environment["SLURMBAR_TRACE"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[slurmbar] \(message())\n".utf8))
    }
}

/// The menubar item itself: `formatTitle` counts next to a severity symbol.
///
/// **Tint finding (SPEC-P3 §2):** macOS renders `MenuBarExtra` label content as a *template*
/// image, which flattens it to the menubar's monochrome. `foregroundStyle` on the symbol is
/// applied here anyway — it costs nothing and takes effect wherever the content is drawn in
/// colour — but the severity is *also* encoded in the symbol itself
/// (`exclamationmark.circle.fill` for error states, `circle.fill` running,
/// `circle.circle.fill` pending, `circle.dotted` idle, `powerplug` no clusters), so the signal
/// survives the flattening. See `AppModel.menuBarSymbol`.
private struct MenuBarLabel: View {

    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.menuBarSymbol)
                .foregroundStyle(color)
            Text(model.menuBarTitle)
        }
        .help(tooltip)
    }

    private var color: Color {
        switch model.menuBarTint {
        case .red: return Palette.red
        case .green: return Palette.green
        case .yellow: return Palette.yellow
        case .secondary: return Palette.secondary
        }
    }

    private var tooltip: String {
        model.clusters.activeHosts.isEmpty
            ? "No active clusters"
            : "Slurm @ \(model.clusters.activeHosts.joined(separator: ", "))"
    }
}
