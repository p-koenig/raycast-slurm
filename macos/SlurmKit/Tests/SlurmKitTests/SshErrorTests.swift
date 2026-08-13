import Foundation
import Testing

@testable import SlurmKit

// Port tests for `src/lib/errors.ts`. The stderr samples are what OpenSSH and Slurm actually
// print; the kinds are the contract the UI switches on.

@Suite("SSH error classification")
struct SshErrorClassificationTests {

    struct Case: CustomStringConvertible, Sendable {
        let name: String
        let stderr: String
        let kind: SshErrorKind
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "auth-publickey",
            stderr: "r.shaw@phoenix.example.edu: Permission denied (publickey,keyboard-interactive).",
            kind: .auth
        ),
        Case(name: "auth-password-prompt", stderr: "r.shaw@phoenix's password:", kind: .auth),
        Case(name: "auth-2fa-verification-code", stderr: "(r.shaw@phoenix) Verification code:", kind: .auth),
        Case(name: "auth-two-factor", stderr: "Two-factor authentication is required for this account.", kind: .auth),
        Case(
            name: "auth-channel",
            stderr: "Could not request channel confirmation, disconnecting.",
            kind: .auth
        ),
        Case(name: "host-key-verification", stderr: "Host key verification failed.", kind: .hostKey),
        Case(
            name: "host-key-changed",
            stderr: """
                @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
                @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                """,
            kind: .hostKey
        ),
        Case(name: "dns-could-not-resolve", stderr: "ssh: Could not resolve hostname phoenix: nodename nor servname provided, or not known", kind: .unknownHost),
        Case(name: "dns-glibc", stderr: "ssh: Could not resolve hostname phoenix: Name or service not known", kind: .unknownHost),
        Case(
            name: "dns-temporary-failure",
            stderr: "ssh: phoenix: Temporary failure in name resolution",
            kind: .unknownHost
        ),
        Case(name: "refused", stderr: "ssh: connect to host phoenix port 22: Connection refused", kind: .refused),
        Case(name: "timeout-connection", stderr: "ssh: connect to host phoenix port 22: Connection timed out", kind: .timeout),
        Case(name: "timeout-operation", stderr: "ssh: connect to host phoenix port 22: Operation timed out", kind: .timeout),
        Case(name: "network-unreachable", stderr: "ssh: connect to host phoenix port 22: Network is unreachable", kind: .network),
        Case(name: "network-no-route", stderr: "ssh: connect to host phoenix port 22: No route to host", kind: .network),
        Case(name: "remote-cmd-scontrol", stderr: "slurm_load_jobs error: Invalid job id specified", kind: .remoteCmd),
        Case(name: "remote-cmd-scancel", stderr: "scancel: error: Kill job error on job id 145789: Invalid job id specified", kind: .remoteCmd),
        Case(name: "remote-cmd-squeue", stderr: "squeue: error: Invalid node name specified", kind: .remoteCmd),
        Case(name: "unknown-empty", stderr: "", kind: .unknown),
    ]

    @Test("stderr maps to the documented kind", arguments: cases)
    func kinds(c: Case) {
        let info = classifySshError(SshFailure(stderr: c.stderr, message: "Command failed with exit code 255"), host: "phoenix")
        #expect(info.kind == c.kind, "\(c.name)")
        #expect(info.host == "phoenix")
    }

    @Test("the check order is the TypeScript's: auth beats everything it co-occurs with")
    func ordering() {
        // A real failed 2FA login prints both a permission-denied line and a connection-closed
        // one; the auth branch runs first, and the UI needs it to.
        let stderr = """
            Connection timed out during banner exchange
            Permission denied (keyboard-interactive).
            """
        #expect(classifySshError(SshFailure(stderr: stderr)).kind == .auth)
    }

    @Test("a Slurm permission error is classified as auth — a TS quirk the port keeps")
    func slurmPermissionDeniedLooksLikeAuth() {
        // `scancel` on someone else's job prints "Access/permission denied", which the auth regex
        // (`/Permission denied/i`) matches before the remote-cmd branch is ever reached. The
        // extension has always behaved this way; reproducing it is the point of a port. If it is
        // ever fixed, fix it in `src/lib/errors.ts` first and re-export the parity expectations.
        let stderr = "scancel: error: Kill job error on job id 145789: Access/permission denied"
        #expect(classifySshError(SshFailure(stderr: stderr), host: "phoenix").kind == .auth)
    }

    @Test("the flag classifies a timeout even when stderr says nothing")
    func flagDrivenTimeout() {
        let info = classifySshError(SshFailure(message: "Command timed out", timedOut: true), host: "phoenix")
        #expect(info.kind == .timeout)
        #expect(info.title == "Connection timed out — phoenix")
        #expect(info.hint == "Check your VPN, your network, or that the host is online.")
    }

    @Test("the setlocale warning is stripped instead of being reported as the failure")
    func setlocaleIsStripped() {
        // The incident this exists for: Raycast forwards a mangled macOS CFLocale via SendEnv, the
        // remote bash complains, and that warning became the message of a genuinely-failed
        // `scontrol show job` — hiding the real reason.
        let stderr = """
            bash: warning: setlocale: LC_ALL: cannot change locale (en_US@rg=deu-u-ca-gregory-u-nu-latn)
            slurm_load_jobs error: Invalid job id specified
            """
        let info = classifySshError(SshFailure(stderr: stderr), host: "phoenix")
        #expect(info.kind == .remoteCmd)
        #expect(info.message == "slurm_load_jobs error: Invalid job id specified")
        // …and `raw` keeps the unfiltered text for the copy-details action.
        #expect(info.raw.contains("setlocale"))
    }

    @Test(
        "benign-only stderr is not a remote command failure",
        arguments: [
            "bash: warning: setlocale: LC_ALL: cannot change locale (en_US@rg=deu)",
            "setlocale: cannot change locale (C.UTF-8)",
            "Warning: Permanently added 'phoenix.example.edu' (ED25519) to the list of known hosts.",
            "Pseudo-terminal will not be allocated because stdin is not a terminal.",
        ]
    )
    func benignOnly(stderr: String) {
        let info = classifySshError(SshFailure(stderr: stderr, message: "Command failed with exit code 1"), host: "phoenix")
        #expect(info.kind == .unknown)
        #expect(info.message == "Command failed with exit code 1")
        #expect(info.raw == stderr)
    }

    @Test("every benign line at once still leaves a real error visible")
    func benignMixedWithReal() {
        let stderr = """
            Warning: Permanently added 'phoenix.example.edu' (ED25519) to the list of known hosts.
            Pseudo-terminal will not be allocated because stdin is not a terminal.
            bash: warning: setlocale: LC_ALL: cannot change locale
            squeue: error: Invalid node name specified
            """
        #expect(classifySshError(SshFailure(stderr: stderr)).message == "squeue: error: Invalid node name specified")
    }

    @Test("the message is the first non-blank line, truncated at 200 characters")
    func truncation() {
        let long = String(repeating: "x", count: 260)
        let info = classifySshError(SshFailure(stderr: "\n\n  \(long)  \nsecond line"))
        #expect(info.kind == .remoteCmd)
        #expect(info.message.count == 200)
        #expect(info.message.hasSuffix("…"))
        #expect(info.message.hasPrefix(String(repeating: "x", count: 199)))
    }

    @Test("host suffixing follows the TS: title gets an em dash, remote-cmd gets a colon")
    func hostSuffixes() {
        #expect(classifySshError(SshFailure(stderr: "Connection refused"), host: "nimbus").title == "Connection refused — nimbus")
        #expect(classifySshError(SshFailure(stderr: "Connection refused")).title == "Connection refused")
        #expect(classifySshError(SshFailure(stderr: "squeue: error: boom"), host: "nimbus").title == "nimbus: command failed")
        #expect(classifySshError(SshFailure(stderr: "squeue: error: boom")).title == "Remote command failed")
        #expect(
            classifySshError(SshFailure(stderr: "Host key verification failed."), host: "nimbus").hint
                == "If you trust the new key, run: ssh-keygen -R nimbus"
        )
        #expect(
            classifySshError(SshFailure(stderr: "Host key verification failed.")).hint
                == "If you trust the new key, run: ssh-keygen -R <host>"
        )
    }

    @Test("raw falls back from stderr to message to a placeholder")
    func rawFallback() {
        #expect(classifySshError(SshFailure(stderr: "boom", message: "wrapped")).raw == "boom")
        #expect(classifySshError(SshFailure(message: "wrapped")).raw == "wrapped")
        #expect(classifySshError(SshFailure()).raw == "Unknown error")
    }

    @Test("an already-classified error is only rehomed")
    func rehoming() {
        let original = makeHostNotInConfigError(host: "phoenix")
        let rehomed = classifySshError(original, host: "nimbus")
        #expect(rehomed.kind == .hostNotInConfig)
        #expect(rehomed.host == "phoenix", "an error that already names its host keeps it")

        let hostless = SshError(SshErrorInfo(kind: .unknown, title: "t", message: "m", raw: "r"))
        #expect(classifySshError(hostless, host: "nimbus").host == "nimbus")
        // toSshError never re-wraps.
        #expect(toSshError(hostless, host: "nimbus").info.host == nil)
    }

    @Test("kind raw values are the TypeScript union members")
    func rawValues() {
        #expect(
            SshErrorKind.allCases.map(\.rawValue) == [
                "auth", "host-key", "unknown-host", "host-not-in-config", "refused", "timeout",
                "network", "remote-cmd", "unknown",
            ]
        )
    }

    @Test("SshErrorInfo round-trips through JSON with the TS field names")
    func codable() throws {
        let info = SshErrorInfo(kind: .auth, host: "phoenix", title: "t", message: "m", hint: "h", raw: "r")
        let data = try JSONEncoder().encode(info)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["kind"] as? String == "auth")
        #expect(try JSONDecoder().decode(SshErrorInfo.self, from: data) == info)
    }
}
