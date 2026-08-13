import Foundation
import Observation
import SlurmKit

/// The cluster selection: what `~/.ssh/config` offers, what the user picked, and whether each
/// pick has a live multiplexed master. Port of `select-cluster.tsx` plus `useActiveHosts`.
///
/// Active hosts are persisted in `UserDefaults` under `activeHosts` as a JSON string array —
/// a **fresh** store, with no migration from the extension's Raycast `LocalStorage`
/// (ARCHITECTURE.md § App design).
@Observable
@MainActor
final class ClusterStore {

    private let preferences: Preferences
    private let connection: ConnectionControl
    private let sshConfig: SshConfig
    private let demoMode: Bool

    init(preferences: Preferences, connection: ConnectionControl, demoMode: Bool, sshConfig: SshConfig = SshConfig()) {
        self.preferences = preferences
        self.connection = connection
        self.sshConfig = sshConfig
        self.demoMode = demoMode
        self.activeHosts = Self.initialActiveHosts(preferences: preferences, demoMode: demoMode)
    }

    // MARK: - State

    /// Every concrete alias in `~/.ssh/config`, sorted. Demo mode substitutes the two fictional
    /// clusters so the picker has something to show without touching the real file.
    private(set) var configHosts: [SshHost] = []

    /// The tagged load state, so the picker can render config-specific copy per failure mode
    /// (UI-INVENTORY §6) rather than one generic error.
    private(set) var configState: SshConfig.ConfigState = .empty(path: "")

    /// The user's selection, in the order they picked. Persisted.
    private(set) var activeHosts: [String]

    /// Per-host ControlMaster probe results (`isMasterUp`, a 5 s local check).
    private(set) var masterUp: [String: Bool] = [:]

    private(set) var isLoading = false

    /// Persisted active names that are no longer in the config — the picker's "Stale" section.
    var staleHosts: [String] {
        let known = Set(configHosts.map(\.name))
        return activeHosts.filter { !known.contains($0) }
    }

    /// Active *and* still present in the config. This, not `activeHosts`, is what the data
    /// stores fan out over: querying an alias ssh can no longer resolve just manufactures error
    /// rows the user cannot act on from the jobs list.
    var usableHosts: [String] {
        let known = Set(configHosts.map(\.name))
        return activeHosts.filter { known.contains($0) }
    }

    /// Active first (in persisted order), then everything else alphabetically
    /// (`select-cluster.tsx:217`, `sortHosts`).
    var sortedHosts: [SshHost] {
        var order: [String: Int] = [:]
        for (index, name) in activeHosts.enumerated() { order[name] = index }
        return configHosts.enumerated()
            .sorted { lhs, rhs in
                let a = order[lhs.element.name] ?? Int.max
                let b = order[rhs.element.name] ?? Int.max
                if a != b { return a < b }
                let byName = lhs.element.name.localizedStandardCompare(rhs.element.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func isActive(_ host: String) -> Bool { activeHosts.contains(host) }

    // MARK: - Loading

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        if demoMode {
            configHosts = Demo.hosts
            configState = .empty(path: "(demo)")
        } else {
            let config = sshConfig
            let result = await Task.detached { config.listHosts() }.value
            configHosts = result.hosts
            configState = result.state
        }
        await probeMasters()
    }

    /// One `isMasterUp` probe per listed host, in parallel. Not polled — the picker refreshes it
    /// after every action that could change it.
    func probeMasters() async {
        let hosts = configHosts.map(\.name)
        let probe = connection.isMasterUp
        var next: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for host in hosts {
                group.addTask { (host, await probe(host)) }
            }
            for await (host, up) in group { next[host] = up }
        }
        masterUp = next
    }

    func refreshMaster(_ host: String) async {
        masterUp[host] = await connection.isMasterUp(host)
    }

    // MARK: - Mutation

    /// The toggle's outcome, so the view can render the inventory's exact toast sequence
    /// (UI-INVENTORY §6) without the store importing SwiftUI.
    enum ToggleOutcome {
        case deselected(host: String)
        case alreadyConnected(host: String)
        case connected(host: String)
        /// Deliberately **success**-styled in the inventory: needing 2FA is the expected path on
        /// these clusters, not a failure.
        case authRequired(host: String, command: String)
        case failed(host: String, error: SshErrorInfo)
    }

    func toggle(_ host: SshHost) async -> ToggleOutcome {
        if isActive(host.name) {
            // Deselecting never tears the connection down — the user may still be using it from
            // a shell, and reconnecting costs a 2FA round trip.
            remove(host.name)
            return .deselected(host: host.name)
        }

        add(host.name)
        if await connection.isMasterUp(host.name) {
            masterUp[host.name] = true
            return .alreadyConnected(host: host.name)
        }

        do {
            try await connection.openMaster(host.name)
            masterUp[host.name] = true
            return .connected(host: host.name)
        } catch let error as SshError where error.isAuth {
            return .authRequired(host: host.name, command: connection.interactiveCommand(host.name))
        } catch {
            return .failed(host: host.name, error: classifySshError(error, host: host.name))
        }
    }

    /// "Close Connection & Deselect" (⌘⇧X).
    func closeAndDeselect(_ host: String) async {
        await connection.closeMaster(host)
        remove(host)
        masterUp[host] = false
    }

    func add(_ host: String) {
        guard !activeHosts.contains(host) else { return }
        activeHosts.append(host)
        persist()
    }

    func remove(_ host: String) {
        activeHosts.removeAll { $0 == host }
        persist()
    }

    func interactiveCommand(_ host: String) -> String {
        connection.interactiveCommand(host)
    }

    private func persist() {
        preferences.saveActiveHosts(activeHosts)
    }

    /// Demo mode with nothing stored defaults to both fictional clusters, matching
    /// `getActiveHosts` (`ssh-config.ts:189`) — otherwise the demo boots into the "No active
    /// clusters" empty state and shows nothing at all.
    private static func initialActiveHosts(preferences: Preferences, demoMode: Bool) -> [String] {
        let stored = preferences.loadActiveHosts()
        if !stored.isEmpty { return stored }
        return demoMode ? Demo.hosts.map(\.name) : []
    }
}
