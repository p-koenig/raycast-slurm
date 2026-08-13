import SlurmKit
import SwiftUI

/// Who is on one node. Port of `NodeJobsView.tsx`.
///
/// The node row you pressed Return on is repeated at the top with the same chips, so the numbers
/// you drilled into stay on screen while you read the jobs that explain them.
struct NodeJobsScreen: View {

    @Environment(AppModel.self) private var model
    var host: String
    var node: String

    @State private var jobs: NodeJobsModel?

    var body: some View {
        Group {
            if let jobs {
                NodeJobsContent(jobs: jobs, node: model.nodes.node(host: host, name: node))
            } else {
                VStack(spacing: 0) {
                    ScreenHeader(title: node, subtitle: host)
                    ProgressView().controlSize(.small).padding(24)
                    Spacer()
                }
            }
        }
        .task {
            let created = NodeJobsModel(host: host, node: node, transport: model.transport)
            jobs = created
            await created.refresh()
            created.startPolling()
        }
        .onDisappear { jobs?.stopPolling() }
    }
}

/// The screen over an already-loaded model, so the snapshot runner can render it in one pass.
struct NodeJobsContent: View {

    @Environment(AppModel.self) private var model
    var jobs: NodeJobsModel
    /// The parent list's node row, re-read from `NodesStore` so it keeps ticking with the
    /// parent's poll rather than freezing at push time.
    var node: SlurmNode?

    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: jobs.node, subtitle: jobs.host)
            ListContainer {
                    if let error = jobs.error {
                        ClusterErrorRow(
                            host: jobs.host,
                            info: error,
                            onRetry: { Task { await jobs.refresh() } },
                            onReauth: { model.openTerminal(host: jobs.host) },
                            onOpenClusters: { model.openSelectClusters() },
                            selection: $selection
                        )
                    }

                    SectionHeaderView(title: "Node")
                    if let node {
                        RowShell(
                            symbol: "circle.fill",
                            symbolColor: StateColors.node(node.state),
                            title: node.name,
                            subtitle: node.partitions.joined(separator: ","),
                            subtitleMinWidth: 0
                        ) {
                            NodeChips(node: node)
                        }
                        .contextMenu {
                            Button("Refresh") { Task { await jobs.refresh() } }
                            Divider()
                            Button("Copy Node Name") { Clipboard.copy(node.name) }
                            if !SlurmFormat.shortReason(node.reason).isEmpty {
                                Button("Copy Reason") { Clipboard.copy(node.reason) }
                            }
                        }
                    }

                    SectionHeaderView(
                        title: "Running Jobs",
                        subtitle: jobs.jobs.isEmpty
                            ? nil
                            : "\(Display.plural(jobs.jobs.count, "job")) · \(Display.plural(jobs.userCount, "user"))"
                    )

                    if jobs.jobs.isEmpty && !jobs.isLoading && jobs.error == nil && jobs.hasLoaded {
                        RowShell(
                            symbol: "moon.zzz",
                            symbolColor: Palette.secondary,
                            title: "No running jobs",
                            subtitle: "Nothing is allocated on this node right now."
                        ) {}
                    }

                    ForEach(jobs.jobs, id: \.jobId) { job in
                        jobRow(job)
                    }
            }
            .focusable()
            .focusEffectDisabled()
            .keyboardNavigation(selection: $selection, ids: jobs.jobs.map(\.jobId)) { id in
                if let job = jobs.jobs.first(where: { $0.jobId == id }) { open(job) }
            }
        }
    }

    private func jobRow(_ job: NodeJob) -> some View {
        let owned = model.jobs.owns(host: jobs.host, user: job.user)
        // AllocTRES is job-wide, so for a job spanning several nodes the CPU/mem/GPU figures
        // describe the whole allocation, not this node's share. Flag those rows rather than
        // letting them read as this node's usage (`slurm.ts:330-337`).
        let spansNodes = (Int(job.nodeCount) ?? 1) > 1
        return SelectableRow(id: job.jobId, selection: $selection, onActivate: { open(job) }) {
            RowShell(
                symbol: "hammer.fill",
                symbolColor: StateColors.job("RUNNING"),
                title: job.jobId,
                subtitle: job.name
            ) {
                // Your own jobs carry the yellow the node list uses for "you have jobs here",
                // so that signal survives the drill-down; everyone else stays blue.
                Chip(text: job.user, color: owned ? Palette.yellow : Palette.blue)
                Meta(text: "\(job.elapsed) / \(job.timeLimit)")
                Meta(text: "\(job.cpus) CPU")
                if let mem = SlurmFormat.memFromTres(job.tres) { Meta(text: mem) }
                if let gpu = SlurmFormat.gpuLabelFromTres(job.tres) { Meta(text: gpu) }
                if spansNodes {
                    Chip(text: "\(job.nodeCount) nodes", color: Palette.secondary)
                }
            }
        } menu: {
            Button("View Details") { open(job) }
            Divider()
            Button("Copy Job ID") { Clipboard.copy(job.jobId) }
            Button("Copy User") { Clipboard.copy(job.user) }
        }
    }

    private func open(_ job: NodeJob) {
        model.push(
            .jobDetail(
                host: jobs.host,
                jobId: job.jobId,
                owned: model.jobs.owns(host: jobs.host, user: job.user)
            )
        )
    }
}
