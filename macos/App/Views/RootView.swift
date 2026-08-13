import SlurmKit
import SwiftUI

/// The popover. SPEC-P3 §1: the extension's six Raycast commands collapse into one window with
/// a segmented top-level switcher and a toolbar row, each tab hosting a `NavigationStack` for
/// its drill-downs.
struct RootView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        PopoverChrome {
            @Bindable var model = model
            ForEach(AppModel.Tab.allCases) { tab in
                if tab == model.tab {
                    NavigationStack(path: Binding(get: { model.path }, set: { model.path = $0 })) {
                        TabRootView(tab: tab)
                            .navigationDestination(for: AppModel.Route.self) { route in
                                RouteView(route: route)
                            }
                    }
                }
            }
        }
        .onAppear { model.popoverOpen = true }
        .onDisappear { model.popoverOpen = false }
    }
}

/// The frame, header and banner that wrap whatever the current tab is showing.
///
/// Split out from `RootView` because the snapshot runner composes it around a bare tab root:
/// `ImageRenderer` takes a single pass with no navigation machinery, so the screens it renders
/// have to be reachable without one.
struct PopoverChrome<Content: View>: View {

    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Top-aligned and clipped: under `ImageRenderer` a list taller than the popover would
        // otherwise be centred, cropping the header off the top of every screenshot.
        .frame(width: PopoverMetrics.width, height: PopoverMetrics.height, alignment: .top)
        .clipped()
        .background(.background)
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                BannerOverlay(banner: banner) { model.dismissBanner() }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.banner)
    }
}

/// Tab switcher + toolbar row: cluster filter, search, Clusters, Refresh, Settings.
struct HeaderView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.snapshotMode) private var snapshotMode
    @FocusState private var searchFocused: Bool

    var body: some View {
        if snapshotMode {
            staticHeader
        } else {
            liveHeader
        }
    }

    /// Every control in the live header is `NSView`-backed and therefore invisible to
    /// `ImageRenderer`; this draws the same thing with shapes so the screenshots show a header
    /// instead of a row of placeholder blocks.
    private var staticHeader: some View {
        VStack(spacing: 6) {
            StaticSegments(titles: AppModel.Tab.allCases.map(\.title), selected: model.tab.title)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 11))
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(model.searchText.isEmpty ? "Search" : model.searchText)
                        .font(.system(size: 11))
                        .foregroundStyle(model.searchText.isEmpty ? .tertiary : .primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                ForEach(["externaldrive.connected.to.line.below", "arrow.clockwise", "gearshape", "power"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var liveHeader: some View {
        @Bindable var model = model
        return VStack(spacing: 6) {
            Picker("", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                ClusterFilterMenu()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("Search", text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .focused($searchFocused)
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                toolbarButton("externaldrive.connected.to.line.below", help: "Select Clusters") {
                    model.openSelectClusters()
                }
                toolbarButton("arrow.clockwise", help: "Refresh (⌘R)") {
                    Task { await model.refreshCurrentTab() }
                }
                .keyboardShortcut("r", modifiers: .command)

                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Settings")

                toolbarButton("power", help: "Quit SlurmBar (⌘Q)") { AppLifetime.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // ⌘F focuses search (SPEC-P3 §5). The button is invisible and zero-sized; it exists
            // only to own the shortcut, because a TextField cannot carry one itself.
            .overlay {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// The hierarchical cluster/partition filter (UI-INVENTORY §8). `includeMine` is only offered on
/// the Nodes tab, exactly as in the extension.
struct ClusterFilterMenu: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Button("All clusters · all partitions") { model.filter = .all }
            if model.tab == .nodes {
                Button("My jobs only (all clusters)") { model.filter = .mine }
            }
            ForEach(clusters, id: \.host) { cluster in
                Divider()
                Section(cluster.host) {
                    Button("All on \(cluster.host)") { model.filter = .cluster(host: cluster.host, partition: nil) }
                    ForEach(cluster.partitions, id: \.self) { partition in
                        Button("\(cluster.host) · \(partition)") {
                            model.filter = .cluster(host: cluster.host, partition: partition)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: model.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
    }

    private var label: String {
        switch model.filter {
        case .all: return "All clusters"
        case .mine: return "My jobs only"
        case .cluster(let host, let partition): return partition.map { "\(host) · \($0)" } ?? host
        }
    }

    /// Failing clusters still get a section header — the filter must not make a broken cluster
    /// invisible in the picker either.
    private var clusters: [(host: String, partitions: [String])] {
        switch model.tab {
        case .myJobs:
            return ClusterFilter.partitionsByCluster(model.jobs.mine) { [$0.partition] }
        case .allJobs:
            return ClusterFilter.partitionsByCluster(model.jobs.all) { [$0.partition] }
        case .nodes, .info:
            return ClusterFilter.partitionsByCluster(model.nodes.results) { $0.partitions }
        }
    }
}

/// The root screen of each tab.
struct TabRootView: View {

    @Environment(AppModel.self) private var model
    var tab: AppModel.Tab

    var body: some View {
        Group {
            switch tab {
            case .myJobs: JobsListView(kind: .mine)
            case .allJobs: JobsListView(kind: .all)
            case .nodes: NodesListView()
            case .info: InfoListView()
            }
        }
        // No `.task` here on purpose: `AppModel.syncActivity()` restarts the tab's poll loop on
        // every tab change and its first tick fires immediately, so adding a fetch here would
        // just issue every query twice.
    }
}

/// Pushed screens.
struct RouteView: View {

    @Environment(AppModel.self) private var model
    var route: AppModel.Route

    var body: some View {
        switch route {
        case .jobDetail(let host, let jobId, let owned):
            JobDetailScreen(host: host, jobId: jobId, owned: owned)
        case .nodeJobs(let host, let node):
            NodeJobsScreen(host: host, node: node)
        case .groupDetail(let host, let key):
            GroupDetailScreen(host: host, key: key)
        case .selectClusters:
            SelectClustersScreen()
        }
    }
}

/// The back bar every pushed screen puts at its top. `NavigationStack` on macOS provides no
/// visible chrome inside a popover, so the affordance is explicit.
struct ScreenHeader: View {

    var title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 6) {
            BackButton()

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background)
        Divider()
    }
}

/// The shared "nothing is selected" state (`manage-jobs.tsx:329`).
struct NoHostsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyState(
            symbol: "powerplug",
            title: "No active clusters",
            message: "Select one or more clusters first.",
            action: (title: "Open Select Clusters", run: { model.openSelectClusters() })
        )
    }
}
