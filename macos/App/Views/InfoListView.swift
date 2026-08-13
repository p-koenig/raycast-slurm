import SlurmKit
import SwiftUI

/// One hardware shape: every node with the same partitions, CPU count, RAM, GRES and features.
///
/// This is what makes the Info tab useful — a 400-node cluster is really six machine types, and
/// the question the tab answers is "what can I ask for", not "what is each box doing".
struct NodeShape: Identifiable {
    var id: String { key }
    let key: String
    let partitions: String
    let cpuTot: Int
    let memMB: Int
    let gres: String
    let gpuModel: String
    let gpuCount: Int
    let features: String
    var nodes: [SlurmNode]

    var title: String {
        gpuCount > 0
            ? "\(gpuCount)× \(gpuModel.uppercased().isEmpty ? "GPU" : gpuModel.uppercased()) · \(cpuTot)c · \(SlurmFormat.formatBytesMB(Double(memMB)))"
            : "\(cpuTot)c · \(SlurmFormat.formatBytesMB(Double(memMB)))"
    }

    /// Grouping key and sort: GPUs desc → RAM desc → CPUs desc (`resources.tsx:165`).
    static func group(_ nodes: [SlurmNode]) -> [NodeShape] {
        var order: [String] = []
        var map: [String: NodeShape] = [:]
        for node in nodes {
            let partitions = node.partitions.sorted().joined(separator: ",")
            let key = [partitions, "\(node.cpuTot)", "\(node.realMemoryMB)", node.gres, node.features]
                .joined(separator: "\u{1}")
            if map[key] == nil {
                order.append(key)
                map[key] = NodeShape(
                    key: key,
                    partitions: partitions,
                    cpuTot: node.cpuTot,
                    memMB: node.realMemoryMB,
                    gres: node.gres,
                    gpuModel: Display.gpuModelFromGres(node.gres, features: node.features),
                    gpuCount: SlurmFormat.gpuCountFromGres(node.gres),
                    features: node.features,
                    nodes: []
                )
            }
            map[key]?.nodes.append(node)
        }
        return order.compactMap { map[$0] }
            .sorted { a, b in
                if a.gpuCount != b.gpuCount { return a.gpuCount > b.gpuCount }
                if a.memMB != b.memMB { return a.memMB > b.memMB }
                return a.cpuTot > b.cpuTot
            }
    }
}

/// The Info tab — "HPC Info" in the extension (`resources.tsx`). Same `listNodes` data as the
/// Nodes tab, read at half the cadence (60 s) because a hardware inventory does not move.
struct InfoListView: View {

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

    private var sections: [(host: String, nodeCount: Int, shapes: [NodeShape])] {
        let filtered = ClusterFilter.apply(model.nodes.results, filter: model.filter, partitions: { $0.partitions })
        return filtered.compactMap { result in
            guard case .ok(let host, let nodes) = result else { return nil }
            let shapes = NodeShape.group(nodes).filter { shape in
                Search.matches(
                    [host, shape.title, shape.partitions, shape.gres, shape.features, shape.gpuModel]
                        .joined(separator: " "),
                    model.searchText
                )
            }
            return shapes.isEmpty ? nil : (host: host, nodeCount: nodes.count, shapes: shapes)
        }
    }

    private var rowIDs: [String] {
        failures.map { "err:\($0.host)" } + sections.flatMap { section in
            section.shapes.map { "\(section.host)|\($0.key)" }
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

                ForEach(sections, id: \.host) { section in
                    Section {
                        ForEach(section.shapes) { shape in
                            shapeRow(host: section.host, shape: shape)
                        }
                    } header: {
                        SectionHeaderView(
                            title: section.host,
                            subtitle: "\(section.nodeCount) nodes · \(section.shapes.count) shapes"
                        )
                        .background(.background)
                    }
                }
        }
        .focusable()
        .focusEffectDisabled()
        .keyboardNavigation(selection: $selection, ids: rowIDs) { id in
            guard let separator = id.firstIndex(of: "|") else { return }
            model.push(
                .groupDetail(
                    host: String(id[id.startIndex..<separator]),
                    key: String(id[id.index(after: separator)...])
                )
            )
        }
    }

    private func shapeRow(host: String, shape: NodeShape) -> some View {
        SelectableRow(
            id: "\(host)|\(shape.key)",
            selection: $selection,
            onActivate: { model.push(.groupDetail(host: host, key: shape.key)) }
        ) {
            RowShell(
                symbol: shape.gpuCount > 0 ? "cpu" : "externaldrive",
                symbolColor: Palette.blue,
                title: shape.title,
                subtitle: shape.partitions.isEmpty ? "(no partition)" : shape.partitions
            ) {
                Chip(text: "\(shape.nodes.count)×", color: Palette.blue)
            }
        } menu: {
            Button("View Details") { model.push(.groupDetail(host: host, key: shape.key)) }
            Divider()
            Button("Copy Node Names") { Clipboard.copy(shape.nodes.map(\.name).joined(separator: ",")) }
            Button("Copy Shape Description") { Clipboard.copy(shape.title) }
        }
    }
}

/// The pushed shape detail (`resources.tsx:149`, `GroupDetail`).
struct GroupDetailScreen: View {

    @Environment(AppModel.self) private var model
    var host: String
    var key: String

    private var shape: NodeShape? {
        guard let nodes = model.nodes.results.first(where: { $0.host == host })?.data else { return nil }
        return NodeShape.group(nodes).first { $0.key == key }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: shape?.title ?? "Shape", subtitle: host)
            if let shape {
                PaneContainer {
                        MetaRow(title: "Cluster", symbol: "externaldrive.connected.to.line.below", text: host)
                        MetaRow(
                            title: "Partitions",
                            symbol: "square.stack.3d.up",
                            text: shape.partitions.isEmpty ? "—" : shape.partitions
                        )
                        MetaRow(title: "CPUs/node", symbol: "cpu", text: "\(shape.cpuTot)")
                        MetaRow(
                            title: "RAM/node",
                            symbol: "memorychip",
                            text: SlurmFormat.formatBytesMB(Double(shape.memMB))
                        )
                        if !shape.gres.isEmpty {
                            MetaRow(title: "GRES", symbol: "square.grid.2x2", text: shape.gres)
                        }
                        if !shape.features.isEmpty {
                            MetaRow(title: "Features", symbol: "tag", text: shape.features)
                        }
                        SectionHeaderView(title: "Nodes (\(shape.nodes.count))")
                        CodeBlock(text: shape.nodes.map(\.name).joined(separator: "\n"))
                            .frame(maxHeight: 260)
                            .padding(.horizontal, 12)
                }
            } else {
                EmptyState(symbol: "questionmark.circle", title: "Shape is no longer present")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
