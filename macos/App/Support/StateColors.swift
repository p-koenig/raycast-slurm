import SlurmKit
import SwiftUI

/// The single place a Slurm state becomes a colour.
///
/// `src/lib/format.ts` imports Raycast's `Color` — the one UI leak in the reference
/// implementation, and the one thing SlurmKit deliberately does not port. SlurmKit hands us
/// `JobStateCategory` / `NodeStateCategory` instead, and the mapping lands here, in exactly one
/// App-layer file (SPEC-P3 §10). Nothing else in the app may switch on a raw state string to
/// pick a colour.
///
/// The colours themselves live in `Resources/Assets.xcassets` with explicit light and dark
/// variants, so a tag stays legible in either appearance.
enum Palette {
    static let green = Color("SlurmGreen")
    static let yellow = Color("SlurmYellow")
    static let red = Color("SlurmRed")
    static let orange = Color("SlurmOrange")
    static let blue = Color("SlurmBlue")
    static let purple = Color("SlurmPurple")
    /// The stand-in for Raycast's `Color.SecondaryText`.
    static let secondary = Color("SlurmSecondary")
}

enum StateColors {

    /// Job state → colour. `format.ts:6-21` (`STATE_COLORS` + `stateColor`).
    static func job(_ state: String) -> Color {
        category(SlurmFormat.stateCategory(state))
    }

    static func category(_ category: JobStateCategory) -> Color {
        switch category {
        case .running: return Palette.green
        case .pending: return Palette.yellow
        case .completing: return Palette.purple
        case .completed: return Palette.blue
        case .cancelled: return Palette.secondary
        case .failed, .timeout: return Palette.red
        case .preempted, .suspended: return Palette.orange
        case .configuring: return Palette.yellow
        case .other: return Palette.secondary
        }
    }

    /// Node state → colour. `format.ts:373` (`nodeStateColor`).
    static func node(_ state: String) -> Color {
        switch SlurmFormat.nodeStateCategory(state) {
        case .unavailable: return Palette.red
        case .allocated: return Palette.blue
        case .mixed: return Palette.purple
        case .idle: return Palette.green
        case .reserved: return Palette.orange
        case .other: return Palette.secondary
        }
    }

    /// Saturation tint for a utilization percentage, matching the node list's "how full is it"
    /// semantics: green = headroom, orange = busy, red = near saturation
    /// (`JobDetailView.tsx:331`). Each pill is tinted independently.
    static func util(_ pct: Double?) -> Color {
        guard let pct else { return Palette.secondary }
        if pct >= 90 { return Palette.red }
        if pct >= 70 { return Palette.orange }
        return Palette.green
    }

    /// The `ClusterAuthRow` icon + tint per error kind (UI-INVENTORY §7).
    static func errorIcon(_ kind: SshErrorKind) -> (symbol: String, color: Color) {
        switch kind {
        case .auth: return ("lock.open.fill", Palette.yellow)
        case .hostKey: return ("exclamationmark.triangle.fill", Palette.red)
        case .hostNotInConfig: return ("questionmark.circle.fill", Palette.orange)
        case .unknownHost, .refused: return ("xmark.circle.fill", Palette.red)
        case .timeout: return ("clock.fill", Palette.orange)
        case .network: return ("wifi.slash", Palette.red)
        case .remoteCmd, .unknown: return ("exclamationmark.circle.fill", Palette.red)
        }
    }
}
