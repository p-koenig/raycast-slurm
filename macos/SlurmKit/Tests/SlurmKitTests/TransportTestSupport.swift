import Foundation

@testable import SlurmKit

// Test scaffolding for everything that touches the filesystem or a process.
//
// SAFETY: no test in this package may open a real SSH connection or contact a real host. The
// transport tests run against `StubSsh` — a shell script written into a temp directory and
// injected via `OpenSshTransport.Configuration.sshBinary` — which records its argv and replays a
// scripted stdout/stderr/exit code/delay. The real-cluster smoke test is a human gate.

/// A throwaway directory, removed by `cleanUp()`.
struct TempDir {

    let url: URL

    init(_ label: String = "slurmkit") {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path(percentEncoded: false) }

    /// Write `contents` to `relative`, creating intermediate directories. Returns the full path.
    @discardableResult
    func write(_ relative: String, _ contents: String, executable: Bool = false) -> String {
        let target = url.appending(path: relative, directoryHint: .notDirectory)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: target.path(percentEncoded: false),
            contents: Data(contents.utf8),
            attributes: executable ? [.posixPermissions: 0o755] : nil
        )
        return target.path(percentEncoded: false)
    }

    func makeDirectory(_ relative: String) -> String {
        let target = url.appending(path: relative, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target.path(percentEncoded: false)
    }

    func path(_ relative: String) -> String {
        url.appending(path: relative).path(percentEncoded: false)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative))
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOfFile: path(relative), encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A fake `ssh` binary: a `/bin/sh` script that records how it was called and replays a canned
/// result.
///
/// It writes one `---END---`-terminated record per invocation to `argv.log` (one argument per
/// line) and to `env.log` (the environment variables the transport is contractually required to
/// set). `delay` exists for the timeout test: the marker file is written *after* the sleep, so its
/// absence proves the process was actually killed rather than merely abandoned.
struct StubSsh {

    let dir: TempDir
    let binaryPath: String

    init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        delaySeconds: Double = 0
    ) {
        dir = TempDir("stub-ssh")
        dir.write("stdout", stdout)
        dir.write("stderr", stderr)
        dir.write("exit", "\(exitCode)")
        dir.write("delay", "\(delaySeconds)")

        let script = """
            #!/bin/sh
            d='\(dir.path)'
            {
              for a in "$@"; do printf '%s\\n' "$a"; done
              printf '%s\\n' '---END---'
            } >> "$d/argv.log"
            printf 'LC_ALL=%s\\nLANG=%s\\nSLURMKIT_TEST=%s\\n---END---\\n' "$LC_ALL" "$LANG" "$SLURMKIT_TEST" >> "$d/env.log"
            delay=$(cat "$d/delay")
            case "$delay" in
              0|0.0) ;;
              *) sleep "$delay" ;;
            esac
            : > "$d/completed"
            cat "$d/stdout"
            cat "$d/stderr" >&2
            exit $(cat "$d/exit")
            """
        binaryPath = dir.write("ssh", script, executable: true)
    }

    /// One entry per invocation, arguments in order.
    var invocations: [[String]] {
        guard let log = dir.read("argv.log") else { return [] }
        return records(log)
    }

    /// One entry per invocation: `["LC_ALL=…", "LANG=…", "SLURMKIT_TEST=…"]`.
    var environments: [[String]] {
        guard let log = dir.read("env.log") else { return [] }
        return records(log)
    }

    /// Written by the stub *after* its delay — absent means the process never got that far.
    var didComplete: Bool { dir.exists("completed") }

    private func records(_ log: String) -> [[String]] {
        log.components(separatedBy: "---END---\n")
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .map { $0.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
    }

    func cleanUp() {
        dir.cleanUp()
    }
}

/// Stub ssh + a temp control directory + a temp `~/.ssh/config`, wired into an `OpenSshTransport`.
struct TransportHarness {

    let stub: StubSsh
    let controlDir: TempDir
    let sshDir: TempDir
    let transport: OpenSshTransport

    /// - Parameter configuredHosts: aliases written into the temp `~/.ssh/config`. `nil` writes no
    ///   config file at all, which is the "No ~/.ssh/config" path.
    init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        delaySeconds: Double = 0,
        configuredHosts: [String]? = ["cluster"],
        controlPersist: String = "12h",
        maxOutputBytes: Int = Transport.defaultMaxOutputBytes,
        isDemoHost: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        stub = StubSsh(stdout: stdout, stderr: stderr, exitCode: exitCode, delaySeconds: delaySeconds)
        controlDir = TempDir("control")
        sshDir = TempDir("sshdir")
        if let configuredHosts {
            sshDir.write("config", configuredHosts.map { "Host \($0)\n  HostName \($0).example.edu\n" }.joined())
        }
        transport = OpenSshTransport(
            configuration: .init(
                sshBinary: stub.binaryPath,
                // A nested path that does not exist yet, so 0700 creation is exercised.
                controlDirectory: controlDir.path + "/sockets",
                controlPersist: controlPersist,
                environment: ["PATH": "/usr/bin:/bin", "SLURMKIT_TEST": "1"],
                sshConfig: SshConfig(directory: sshDir.path, homeDirectory: sshDir.path),
                isDemoHost: isDemoHost,
                maxOutputBytes: maxOutputBytes
            )
        )
    }

    /// Rewrite the temp `~/.ssh/config` mid-test (used to prove negative results are not memoized).
    func writeConfig(hosts: [String]) {
        sshDir.write("config", hosts.map { "Host \($0)\n  HostName \($0).example.edu\n" }.joined())
    }

    func removeConfig() {
        try? FileManager.default.removeItem(atPath: sshDir.path + "/config")
    }

    func cleanUp() {
        stub.cleanUp()
        controlDir.cleanUp()
        sshDir.cleanUp()
    }
}

/// The expected flag block for a given control directory — the parity contract with
/// `src/lib/ssh.ts`'s `baseOpts()`, order included.
func expectedBaseOptions(controlDirectory: String, controlPersist: String = "12h") -> [String] {
    [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=\(controlDirectory)/ssh-%C",
        "-o", "ControlPersist=\(controlPersist)",
        "-o", "ServerAliveInterval=30",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes",
    ]
}
