import AppKit
import Foundation
import Observation
import SlurmKit

/// The app's root state: which tab is showing, what is pushed on top of it, the transient
/// banner queue, and the polling policy.
///
/// SPEC-P3 §1 collapses the extension's six Raycast commands into one popover with a
/// segmented switcher, so the "which command am I in" question becomes `tab`, and Raycast's
/// `launchCommand` cross-jumps become `tab` + a stack push.
@Observable
@MainActor
final class AppModel {

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case myJobs, allJobs, nodes, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .myJobs: return "My Jobs"
            case .allJobs: return "All Jobs"
            case .nodes: return "Nodes"
            case .info: return "Info"
            }
        }

        var symbol: String {
            switch self {
            case .myJobs: return "hammer"
            case .allJobs: return "list.bullet"
            case .nodes: return "server.rack"
            case .info: return "cpu"
            }
        }
    }

    /// Pushed screens. Every case carries identifiers rather than model values, so a drill-down
    /// re-reads the store on each render and keeps ticking with the parent's poll instead of
    /// freezing whatever was on screen when it was pushed.
    enum Route: Hashable {
        case jobDetail(host: String, jobId: String, owned: Bool)
        case nodeJobs(host: String, node: String)
        case groupDetail(host: String, key: String)
        case selectClusters
    }

    /// The native stand-in for a Raycast toast: a transient banner over the bottom of the
    /// popover, auto-dismissed after 3 s, tap to dismiss (SPEC-P3 §4). The copy is the
    /// inventory's, verbatim.
    struct Banner: Identifiable, Equatable {
        enum Style: Equatable { case success, failure, progress }
        let id = UUID()
        var style: Style
        var title: String
        var message: String?
    }

    // MARK: - Wiring

    let demoMode: Bool
    let preferences: Preferences
    let transport: any SshTransport
    let connection: ConnectionControl
    let clusters: ClusterStore
    let jobs: JobsStore
    let nodes: NodesStore
    let notifier: JobNotifier

    init(demoMode: Bool, preferences: Preferences = Preferences()) {
        self.demoMode = demoMode
        self.preferences = preferences

        if demoMode {
            let loaded = DemoFixtures.load()
            self.transport = DemoAppTransport(loaded: loaded)
            self.connection = .demo
        } else {
            let ssh = OpenSshTransport(
                configuration: .init(controlPersist: preferences.controlPersist)
            )
            self.transport = ssh
            self.connection = .real(ssh)
        }

        self.clusters = ClusterStore(preferences: preferences, connection: connection, demoMode: demoMode)
        self.jobs = JobsStore(transport: transport)
        self.nodes = NodesStore(transport: transport)
        // Constructed here but inert: it subscribes to nothing and touches
        // `UNUserNotificationCenter` for the first time in `start()`, which the snapshot runner
        // never calls.
        self.notifier = JobNotifier(preferences: preferences, transport: transport, demoMode: demoMode)
    }

    // MARK: - Navigation

    var tab: Tab = .myJobs {
        didSet { syncActivity() }
    }

    /// One stack per tab, so switching away and back keeps the drill-down you were in.
    var paths: [Tab: [Route]] = [:]

    var path: [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    func push(_ route: Route) {
        paths[tab, default: []].append(route)
    }

    /// A cross-jump: switch tab *and* push, which is what Raycast's `launchCommand` amounted to.
    func jump(to tab: Tab, push route: Route? = nil) {
        self.tab = tab
        if let route { paths[tab, default: []].append(route) }
    }

    func openSelectClusters() {
        if path.last != .selectClusters { push(.selectClusters) }
    }

    // MARK: - Query state

    /// Search and filter are deliberately app-wide rather than per tab: the toolbar row that
    /// carries them is app-wide too, and carrying a stale query into a tab you just switched to
    /// reads as a bug.
    var searchText: String = ""
    var filter: ClusterFilter = .all

    // MARK: - Banners

    private(set) var banner: Banner?
    private var bannerDismissal: Task<Void, Never>?

    func show(_ banner: Banner) {
        self.banner = banner
        bannerDismissal?.cancel()
        let id = banner.id
        bannerDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if self.banner?.id == id { self.banner = nil }
        }
    }

    func dismissBanner() {
        bannerDismissal?.cancel()
        banner = nil
    }

    /// The inventory's failure-toast shape: title `"{context}: {info.title}"`, body
    /// `info.hint ?? info.message` (UI-INVENTORY §0).
    func showFailure(_ error: SshErrorInfo, context: String) {
        show(Banner(style: .failure, title: "\(context): \(error.title)", message: error.hint ?? error.message))
    }

    func showFailure(_ error: any Error, host: String?, context: String) {
        showFailure(classifySshError(error, host: host), context: context)
    }

    // MARK: - Terminal

    /// Open a real Terminal for password / 2FA. A no-op in demo mode, matching the extension.
    func openTerminal(host: String) {
        guard !demoMode else {
            show(Banner(style: .success, title: "Demo mode", message: "No Terminal is opened for \(host)."))
            return
        }
        do {
            try TerminalLauncher.run(command: connection.interactiveCommand(host), host: host)
        } catch {
            show(
                Banner(
                    style: .failure,
                    title: "Couldn't open Terminal for \(host)",
                    message: error.localizedDescription
                )
            )
        }
    }

    // MARK: - Lifecycle and polling

    /// Whether the popover window is on screen. `MenuBarExtra(.window)` exposes no open/close
    /// callback, so the root view reports its own appear/disappear — which is the same edge.
    var popoverOpen = false {
        didSet { syncActivity() }
    }

    private var screensAsleep = false {
        didSet { syncActivity() }
    }

    private let minePoll = PollLoop()
    private let allPoll = PollLoop()
    private let nodesPoll = PollLoop()
    private let labelPoll = PollLoop()
    private var sleepObservers: [NSObjectProtocol] = []

    func start() {
        observeScreenSleep()
        // Every my-jobs poll — foreground and background — is diffed for notifications. Wiring it
        // here rather than in `init` is what keeps snapshot mode away from `UNUserNotificationCenter`.
        notifier.start()
        jobs.onMyJobsPoll = { [notifier] results in notifier.handle(results) }
        Task { @MainActor in
            await clusters.reload()
            await syncHosts()
            await jobs.refreshUsers()
            await jobs.refreshLabel()
            syncActivity()
        }
    }

    /// Push the active-host list into the data stores. Called after any change to the selection.
    func syncHosts() async {
        let hosts = clusters.usableHosts
        jobs.setHosts(hosts)
        nodes.setHosts(hosts)
    }

    func hostsChanged() {
        Task { @MainActor in
            await syncHosts()
            await jobs.refreshUsers()
            syncActivity()
            await refreshCurrentTab()
        }
    }

    /// Manual refresh (⌘R): whatever the current tab is showing.
    func refreshCurrentTab() async {
        switch tab {
        case .myJobs: await jobs.refreshMine()
        case .allJobs: await jobs.refreshAll()
        case .nodes, .info: await nodes.refresh()
        }
    }

    /// The one place that decides which loops run. Everything suspends while the popover is
    /// closed or the screen is asleep, except the 30 s label tick — that is the only reason the
    /// process does any work in the background at all.
    private func syncActivity() {
        minePoll.stop()
        allPoll.stop()
        nodesPoll.stop()
        labelPoll.stop()

        guard !screensAsleep else { return }

        guard popoverOpen else {
            // The only work the process does with the popover closed: keep the menubar count
            // honest, using the cheap single-`squeue` variant that skips the AllocTRES join.
            labelPoll.start(seconds: { 30 }, fireImmediately: false) { [jobs] in await jobs.refreshLabel() }
            return
        }

        let jobsInterval = { @MainActor [preferences] in Double(preferences.jobsPollSeconds) }
        let nodesInterval = { @MainActor [preferences] in Double(preferences.nodesPollSeconds) }

        // Loops are restarted rather than left running because the *cadence* is tab-dependent
        // (Info reads nodes at half the rate), and because the immediate first tick is what
        // makes a tab switch feel like it fetched something.
        switch tab {
        case .myJobs:
            minePoll.start(seconds: jobsInterval) { [jobs] in await jobs.refreshMine() }
        case .allJobs:
            allPoll.start(seconds: jobsInterval) { [jobs] in await jobs.refreshAll() }
        case .nodes:
            nodesPoll.start(seconds: nodesInterval) { [nodes] in await nodes.refresh() }
            // The nodes tab also needs my jobs, for the "you have jobs here" marker and the
            // "My jobs only" filter — but that is not a reason to poll them at the jobs cadence.
            minePoll.start(seconds: nodesInterval) { [jobs] in await jobs.refreshMine() }
        case .info:
            // A hardware inventory does not move; the Info tab reads the same nodes at half the
            // cadence (60 s by default).
            nodesPoll.start(seconds: { @MainActor in nodesInterval() * 2 }) { [nodes] in await nodes.refresh() }
        }
    }

    private func observeScreenSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let asleep = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        }
        let awake = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        }
        sleepObservers = [asleep, awake]
    }

    // MARK: - Menubar label

    /// The label text: `formatTitle` counts, or `"Slurm"` when there is nothing selected
    /// (`menu-bar.tsx`).
    var menuBarTitle: String {
        clusters.activeHosts.isEmpty ? "Slurm" : Display.menuBarTitle(jobs.counts)
    }

    /// `pickTint` (`menu-bar.tsx:163`), strict order: any cluster error → red; FAILED/TIMEOUT
    /// present → red; RUNNING → green; PENDING → yellow; else secondary.
    var menuBarTint: Color3 {
        if clusters.activeHosts.isEmpty { return .secondary }
        if jobs.anyClusterFailing { return .red }
        let counts = jobs.counts
        if (counts["FAILED"] ?? 0) != 0 || (counts["TIMEOUT"] ?? 0) != 0 { return .red }
        if (counts["RUNNING"] ?? 0) != 0 { return .green }
        if (counts["PENDING"] ?? 0) != 0 { return .yellow }
        return .secondary
    }

    /// Severity encoded as a *symbol* as well as a tint.
    ///
    /// macOS renders menu bar content as a template image, which strips colour from an SF Symbol
    /// — so a tint-only signal can silently degrade to "grey dot, always". Shipping both means
    /// the severity still reads if the tint is flattened (SPEC-P3 §2).
    var menuBarSymbol: String {
        switch menuBarTint {
        case .red: return "exclamationmark.circle.fill"
        case .green: return "circle.fill"
        case .yellow: return "circle.circle.fill"
        case .secondary: return clusters.activeHosts.isEmpty ? "powerplug" : "circle.dotted"
        }
    }

    /// The four states `pickTint` can produce, kept as a plain enum so the store stays free of
    /// SwiftUI and the mapping stays in `StateColors`.
    enum Color3 { case red, green, yellow, secondary }
}
