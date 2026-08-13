import Foundation

/// Namespace for demo mode.
///
/// `DemoTransport` is an `SshTransport` that serves canned output keyed by the remote command
/// string. Like the extension's demo mode, that output still flows through the *real* parsers, so
/// wire-format drift surfaces immediately instead of hiding behind a second code path.
///
/// The two fictional clusters below mirror `DEMO_HOSTS` in `src/lib/demo.ts`, which is what the
/// exported fixtures are keyed on. Activation (`SLURMBAR_DEMO=1` or a hidden `UserDefaults` key)
/// is App-layer wiring in P3; SlurmKit only provides the transport.
public enum Demo {

    /// `DEMO_USER`.
    public static let user = "r.shaw"

    public static let hosts: [SshHost] = [
        SshHost(name: "phoenix", hostName: "phoenix.hpc.example.edu", user: Demo.user),
        SshHost(name: "nimbus", hostName: "nimbus.hpc.example.edu", user: Demo.user),
    ]

    /// `isDemoHost` — the predicate `OpenSshTransport.Configuration.isDemoHost` is wired to in
    /// demo mode, so a fictional alias never hits the `~/.ssh/config` gate.
    public static func isDemoHost(_ host: String) -> Bool {
        hosts.contains { $0.name == host }
    }
}
