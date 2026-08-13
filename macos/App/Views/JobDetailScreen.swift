import SlurmKit
import SwiftUI

/// The pushed job detail. Port of `JobDetailView.tsx`: a five-pane screen — Info, Schedule,
/// Utilization, Output, Error — over a single `scontrol show job` fetch.
struct JobDetailScreen: View {

    @Environment(AppModel.self) private var model
    var host: String
    var jobId: String
    var owned: Bool

    @State private var detail: JobDetailModel?

    var body: some View {
        Group {
            if let detail {
                JobDetailContent(detail: detail)
            } else {
                VStack(spacing: 0) {
                    ScreenHeader(title: "Job \(jobId)", subtitle: host)
                    ProgressView().controlSize(.small).padding(24)
                    Spacer()
                }
            }
        }
        .task {
            // `scontrol show job` is fetched **once**: it describes the job's configuration, and
            // the Schedule pane derives the moving parts from a local clock instead.
            let created = JobDetailModel(host: host, jobId: jobId, owned: owned, transport: model.transport)
            detail = created
            await created.load()
        }
        // The screen going away kills the metrics stream even if the Utilization pane was not
        // the one on top when the user backed out.
        .onDisappear { detail?.stopMetrics() }
    }
}

/// The detail screen over an already-constructed model. Split from `JobDetailScreen` so the
/// snapshot runner can preload a model and render this directly — `ImageRenderer` takes one
/// pass and never runs a `.task`.
struct JobDetailContent: View {

    @Bindable var detail: JobDetailModel
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Job \(detail.jobId)", subtitle: detail.host)

            Group {
                if snapshotMode {
                    // `Picker(.segmented)` is NSView-backed and does not survive `ImageRenderer`.
                    StaticSegments(
                        titles: JobDetailModel.Pane.allCases.map(\.title),
                        selected: detail.pane.title
                    )
                } else {
                    Picker("", selection: $detail.pane) {
                        ForEach(JobDetailModel.Pane.allCases) { pane in
                            Text(pane.title).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            Group {
                switch detail.pane {
                case .info: InfoPane(detail: detail)
                case .schedule: SchedulePane(detail: detail)
                case .utilization: UtilizationPane(detail: detail)
                case .stdout: LogPane(detail: detail, pane: detail.stdout)
                case .stderr: LogPane(detail: detail, pane: detail.stderr)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Info

/// Identity + allocation at a glance.
private struct InfoPane: View {

    var detail: JobDetailModel

    var body: some View {
        if let fields = detail.fields {
            PaneContainer {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Job \(fields["JobId"] ?? detail.jobId)")
                            .font(.system(size: 17, weight: .bold))
                        if let name = fields["JobName"], !name.isEmpty {
                            Text(name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                    MetaRow(title: "User", symbol: "person", text: JobTime.stripUid(fields["UserId"]))
                    Divider().padding(.vertical, 4)

                    MetaRow(title: "GPUs", symbol: "cpu") {
                        if let gpu = SlurmFormat.gpuInfoFromTres(detail.tres) {
                            Chip(
                                text: gpu.type.map { "\(gpu.count) × \(SlurmFormat.prettifyGpuModel($0))" }
                                    ?? "\(gpu.count) GPU",
                                color: Palette.green
                            )
                        } else {
                            Text("none").foregroundStyle(.secondary)
                        }
                    }
                    MetaRow(
                        title: "RAM",
                        symbol: "memorychip",
                        text: SlurmFormat.memFromTres(detail.tres).map(JobTime.prettifyMem) ?? "—"
                    )
                    MetaRow(
                        title: "CPUs",
                        symbol: "gauge.with.dots.needle.33percent",
                        text: (fields["NumCPUs"]?.isEmpty == false) ? fields["NumCPUs"]! : "—"
                    )
            }
        } else {
            LoadingPane(error: detail.error)
        }
    }
}

// MARK: - Schedule

/// Timing, shaped by state: RUNNING gets a progress bar toward the limit, PENDING gets the
/// reason and estimated start, finished jobs get the closed interval.
private struct SchedulePane: View {

    var detail: JobDetailModel

    var body: some View {
        if detail.fields == nil {
            LoadingPane(error: detail.error)
        } else if detail.isRunning {
            // Tick once a second so a running job's progress and remaining advance live —
            // and only while running, so a finished job does not re-render forever.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                body(now: context.date)
            }
        } else {
            body(now: Date())
        }
    }

    @ViewBuilder
    private func body(now: Date) -> some View {
        let fields = detail.fields ?? [:]
        let time = JobTime.buildJobTime(fields: fields, nowMs: now.timeIntervalSince1970 * 1000)

        PaneContainer {
                if detail.isPending {
                    MetaRow(title: "Status", symbol: "clock.badge.questionmark") {
                        Chip(text: "PENDING", color: StateColors.job("PENDING"))
                    }
                    MetaRow(
                        title: "Reason",
                        symbol: "questionmark.circle",
                        text: nonEmpty(SlurmFormat.shortReason(fields["Reason"])) ?? "—"
                    )
                    MetaRow(
                        title: "Est. Start",
                        symbol: "clock",
                        text: time.started.map { Display.dateWithRelative($0, now: now) } ?? "not yet estimated"
                    )
                    MetaRow(title: "Partition", symbol: "externaldrive", text: nonEmpty(fields["Partition"]) ?? "—")
                } else {
                    let state = fields["JobState"] ?? ""
                    MetaRow(title: "Status", symbol: "circle.fill") {
                        Chip(text: nonEmpty(state) ?? "—", color: StateColors.job(state))
                    }
                    if detail.isRunning, let progress = time.progress {
                        MetaRow(title: "Progress", symbol: "chart.bar") {
                            HStack(spacing: 6) {
                                MeterBar(value: progress)
                                Text("\(Int((progress * 100).rounded()))%")
                            }
                        }
                    }
                    Divider().padding(.vertical, 4)
                    if let elapsed = time.elapsedSec {
                        MetaRow(title: "Elapsed", symbol: "clock", text: SlurmFormat.formatDurationSeconds(elapsed))
                    }
                    if let remaining = time.remainingSec {
                        MetaRow(
                            title: "Remaining",
                            symbol: "hourglass",
                            text: SlurmFormat.formatDurationSeconds(remaining)
                        )
                    }
                    MetaRow(
                        title: "Started",
                        symbol: "play.circle",
                        text: Display.dateWithRelative(time.started, now: now)
                    )
                    MetaRow(
                        title: detail.isRunning ? "Ends (est.)" : "Ended",
                        symbol: "stop.circle",
                        text: Display.dateWithRelative(time.ends, now: now)
                    )
                    MetaRow(
                        title: "Time Limit",
                        symbol: "timer",
                        text: time.limitSec.map(SlurmFormat.formatDurationSeconds) ?? "unlimited"
                    )
                }
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Logs

/// Output (stdout) / Error (stderr). A one-shot `readLogTail` plus a 10 s poll while readable —
/// the live `tail -F` viewer is v1.1 and deliberately not built (SPEC-P3 §9).
private struct LogPane: View {

    var detail: JobDetailModel
    var pane: LogPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if detail.fields == nil {
                LoadingPane(error: detail.error)
            } else if !pane.owned {
                GateMessage(
                    title: pane.stream.label,
                    markdown: "Log files can only be read for **your own** jobs."
                )
            } else if pane.path.isEmpty {
                GateMessage(
                    title: pane.stream.label,
                    markdown: "No \(pane.stream.noun) file is set in this job's run configuration."
                )
            } else {
                HStack(spacing: 6) {
                    Text(pane.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Copy Path") { Clipboard.copy(pane.path) }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                    Button("Refresh") { Task { await pane.refresh() } }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .keyboardShortcut("r", modifiers: .command)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                if let error = pane.errorMessage {
                    CodeBlock(text: "Could not read the log file:\n\n\(error)")
                        .padding(.horizontal, 12)
                } else if let tail = pane.tail {
                    CodeBlock(text: tail.isEmpty ? "(empty — nothing written yet)" : tail)
                        .padding(.horizontal, 12)
                        .contextMenu {
                            Button("Copy Output") { Clipboard.copy(tail) }
                            Button("Copy File Path") { Clipboard.copy(pane.path) }
                        }
                } else {
                    ProgressView().controlSize(.small).padding(24).frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
        .task(id: pane.path) {
            await pane.refresh()
            pane.startPolling()
        }
        .onDisappear { pane.stopPolling() }
    }
}

/// The first gate every pane shares: no fields yet means the `scontrol` call is still in flight
/// (or failed).
private struct LoadingPane: View {
    var error: SshErrorInfo?

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 8) {
                let icon = StateColors.errorIcon(error.kind)
                Label(error.title, systemImage: icon.symbol)
                    .foregroundStyle(icon.color)
                    .font(.system(size: 12, weight: .medium))
                Text(error.hint ?? error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(32)
        }
    }
}
