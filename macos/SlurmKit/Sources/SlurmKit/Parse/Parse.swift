/// Umbrella namespace for the pure parsing and formatting functions ported from
/// `src/lib/slurm.ts`, `src/lib/format.ts`, `src/lib/hostlist.ts`, `src/lib/metrics.ts` and
/// `src/lib/shell.ts`.
///
/// The functions themselves live in the sibling files as top-level `public` enums —
/// `SqueueParse`, `ScontrolParse`, `SlurmFormat`, `Hostlist`, `MetricStream`, `SlurmCommands`
/// and the free function `shellQuote` — so call sites read like the TypeScript they mirror.
///
/// Everything under this namespace stays free of UI types: the TypeScript `format.ts` imports
/// Raycast's `Color`, and that is the one leak which is deliberately *not* ported. State →
/// colour mapping lives in the App layer, which consumes `JobStateCategory` /
/// `NodeStateCategory` instead.
///
/// There is no I/O here. Every entry point takes the raw stdout of one remote command (built by
/// `SlurmCommands`) and returns models; Transport supplies the bytes.
public enum Parse {

    /// The parsing namespaces this module vends, by name. Documentation only.
    public static let namespaces: [String] = [
        "SqueueParse", "ScontrolParse", "SlurmFormat", "Hostlist", "MetricStream", "SlurmCommands",
    ]
}
