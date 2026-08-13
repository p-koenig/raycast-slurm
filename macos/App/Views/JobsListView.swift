import SlurmKit
import SwiftUI

/// My Jobs and All Jobs. One view, because the extension's `all-jobs.tsx` is a near-clone of
/// `manage-jobs.tsx`: the deltas are the query (`listAllJobs` vs `listJobs -u`), the gate (All
/// Jobs does not wait for `whoami`), and a leading user chip per row.
///
/// **No pagination** (SPEC-P3 §3). The extension pages at 100 rows purely to stop the Raycast
/// worker running out of heap; `LazyVStack` only materialises visible rows, so every match is
/// rendered. What is kept is everything the paging was wrapped around: full-dataset search,
/// cluster-order flattening, per-section match counts, and error rows built from the
/// **unfiltered** results.
struct JobsListView: View {

    enum Kind { case mine, all }

    @Environment(AppModel.self) private var model
    var kind: Kind

    @State private var selection: String?
    @State private var pendingCancel: (host: String, job: Job)?

    var body: some View {
        Group {
            if model.clusters.activeHosts.isEmpty {
                NoHostsView()
            } else {
                content
            }
        }
        .confirmationDialog(
            pendingCancel.map { "Cancel job \($0.job.jobId) on \($0.host)?" } ?? "",
            isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }),
            titleVisibility: .visible
        ) {
            Button("scancel", role: .destructive) {
                if let pending = pendingCancel { cancel(host: pending.host, job: pending.job) }
                pendingCancel = nil
            }
            Button("Keep Running", role: .cancel) { pendingCancel = nil }
        } message: {
            Text(pendingCancel?.job.name ?? "")
        }
    }

    // MARK: - Data shaping

    private var results: [ClusterResult<[Job]>] {
        kind == .mine ? model.jobs.mine : model.jobs.all
    }

    private var isLoading: Bool {
        kind == .mine ? model.jobs.isLoadingMine : model.jobs.isLoadingAll
    }

    private var hasLoaded: Bool {
        kind == .mine ? model.jobs.hasLoadedMine : model.jobs.hasLoadedAll
    }

    /// Failures come from the **unfiltered** results so a cluster filter can never hide a
    /// cluster that is down (`manage-jobs.tsx:103`).
    private var failures: [(host: String, error: SshErrorInfo)] {
        SlurmKit.failures(results)
    }

    /// Matches per cluster, in cluster order, after search and filter.
    private var sections: [(host: String, jobs: [Job])] {
        let filtered = ClusterFilter.apply(results, filter: model.filter, partitions: { [$0.partition] })
        return filtered.compactMap { result in
            guard case .ok(let host, let jobs) = result else { return nil }
            let matches = jobs.filter { Search.matches(Search.jobHaystack(host: host, job: $0), model.searchText) }
            return matches.isEmpty ? nil : (host: host, jobs: matches)
        }
    }

    private var totalMatches: Int { sections.reduce(0) { $0 + $1.jobs.count } }

    private var rowIDs: [String] {
        failures.map { "err:\($0.host)" } + sections.flatMap { section in
            section.jobs.map { "\(section.host):\($0.jobId)" }
        }
    }

    // MARK: - Body

    private var content: some View {
        ListContainer {
                ForEach(failures, id: \.host) { failure in
                    ClusterErrorRow(
                        host: failure.host,
                        info: failure.error,
                        onRetry: { Task { await model.refreshCurrentTab() } },
                        onReauth: { model.openTerminal(host: failure.host) },
                        onOpenClusters: { model.openSelectClusters() },
                        selection: $selection
                    )
                }

                if totalMatches == 0 && failures.isEmpty && !isLoading && hasLoaded {
                    EmptyState(
                        symbol: "tray",
                        title: "No jobs",
                        message: "No queued or running jobs on any active cluster."
                    )
                }

                ForEach(sections, id: \.host) { section in
                    Section {
                        ForEach(section.jobs, id: \.jobId) { job in
                            jobRow(host: section.host, job: job)
                        }
                    } header: {
                        SectionHeaderView(title: section.host, subtitle: "\(section.jobs.count) jobs")
                            .background(.background)
                    }
                }
        }
        .focusable()
        .focusEffectDisabled()
        .keyboardNavigation(selection: $selection, ids: rowIDs) { id in activate(id) }
        .background(shortcuts)
    }

    /// The inventory's row shortcuts, acting on the selected row. They live on invisible buttons
    /// because a shortcut has to be owned by a focusable control — a context-menu item's
    /// `keyboardShortcut` only fires while that menu is open.
    private var shortcuts: some View {
        ZStack {
            Button("") { if let job = selectedJob() { Clipboard.copy(job.job.jobId) } }
                .keyboardShortcut(".", modifiers: .command)
            Button("") { if let job = selectedJob() { pendingCancel = job } }
                .keyboardShortcut("x", modifiers: .control)
            Button("") { if let host = selectedErrorHost() { model.openTerminal(host: host) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("") { if let host = selectedErrorHost() { model.openTerminal(host: host) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func selectedJob() -> (host: String, job: Job)? {
        guard let id = selection, !id.hasPrefix("err:"), let separator = id.firstIndex(of: ":") else { return nil }
        let host = String(id[id.startIndex..<separator])
        let jobId = String(id[id.index(after: separator)...])
        guard let job = sections.first(where: { $0.host == host })?.jobs.first(where: { $0.jobId == jobId }) else {
            return nil
        }
        return (host: host, job: job)
    }

    private func selectedErrorHost() -> String? {
        guard let id = selection, id.hasPrefix("err:") else { return nil }
        return String(id.dropFirst(4))
    }

    private func jobRow(host: String, job: Job) -> some View {
        let owned = kind == .mine || model.jobs.owns(host: host, user: job.user)
        return SelectableRow(
            id: "\(host):\(job.jobId)",
            selection: $selection,
            onActivate: { model.push(.jobDetail(host: host, jobId: job.jobId, owned: owned)) }
        ) {
            RowShell(
                symbol: "hammer.fill",
                symbolColor: StateColors.job(job.state),
                title: job.jobId,
                subtitle: job.name
            ) {
                // Accessory order is the inventory's, left to right.
                if kind == .all, let user = job.user {
                    // Blue for everyone, per UI-INVENTORY §2. The yellow "this one is mine"
                    // tint is the node drill-down's rule (§10), not this list's.
                    Chip(text: user, color: Palette.blue)
                }
                Chip(text: job.partition, color: Palette.secondary)
                Meta(text: "\(job.elapsed) / \(job.timeLimit)")
                Meta(text: "\(job.cpus) CPU")
                if let mem = SlurmFormat.memFromTres(job.tres) { Meta(text: mem) }
                if let gpu = SlurmFormat.gpuLabelFromTres(job.tres) { Meta(text: gpu) }
            }
        } menu: {
            Button("View Details") { model.push(.jobDetail(host: host, jobId: job.jobId, owned: owned)) }
            Divider()
            Button("Copy Job ID") { Clipboard.copy(job.jobId) }
            Button("Cancel Job…", role: .destructive) { pendingCancel = (host: host, job: job) }
        }
    }

    // MARK: - Actions

    private func activate(_ id: String) {
        if id.hasPrefix("err:") {
            let host = String(id.dropFirst(4))
            if failures.first(where: { $0.host == host })?.error.kind == .auth {
                model.openTerminal(host: host)
            } else {
                Task { await model.refreshCurrentTab() }
            }
            return
        }
        guard let separator = id.firstIndex(of: ":") else { return }
        let host = String(id[id.startIndex..<separator])
        let jobId = String(id[id.index(after: separator)...])
        guard let job = sections.first(where: { $0.host == host })?.jobs.first(where: { $0.jobId == jobId }) else {
            return
        }
        let owned = kind == .mine || model.jobs.owns(host: host, user: job.user)
        model.push(.jobDetail(host: host, jobId: job.jobId, owned: owned))
    }

    private func cancel(host: String, job: Job) {
        Task {
            do {
                try await model.jobs.cancel(host: host, jobId: job.jobId)
                model.show(.init(style: .success, title: "Cancelled \(job.jobId)"))
                await model.refreshCurrentTab()
            } catch {
                model.showFailure(error, host: host, context: "Cancel \(job.jobId)")
            }
        }
    }
}
