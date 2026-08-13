import Foundation

@testable import SlurmKit

/// Builds a `DemoTransport` from the golden fixtures.
///
/// This is the loader SPEC-P2 asks for on the test side: every fixture case that was captured
/// through a real lib call records `(host, cmd, input)`, which is exactly a demo response map.
/// Feeding the client from it closes the loop transport → parse on the same data the TypeScript
/// produced, and makes "the client issues exactly the command the extension issued" checkable —
/// a drifting builder shows up as a missing entry, never as stale output.
///
/// (P3 bundles an equivalent map as an app resource; that is its concern, not SlurmKit's.)
enum DemoFixtures {

    /// Fixture kinds whose cases carry a host and a command.
    static let commandKinds = [
        "jobs-user", "jobs-all", "node-jobs", "partition-activity", "nodes", "job-detail", "metrics-script",
    ]

    /// Commands the extension issues but that no fixture captures: `whoami` has no parser to pin,
    /// and `scancel` produces no output at all. Synthesised here so the client's own methods are
    /// still exercised end to end.
    static let syntheticEntries: [DemoTransport.Entry] = Demo.hosts.flatMap { host in
        [
            DemoTransport.Entry(host: host.name, command: "whoami", output: "\(Demo.user)\n"),
            DemoTransport.Entry(host: host.name, command: "scancel 145789", output: ""),
            DemoTransport.Entry(
                host: host.name,
                command: SlurmClient.readLogTailCommand(path: "/scratch/r.shaw/slurm-145789.out", lines: 200),
                output: "epoch 3/10 loss 0.214\nepoch 4/10 loss 0.198\n"
            ),
        ]
    }

    static let entries: [DemoTransport.Entry] = {
        var entries: [DemoTransport.Entry] = []
        for kind in commandKinds {
            for rawCase in Fixtures.rawCases(kind) {
                guard let object = rawCase.objectValue,
                    let host = object["host"]?.stringValue,
                    let command = object["cmd"]?.stringValue
                else { continue }
                // `metrics-script` has no `input`: it pins the command, not a parse.
                entries.append(
                    DemoTransport.Entry(host: host, command: command, output: object["input"]?.stringValue ?? "")
                )
            }
        }
        return entries + syntheticEntries
    }()

    static func transport() -> DemoTransport {
        DemoTransport(entries: entries)
    }

    /// A fresh transport per call, so `recordedCalls()` only ever describes one test.
    static func client(host: String) -> (SlurmClient, DemoTransport) {
        let transport = transport()
        return (SlurmClient(host: host, transport: transport), transport)
    }
}
