import AppKit
import Foundation
import SlurmKit
import SwiftUI

/// Headless screen rendering — the mechanism SPEC-P3's acceptance rests on.
///
/// Driving a real `MenuBarExtra` popover from a shell is flaky (it needs a click at real screen
/// coordinates, and the window has no scriptable identity), so instead: boot the demo stores,
/// wait for both fictional clusters to answer, then render each key screen through SwiftUI's
/// `ImageRenderer` at 2× and exit. Any failure is a non-zero exit, so this is usable as a CI
/// gate and not just as a screenshot tool.
///
/// The one structural consequence: `ImageRenderer` performs a **single** layout pass and never
/// runs a `.task`, so every screen has to be reachable from an already-populated model. That is
/// why the detail screens are split into `…Screen` (fetches) and `…Content` (renders) — the
/// runner preloads the model and renders the content half.
///
/// It is also why the lists are `LazyVStack`s rather than `List`s: `List` is NSTableView-backed
/// on macOS and renders blank here.
@MainActor
enum SnapshotRunner {

    /// Each PNG plus what it is there to evidence. The descriptions double as the report's
    /// checklist.
    struct Shot {
        let name: String
        let evidences: String
    }

    static func run(directory: String, model: AppModel) async {
        do {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try await boot(model: model)
            let shots = try await render(into: url, model: model)
            FileHandle.standardError.write(
                Data("snapshot: wrote \(shots.count) images to \(url.path)\n".utf8)
            )
            for shot in shots {
                FileHandle.standardError.write(Data("  \(shot.name).png — \(shot.evidences)\n".utf8))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    enum SnapshotError: LocalizedError {
        case noData(String)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noData(let what): return "demo data never arrived: \(what)"
            case .renderFailed(let what): return "ImageRenderer produced no image for \(what)"
            }
        }
    }

    // MARK: - Boot

    /// Bring the demo stores to a state where every screen has something real to draw.
    private static func boot(model: AppModel) async throws {
        await model.clusters.reload()
        await model.syncHosts()
        await model.jobs.refreshUsers()
        await model.jobs.refreshMine()
        await model.jobs.refreshAll()
        await model.nodes.refresh()

        let expected = Set(Demo.hosts.map(\.name))
        guard expected.isSubset(of: Set(model.jobs.mine.compactMap { $0.isOk ? $0.host : nil })) else {
            throw SnapshotError.noData("my jobs for \(expected.sorted().joined(separator: ", "))")
        }
        guard expected.isSubset(of: Set(model.nodes.results.compactMap { $0.isOk ? $0.host : nil })) else {
            throw SnapshotError.noData("nodes for \(expected.sorted().joined(separator: ", "))")
        }
    }

    // MARK: - Screens

    private static func render(into directory: URL, model: AppModel) async throws -> [Shot] {
        var shots: [Shot] = []

        // --- The four tabs -------------------------------------------------------------
        for (tab, evidence) in [
            (
                AppModel.Tab.myJobs,
                "My Jobs: per-cluster sections with match counts, job-row accessory order "
                    + "(partition · elapsed/limit · CPU · mem · GPU), state-tinted hammers"
            ),
            (
                AppModel.Tab.allJobs,
                "All Jobs: same rows plus the leading user chip (yellow when it is mine, blue otherwise)"
            ),
            (
                AppModel.Tab.nodes,
                "Nodes: nodeUtilTags chips (state/cpu/mem/gpu) with their threshold colours, "
                    + "and the yellow person marker on nodes where I have jobs"
            ),
            (AppModel.Tab.info, "Info: shapes grouped per cluster, '{n} nodes · {m} shapes' subtitle, count chips"),
        ] {
            model.tab = tab
            shots.append(
                try shoot(
                    name: "tab-\(tab.rawValue)",
                    evidences: evidence,
                    into: directory,
                    model: model,
                    view: PopoverChrome { TabRootView(tab: tab) }
                )
            )
        }
        model.tab = .myJobs

        // --- Job detail: a running, owned job ------------------------------------------
        let running = JobDetailModel(
            host: "phoenix",
            jobId: "145789",
            owned: true,
            transport: model.transport
        )
        await running.load()
        guard running.fields != nil else { throw SnapshotError.noData("scontrol show job 145789") }

        running.pane = .info
        shots.append(
            try shoot(
                name: "jobdetail-info",
                evidences: "Info pane: UserId with the (uid) tail stripped, green GPU chip from AllocTRES, "
                    + "RAM via prettifyMem, CPU count",
                into: directory,
                model: model,
                view: PopoverChrome { JobDetailContent(detail: running) }
            )
        )

        running.pane = .schedule
        shots.append(
            try shoot(
                name: "jobdetail-schedule",
                evidences: "Schedule pane for a RUNNING job: state chip, progress toward the time limit, "
                    + "elapsed / remaining / started / Ends (est.) / time limit",
                into: directory,
                model: model,
                view: PopoverChrome { JobDetailContent(detail: running) }
            )
        )

        // Utilization needs real ticks before the charts have anything to draw.
        let metrics = running.startMetrics()
        await metrics.awaitSamples(12)
        guard metrics.samples.count >= 10 else {
            throw SnapshotError.noData("metric ticks (got \(metrics.samples.count))")
        }
        running.pane = .utilization
        shots.append(
            try shoot(
                name: "jobdetail-utilization",
                evidences: "Utilization pane: run/window pill pairs with utilColor thresholds, the growing "
                    + "window label, and one Swift Charts sparkline per GPU plus CPU and RAM",
                into: directory,
                model: model,
                view: PopoverChrome { JobDetailContent(detail: running) }
            )
        )
        running.stopMetrics()

        // --- The not-owned Utilization gate --------------------------------------------
        let notOwned = JobDetailModel(host: "phoenix", jobId: "145789", owned: false, transport: model.transport)
        await notOwned.load()
        notOwned.pane = .utilization
        shots.append(
            try shoot(
                name: "jobdetail-utilization-not-owned",
                evidences: "The ownership gate, verbatim: \"Live metrics are only available for **your own** jobs.\"",
                into: directory,
                model: model,
                view: PopoverChrome { JobDetailContent(detail: notOwned) }
            )
        )

        // --- A pending job's Info: the placeholder-TRES rule ----------------------------
        let pending = JobDetailModel(host: "phoenix", jobId: "145847", owned: true, transport: model.transport)
        await pending.load()
        pending.pane = .info
        shots.append(
            try shoot(
                name: "jobdetail-pending-info",
                evidences: "firstMeaningfulTres: this pending job's AllocTRES is a placeholder, so GPUs and RAM "
                    + "must resolve from ReqTRES (2 × A100, 64 GB) instead of reading as none",
                into: directory,
                model: model,
                view: PopoverChrome { JobDetailContent(detail: pending) }
            )
        )

        // --- Node drill-down with the multi-node caveat ---------------------------------
        let nodeJobs = NodeJobsModel(host: "phoenix", node: "gpu01", transport: model.transport)
        await nodeJobs.refresh()
        guard !nodeJobs.jobs.isEmpty else { throw SnapshotError.noData("running jobs on phoenix gpu01") }
        let node = model.nodes.node(host: "phoenix", name: "gpu01")
        shots.append(
            try shoot(
                name: "nodejobs-multinode",
                evidences: "NodeJobs: the node row repeated with its chips, jobs sorted by footprint, owner chips "
                    + "(yellow = mine), and the secondary \"2 nodes\" caveat tag on the job whose AllocTRES "
                    + "covers more than this node",
                into: directory,
                model: model,
                view: PopoverChrome { NodeJobsContent(jobs: nodeJobs, node: node) }
            )
        )

        // --- Cluster picker -------------------------------------------------------------
        shots.append(
            try shoot(
                name: "select-clusters",
                evidences: "Select Clusters: Active/Available sections, the Active chip, the green "
                    + "\"connection running\" dot, user chip and HostName",
                into: directory,
                model: model,
                view: PopoverChrome { SelectClustersScreen() }
            )
        )

        return shots
    }

    // MARK: - Rendering

    private static func shoot(
        name: String,
        evidences: String,
        into directory: URL,
        model: AppModel,
        view: some View
    ) throws -> Shot {
        let renderer = ImageRenderer(
            content:
                view
                .environment(model)
                .environment(\.snapshotMode, true)
                .frame(width: PopoverMetrics.width, height: PopoverMetrics.height, alignment: .top)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw SnapshotError.renderFailed(name) }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        try png.write(to: directory.appending(path: "\(name).png"))
        return Shot(name: name, evidences: evidences)
    }
}
