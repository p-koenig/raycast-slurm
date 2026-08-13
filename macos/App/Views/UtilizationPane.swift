import Charts
import SlurmKit
import SwiftUI

/// Live per-job utilization — the pane SPEC-P3 §8 asks to exceed the extension on.
///
/// It keeps everything the inventory specifies (the run / trailing-window pill pairs, the
/// `utilColor` thresholds, the window growing from 0 to 30 s) and adds what a terminal UI could
/// not: a Swift Charts sparkline per series, so "94% average" also shows *how* it got there —
/// a GPU sawtoothing between 20 % and 100 % averages the same as one pinned at 60 %, and only
/// the first is a dataloader problem.
struct UtilizationPane: View {

    var detail: JobDetailModel

    var body: some View {
        // The gates, in the inventory's order (§9). Order matters: a job that is neither owned
        // nor running should read as "not running", because that is the fact the user can act on.
        if detail.fields == nil {
            LoadingGate(error: detail.error)
        } else if !detail.isRunning {
            GateMessage(
                title: "Utilization",
                markdown: "Live metrics are only available while the job is **running**.",
                detail: "Current state: \(detail.state.isEmpty ? "—" : detail.state)"
            )
        } else if !detail.owned {
            GateMessage(
                title: "Utilization",
                markdown: "Live metrics are only available for **your own** jobs."
            )
        } else if let metrics = detail.metrics {
            LiveUtilization(metrics: metrics)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(32)
                .task { detail.startMetrics() }
        }
    }
}

/// The pane once a stream is attached.
struct LiveUtilization: View {

    var metrics: MetricsModel

    var body: some View {
        Group {
            if let error = metrics.errorMessage, metrics.samples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Utilization").font(.system(size: 13, weight: .semibold))
                    Text("Could not start the metrics stream:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    CodeBlock(text: error)
                    Spacer(minLength: 0)
                }
                .padding(12)
            } else if metrics.samples.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            } else {
                content
            }
        }
        // Kill the `srun --overlap` step when the pane goes away. A leaked one holds a slot on
        // the cluster for as long as the job runs.
        .onDisappear { metrics.stop() }
    }

    private var windowLabel: String { "\(Int(metrics.windowSeconds))s" }

    private var content: some View {
        PaneContainer {
                MetaRow(title: "Status", symbol: "bolt.horizontal") {
                    Chip(text: "RUNNING", color: StateColors.job("RUNNING"))
                }

                let gpus = metrics.gpus
                if gpus.isEmpty {
                    Divider().padding(.vertical, 4)
                    MetaRow(title: "GPUs", symbol: "cpu", text: "none allocated")
                } else {
                    ForEach(gpus, id: \.index) { gpu in
                        Divider().padding(.vertical, 4)
                        MetaRow(title: "GPU \(gpu.index)", symbol: "cpu", text: label(for: gpu))
                        metricRow(
                            "Utilization",
                            runKey: RunStats.gpuKey(index: gpu.index, field: .util),
                            pick: { MetricsModel.gpuValue($0, index: gpu.index, field: .util) }
                        )
                        metricRow(
                            "VRAM",
                            runKey: RunStats.gpuKey(index: gpu.index, field: .memPct),
                            pick: { MetricsModel.gpuValue($0, index: gpu.index, field: .memPct) }
                        )
                        Sparkline(
                            series: [
                                .init(
                                    name: "util",
                                    color: Palette.green,
                                    points: metrics.series { MetricsModel.gpuValue($0, index: gpu.index, field: .util) }
                                ),
                                .init(
                                    name: "vram",
                                    color: Palette.blue,
                                    points: metrics.series {
                                        MetricsModel.gpuValue($0, index: gpu.index, field: .memPct)
                                    }
                                ),
                            ]
                        )
                    }
                }

                Divider().padding(.vertical, 4)
                metricRow("CPU", runKey: RunStats.cpuKey, pick: { $0.cpu })
                Sparkline(series: [.init(name: "cpu", color: Palette.orange, points: metrics.series { $0.cpu })])
                metricRow("RAM", runKey: RunStats.ramKey, pick: { $0.ram })
                Sparkline(series: [.init(name: "ram", color: Palette.purple, points: metrics.series { $0.ram })])
        }
    }

    /// `"{PrettyName} · {N} GB"` — the model and total VRAM, from the latest tick that saw the
    /// device.
    private func label(for gpu: GpuSample) -> String {
        let name = gpu.name.isEmpty ? "GPU" : SlurmFormat.prettifyGpuModel(gpu.name)
        guard gpu.memTotalMiB > 0 else { return name }
        return "\(name) · \(Int((gpu.memTotalMiB / 1024).rounded())) GB"
    }

    /// One labelled row carrying two independently-tinted pills: the run average (every tick
    /// since the pane opened, from the unbounded `RunStats`) and the trailing-window average
    /// (≤30 s, from the capped sample array).
    @ViewBuilder
    private func metricRow(
        _ title: String,
        runKey: String,
        pick: @escaping (MetricSample) -> Double?
    ) -> some View {
        let run = metrics.runAverage(runKey)
        let window = metrics.windowAverage(pick)
        MetaRow(title: title) {
            HStack(spacing: 4) {
                Chip(text: "run \(percent(run))", color: StateColors.util(run))
                Chip(text: "\(windowLabel) \(percent(window))", color: StateColors.util(window))
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }
}

/// A fixed 0–100 sparkline with a subtle area fill and no legend — the pill labels above it are
/// the legend (SPEC-P3 §8).
struct Sparkline: View {

    struct Series: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let points: [(x: Int, y: Double)]
    }

    var series: [Series]

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points, id: \.x) { point in
                    // `.unstacked` is load-bearing: `AreaMark` stacks multiple series by
                    // default, so a GPU at 94 % utilization and 78 % VRAM was drawing a 172 %
                    // band that spilled out of the 0–100 plot area and over the rows above it.
                    // These two series are independent readings, not parts of a whole.
                    AreaMark(
                        x: .value("Sample", point.x),
                        y: .value("Percent", point.y),
                        series: .value("Series", line.name),
                        stacking: .unstacked
                    )
                    .foregroundStyle(line.color.opacity(0.12))
                    .interpolationMethod(.monotone)
                }
                ForEach(line.points, id: \.x) { point in
                    LineMark(
                        x: .value("Sample", point.x),
                        y: .value("Percent", point.y),
                        series: .value("Series", line.name)
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
                }
            }
        }
        // Fixed axis: a self-scaling y makes 60 % and 95 % look identical, which is exactly the
        // question this chart exists to answer.
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) {
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// Loading / error placeholder shared with the other panes.
struct LoadingGate: View {
    var error: SshErrorInfo?

    var body: some View {
        if let error {
            GateMessage(title: error.title, markdown: LocalizedStringKey(error.hint ?? error.message))
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(32)
        }
    }
}
