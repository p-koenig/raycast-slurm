import AppKit
import SlurmKit
import SwiftUI

// Shared row chrome. The extension gets this from Raycast's `List.Item` (icon + title +
// subtitle on the left, accessories on the right); SwiftUI has no such primitive, so the shape
// is rebuilt once here and every list uses it — which is what keeps a job reading identically
// in My Jobs, All Jobs and the node drill-down.

/// The popover's geometry. SPEC-P3 §1 asks for ~440×580; it ended up slightly wider because an
/// All Jobs row carries seven accessories (user, partition, elapsed/limit, CPUs, memory, GPU)
/// and at 440 pt the GPU tag — the one people actually scan for — was the thing that fell off
/// the right edge.
enum PopoverMetrics {
    static let width: CGFloat = 470
    static let height: CGFloat = 600
    static var size: CGSize { CGSize(width: width, height: height) }
}

/// A tinted capsule. Raycast's `{ tag: { value, color } }` accessory.
struct Chip: View {
    var text: String
    var color: Color = Palette.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A plain right-hand accessory. Raycast's `{ text: … }`.
struct Meta: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The standard row: leading symbol, title + subtitle, trailing accessories.
struct RowShell<Accessories: View>: View {
    var symbol: String
    var symbolColor: Color
    var title: String
    var subtitle: String?
    /// How much room the subtitle keeps when the row is tight. Job rows keep a small floor so a
    /// name degrades to `sd3…` rather than vanishing; node rows set it to 0, because their
    /// partition list matters far less than the utilization chips it would otherwise squeeze.
    var subtitleMinWidth: CGFloat = 30
    @ViewBuilder var accessories: Accessories

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(symbolColor)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if let subtitle, !subtitle.isEmpty {
                // The name is the element that gives way when the row is tight — the same
                // priority the extension has to fake with a character budget. It keeps a small
                // floor so it degrades to "sd3…" rather than vanishing, which is the spirit of
                // `fitSubtitleToRow`'s `Math.max(6, …)`.
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: subtitleMinWidth, alignment: .leading)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 3)
            accessories
                .layoutPriority(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .frame(minHeight: 25)
        .contentShape(Rectangle())
    }
}

/// Section header: host name on the left, match count on the right.
struct SectionHeaderView: View {
    var title: String
    var subtitle: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// A row's selection / hover background. Extracted so every list highlights identically.
struct RowBackground: View {
    var isSelected: Bool
    var isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.06) : .clear))
            .padding(.horizontal, 4)
    }
}

/// The back chevron a pushed screen shows. A `Button` here would render as an unrepresentable
/// placeholder in snapshot mode, so offscreen it degrades to the bare glyph.
struct BackButton: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back")
        }
    }
}

/// A clickable list row with hover and selection.
struct SelectableRow<Content: View, Menu: View>: View {
    var id: String
    @Binding var selection: String?
    var onActivate: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var menu: Menu

    @State private var hovering = false

    var body: some View {
        content
            .background(RowBackground(isSelected: selection == id, isHovered: hovering))
            .onHover { hovering = $0 }
            .onTapGesture {
                selection = id
                onActivate()
            }
            .contextMenu { menu }
            .id(id)
    }
}

/// The per-cluster failure row. Port of `ClusterAuthRow` (UI-INVENTORY §7).
///
/// It is rendered from the **unfiltered** results, so a cluster filter can never hide a cluster
/// that is broken — the reason the extension computes failures separately in every view.
struct ClusterErrorRow: View {
    var host: String
    var info: SshErrorInfo
    var onRetry: () -> Void
    var onReauth: () -> Void
    var onOpenClusters: () -> Void

    @Binding var selection: String?

    var body: some View {
        let icon = StateColors.errorIcon(info.kind)
        SelectableRow(
            id: "err:\(host)",
            selection: $selection,
            onActivate: { info.kind == .auth ? onReauth() : onRetry() }
        ) {
            RowShell(
                symbol: icon.symbol,
                symbolColor: icon.color,
                title: info.title,
                subtitle: info.hint ?? info.message
            ) {
                if info.kind == .auth {
                    Chip(text: "Reauth ⌘⇧R", color: Palette.yellow)
                } else {
                    Chip(text: "Retry ⌘R", color: Palette.secondary)
                }
            }
        } menu: {
            if info.kind == .auth {
                Button("Reauthenticate \(host)", action: onReauth)
            } else {
                Button("Retry", action: onRetry)
                Button("Open Terminal for \(host)", action: onReauth)
            }
            Button("Open Select Clusters", action: onOpenClusters)
            Divider()
            Button("Copy Error Details") { Clipboard.copy(info.raw) }
        }
    }
}

/// A centred empty state, with the inventory's title/description pairs.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// A labelled metadata row, the native equivalent of Raycast's
/// `List.Item.Detail.Metadata.Label`.
struct MetaRow<Value: View>: View {
    var title: String
    var symbol: String?
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 13, alignment: .leading)
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            value
                .font(.system(size: 11))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

extension MetaRow where Value == Text {
    init(title: String, symbol: String? = nil, text: String) {
        self.init(title: title, symbol: symbol) { Text(text) }
    }
}

/// The transient banner that replaces Raycast's toasts (SPEC-P3 §4): bottom overlay,
/// auto-dismissed after 3 s, tap to dismiss. The copy is the inventory's, unchanged.
struct BannerOverlay: View {
    var banner: AppModel.Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title)
                    .font(.system(size: 11, weight: .medium))
                if let message = banner.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onTapGesture(perform: onDismiss)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var symbol: String {
        switch banner.style {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .progress: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch banner.style {
        case .success: return Palette.green
        case .failure: return Palette.red
        case .progress: return Palette.blue
        }
    }
}

/// A fenced, monospaced block — the native form of the extension's markdown code fences.
struct CodeBlock: View {
    var text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Prose shown in place of a pane's content when a gate blocks it. The **bold** words are the
/// inventory's emphasis and are load-bearing copy, so they are reproduced as markdown.
struct GateMessage: View {
    var title: String
    var markdown: LocalizedStringKey
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(markdown)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Snapshot mode

/// Whether the view tree is being drawn by `ImageRenderer` rather than by the window server.
///
/// `ImageRenderer` performs one layout pass into a `GraphicsContext`, and two things follow from
/// that, both of which this flag exists to work around:
///
/// * **AppKit-backed controls do not draw.** `Picker(.segmented)`, `TextField`, `Button`,
///   `Menu`, `SettingsLink` and `ProgressView` are `NSView`s under the hood; the renderer paints
///   a yellow "unrepresentable" placeholder where each one should be.
/// * **Lazy containers stay empty.** `ScrollView` + `LazyVStack` never materialise their rows,
///   because nothing ever scrolls them into view.
///
/// So in snapshot mode the chrome is redrawn with plain SwiftUI shapes and the lists become
/// eager `VStack`s. The *content* — every row, chip, colour and string this phase is verified on
/// — is the same code either way.
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// A scrolling list that turns into a plain stack when rendered offscreen.
struct ListContainer<Content: View>: View {

    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder var content: Content

    var body: some View {
        if snapshotMode {
            VStack(alignment: .leading, spacing: 0) { content }
                // Take the ideal height first: without this the squeeze into the popover's
                // remaining space makes fixed-height children (the charts) overlap the rows
                // above them.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) { content }
                    .padding(.bottom, 8)
            }
        }
    }
}

/// A scrolling detail pane, same trade-off as `ListContainer`.
struct PaneContainer<Content: View>: View {

    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder var content: Content

    var body: some View {
        if snapshotMode {
            VStack(alignment: .leading, spacing: 2) { content }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { content }
                    .padding(.vertical, 10)
            }
        }
    }
}

/// A drawn progress bar. Replaces `ProgressView(value:)`, which is `NSProgressIndicator` and so
/// cannot be rendered offscreen — and which looks heavier than a metadata row wants anyway.
struct MeterBar: View {
    var value: Double
    var width: CGFloat = 150

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(0, min(1, value)) * width)
        }
        .frame(width: width, height: 5)
    }
}

/// A drawn stand-in for `Picker(.segmented)`, used only in snapshot mode.
struct StaticSegments: View {
    var titles: [String]
    var selected: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 11, weight: title == selected ? .semibold : .regular))
                    .foregroundStyle(title == selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(title == selected ? Color.primary.opacity(0.14) : .clear)
                    )
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Keyboard navigation

/// Arrow-key + Return navigation over a flat list of row ids (SPEC-P3 §5).
///
/// SwiftUI's `List` gives this for free but is AppKit-backed, which `ImageRenderer` cannot
/// draw — and the snapshot mode that verifies this app *is* `ImageRenderer`. So the lists are
/// `LazyVStack`s and the keyboard behaviour is reimplemented here, which also makes the
/// selection model explicit enough to drive from a Return-key default action.
struct KeyboardNavigation: ViewModifier {
    @Binding var selection: String?
    var ids: [String]
    var onActivate: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.return) {
                guard let selection, ids.contains(selection) else { return .ignored }
                onActivate(selection)
                return .handled
            }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = delta > 0 ? ids.first : ids.last
            return .handled
        }
        let next = min(max(index + delta, 0), ids.count - 1)
        selection = ids[next]
        return .handled
    }
}

extension View {
    func keyboardNavigation(
        selection: Binding<String?>,
        ids: [String],
        onActivate: @escaping (String) -> Void
    ) -> some View {
        modifier(KeyboardNavigation(selection: selection, ids: ids, onActivate: onActivate))
    }
}
