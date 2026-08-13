import SlurmKit
import SwiftUI

/// The cluster picker, as a pushed screen. Port of `select-cluster.tsx` (UI-INVENTORY §6).
///
/// It never edits `~/.ssh/config` — it only reads it. What it owns is the *selection* and the
/// ControlMaster lifecycle: activating a cluster opens a multiplexed master (or hands you a
/// Terminal for 2FA), and "Close Connection & Deselect" tears one down.
struct SelectClustersScreen: View {

    @Environment(AppModel.self) private var model
    @State private var selection: String?

    private var clusters: ClusterStore { model.clusters }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: "Select Clusters",
                subtitle: clusters.activeHosts.isEmpty ? nil : clusters.activeHosts.joined(separator: ", ")
            )
            content
        }
        .task { await clusters.reload() }
    }

    @ViewBuilder
    private var content: some View {
        // Config-error screens *replace* the list — there is nothing meaningful to show
        // alongside "your config file is missing".
        switch clusters.configState {
        case .missing(let path):
            configError(
                symbol: "doc.badge.plus",
                color: Palette.orange,
                title: "No ~/.ssh/config",
                message: "Create \(path) with at least one Host entry to start."
            )
        case .unreadable(_, let reason):
            configError(
                symbol: "exclamationmark.triangle.fill",
                color: Palette.red,
                title: "Couldn't read ~/.ssh/config",
                message: reason
            )
        case .empty where clusters.configHosts.isEmpty && clusters.staleHosts.isEmpty:
            configError(
                symbol: "magnifyingglass",
                color: Palette.secondary,
                title: "No hosts in ~/.ssh/config",
                message: "The file exists but contains no Host entries."
            )
        default:
            list
        }
    }

    private func configError(symbol: String, color: Color, title: String, message: String) -> some View {
        EmptyState(
            symbol: symbol,
            title: title,
            message: message,
            action: (title: "Reload", run: { Task { await clusters.reload() } })
        )
    }

    private var activeHosts: [SshHost] { clusters.sortedHosts.filter { clusters.isActive($0.name) } }
    private var availableHosts: [SshHost] { clusters.sortedHosts.filter { !clusters.isActive($0.name) } }

    private var list: some View {
        ListContainer {
                if !clusters.staleHosts.isEmpty {
                    Section {
                        ForEach(clusters.staleHosts, id: \.self) { name in
                            staleRow(name)
                        }
                    } header: {
                        SectionHeaderView(title: "Stale (\(clusters.staleHosts.count))").background(.background)
                    }
                }

                Section {
                    ForEach(activeHosts, id: \.name) { host in
                        clusterRow(host, isActive: true)
                    }
                } header: {
                    SectionHeaderView(title: "Active (\(activeHosts.count))").background(.background)
                }

                Section {
                    ForEach(availableHosts, id: \.name) { host in
                        clusterRow(host, isActive: false)
                    }
                } header: {
                    SectionHeaderView(title: "Available").background(.background)
                }
        }
        .focusable()
        .focusEffectDisabled()
        .keyboardNavigation(selection: $selection, ids: clusters.sortedHosts.map(\.name)) { id in
            if let host = clusters.sortedHosts.first(where: { $0.name == id }) { toggle(host) }
        }
        .background(shortcuts)
    }

    /// A persisted active name that is no longer in the config. It cannot be connected to, so
    /// the only action is to forget it.
    private func staleRow(_ name: String) -> some View {
        SelectableRow(id: "stale:\(name)", selection: $selection, onActivate: { dropStale(name) }) {
            RowShell(
                symbol: "questionmark.circle.fill",
                symbolColor: Palette.orange,
                title: name,
                subtitle: "No longer in ~/.ssh/config"
            ) {
                Chip(text: "Stale", color: Palette.orange)
            }
        } menu: {
            Button("Remove from Active List", role: .destructive) { dropStale(name) }
        }
    }

    private func clusterRow(_ host: SshHost, isActive: Bool) -> some View {
        let masterUp = clusters.masterUp[host.name] ?? false
        return SelectableRow(id: host.name, selection: $selection, onActivate: { toggle(host) }) {
            RowShell(
                symbol: isActive ? "checkmark.circle.fill" : "circle",
                symbolColor: isActive ? Palette.green : Palette.secondary,
                title: host.name,
                subtitle: nil
            ) {
                if isActive { Chip(text: "Active", color: Palette.green) }
                if masterUp {
                    // The green dot means "a multiplexed master is live for this host" — i.e.
                    // the next command will be instant and will not re-prompt for 2FA.
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Palette.green)
                        .help("Connection running")
                }
                if let user = host.user { Chip(text: user, color: Palette.secondary) }
                Meta(text: host.hostName)
            }
        } menu: {
            Button(isActive ? "Deselect (Keep Connection Running)" : "Activate & Connect") { toggle(host) }
            Button("Open in Terminal (Interactive)") { openTerminal(host) }
            Button("Close Connection & Deselect", role: .destructive) { closeAndDeselect(host) }
            Divider()
            Button("Reload SSH Config") { Task { await clusters.reload() } }
            Button("Copy Host Alias") { Clipboard.copy(host.name) }
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { if let host = selectedHost() { openTerminal(host) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { if let host = selectedHost() { closeAndDeselect(host) } }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("") { Task { await clusters.reload() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { if let host = selectedHost() { Clipboard.copy(host.name) } }
                .keyboardShortcut(".", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func selectedHost() -> SshHost? {
        guard let selection else { return nil }
        return clusters.sortedHosts.first { $0.name == selection }
    }

    // MARK: - Actions

    /// The toast sequence is the inventory's, including the deliberately **success**-styled
    /// "Auth required" case: needing 2FA is the expected path on these clusters, not a failure.
    private func toggle(_ host: SshHost) {
        Task {
            let outcome = await clusters.toggle(host)
            switch outcome {
            case .deselected(let name):
                model.show(.init(style: .success, title: "Deselected \(name)", message: "Connection kept running"))
            case .alreadyConnected(let name):
                model.show(.init(style: .success, title: "Activated \(name)", message: "Connection already up"))
            case .connected(let name):
                model.show(.init(style: .success, title: "Connected: \(name)"))
            case .authRequired(let name, _):
                model.show(.init(style: .success, title: "Auth required — opening Terminal for \(name)"))
                model.openTerminal(host: name)
            case .failed(let name, let error):
                model.showFailure(error, context: "Connecting to \(name)")
            }
            model.hostsChanged()
        }
    }

    private func openTerminal(_ host: SshHost) {
        model.openTerminal(host: host.name)
        clusters.add(host.name)
        model.hostsChanged()
        Task { await clusters.refreshMaster(host.name) }
    }

    private func closeAndDeselect(_ host: SshHost) {
        Task {
            await clusters.closeAndDeselect(host.name)
            model.show(.init(style: .success, title: "Connection closed: \(host.name)"))
            model.hostsChanged()
        }
    }

    private func dropStale(_ name: String) {
        clusters.remove(name)
        model.show(
            .init(
                style: .success,
                title: "Removed stale entry: \(name)",
                message: "It was no longer in ~/.ssh/config."
            )
        )
        model.hostsChanged()
    }
}
