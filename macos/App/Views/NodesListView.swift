import SlurmKit
import SwiftUI

/// The Nodes tab — "HPC Util" in the extension (`node-utilization.tsx`).
///
/// The chips are the point of this screen: state, CPU load, memory, and GPU allocation when the
/// node has any, each tinted by how full it is. They come from `Display.nodeUtilTags`, shared
/// verbatim with the per-node drill-down so a node reads identically in both places.
struct NodesListView: View {

    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        Group {
            if model.clusters.activeHosts.isEmpty {
                NoHostsView()
            } else {
                content
            }
        }
    }

    private var failures: [(host: String, error: SshErrorInfo)] {
        SlurmKit.failures(model.nodes.results)
    }

    private var myNodes: [String: Set<String>] { model.jobs.myNodeSets }

    private var sections: [(host: String, nodes: [SlurmNode])] {
        let sets = myNodes
        let filtered = ClusterFilter.apply(
            model.nodes.results,
            filter: model.filter,
            partitions: { $0.partitions },
            isMine: { host, node in sets[host]?.contains(node.name) ?? false }
        )
        return filtered.compactMap { result in
            guard case .ok(let host, let nodes) = result else { return nil }
            let matches = nodes.filter { Search.matches(Search.nodeHaystack(host: host, node: $0), model.searchText) }
            return matches.isEmpty ? nil : (host: host, nodes: matches)
        }
    }

    private var totalMatches: Int { sections.reduce(0) { $0 + $1.nodes.count } }

    private var rowIDs: [String] {
        failures.map { "err:\($0.host)" } + sections.flatMap { section in
            section.nodes.map { "\(section.host):\($0.name)" }
        }
    }

    private var content: some View {
        ListContainer {
                ForEach(failures, id: \.host) { failure in
                    ClusterErrorRow(
                        host: failure.host,
                        info: failure.error,
                        onRetry: { Task { await model.nodes.refresh() } },
                        onReauth: { model.openTerminal(host: failure.host) },
                        onOpenClusters: { model.openSelectClusters() },
                        selection: $selection
                    )
                }

                if totalMatches == 0 && failures.isEmpty && !model.nodes.isLoading && model.nodes.hasLoaded {
                    EmptyState(symbol: "magnifyingglass", title: "No nodes match this filter")
                }

                ForEach(sections, id: \.host) { section in
                    Section {
                        ForEach(section.nodes, id: \.name) { node in
                            nodeRow(host: section.host, node: node)
                        }
                    } header: {
                        SectionHeaderView(title: section.host, subtitle: "\(section.nodes.count) nodes")
                            .background(.background)
                    }
                }
        }
        .focusable()
        .focusEffectDisabled()
        .keyboardNavigation(selection: $selection, ids: rowIDs) { id in activate(id) }
    }

    private func nodeRow(host: String, node: SlurmNode) -> some View {
        let mine = myNodes[host]?.contains(node.name) ?? false
        return SelectableRow(
            id: "\(host):\(node.name)",
            selection: $selection,
            onActivate: { model.push(.nodeJobs(host: host, node: node.name)) }
        ) {
            RowShell(
                symbol: "circle.fill",
                symbolColor: StateColors.node(node.state),
                title: node.name,
                subtitle: node.partitions.joined(separator: ","),
                subtitleMinWidth: 0
            ) {
                NodeChips(node: node)
                if mine {
                    // The extension appends a yellow person icon to mark "you have jobs here";
                    // the drill-down carries the same yellow onto your own job rows.
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.yellow)
                }
            }
        } menu: {
            Button("Show Running Jobs") { model.push(.nodeJobs(host: host, node: node.name)) }
            Divider()
            Button("Copy Node Name") { Clipboard.copy(node.name) }
            if !SlurmFormat.shortReason(node.reason).isEmpty {
                Button("Copy Reason") { Clipboard.copy(node.reason) }
            }
        }
    }

    private func activate(_ id: String) {
        if id.hasPrefix("err:") {
            let host = String(id.dropFirst(4))
            if failures.first(where: { $0.host == host })?.error.kind == .auth {
                model.openTerminal(host: host)
            } else {
                Task { await model.nodes.refresh() }
            }
            return
        }
        guard let separator = id.firstIndex(of: ":") else { return }
        model.push(
            .nodeJobs(
                host: String(id[id.startIndex..<separator]),
                node: String(id[id.index(after: separator)...])
            )
        )
    }
}

/// The `nodeUtilTags` chip strip.
struct NodeChips: View {
    var node: SlurmNode

    var body: some View {
        ForEach(Display.nodeUtilTags(node)) { tag in
            Chip(text: tag.value, color: color(for: tag))
        }
    }

    private func color(for tag: Display.Tag) -> Color {
        switch tag.role {
        case .state(let state): return StateColors.node(state)
        case .fixed(let role):
            switch role {
            case .green: return Palette.green
            case .yellow: return Palette.yellow
            case .red: return Palette.red
            case .orange: return Palette.orange
            case .blue: return Palette.blue
            case .purple: return Palette.purple
            case .secondary: return Palette.secondary
            }
        }
    }
}
