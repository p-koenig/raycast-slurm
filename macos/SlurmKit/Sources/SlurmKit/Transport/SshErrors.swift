import Foundation

/// SSH failure classification, ported from `src/lib/errors.ts` (minus `showSshErrorToast`, which
/// is UI).
///
/// The point of the table is that the UI never invents copy at the call site: it switches on
/// `SshErrorKind` and renders the structured `SshErrorInfo`. When a new failure mode shows up,
/// add a kind here rather than a string somewhere else.

/// The failure taxonomy. Raw values are the exact TS union members, so an `SshErrorInfo` encoded
/// by either side decodes on the other.
public enum SshErrorKind: String, Codable, Equatable, Sendable, CaseIterable {
    case auth
    case hostKey = "host-key"
    case unknownHost = "unknown-host"
    case hostNotInConfig = "host-not-in-config"
    case refused
    case timeout
    case network
    case remoteCmd = "remote-cmd"
    case unknown
}

/// Everything the UI needs to render a failure: what happened, in the user's words, plus the raw
/// text for the "copy details" action.
public struct SshErrorInfo: Codable, Equatable, Sendable {
    public var kind: SshErrorKind
    public var host: String?
    public var title: String
    public var message: String
    public var hint: String?
    public var raw: String

    public init(
        kind: SshErrorKind,
        host: String? = nil,
        title: String,
        message: String,
        hint: String? = nil,
        raw: String
    ) {
        self.kind = kind
        self.host = host
        self.title = title
        self.message = message
        self.hint = hint
        self.raw = raw
    }
}

/// The thrown form of `SshErrorInfo`.
///
/// The TS keeps a separate `SshAuthError` subclass purely so legacy `instanceof` checks keep
/// matching; Swift has no such legacy, so there is one error type and the discriminator is
/// `info.kind` (`isAuth` spells the common check).
public struct SshError: Error, Equatable, Sendable {
    public let info: SshErrorInfo

    public init(_ info: SshErrorInfo) {
        self.info = info
    }

    public var isAuth: Bool { info.kind == .auth }
}

extension SshError: LocalizedError {
    public var errorDescription: String? { info.message }
}

/// The classifier's input: what a finished `ssh` process left behind.
///
/// The TS reads `{ stderr, message, code, signal }` off Node's `execFile` error. `code` is only
/// ever compared against the string `"ETIMEDOUT"` and `signal` against `"SIGTERM"`, so both
/// collapse into `timedOut` here; the numeric exit status is carried for diagnostics.
public struct SshFailure: Equatable, Sendable {
    public var stderr: String
    public var message: String
    public var exitCode: Int32?
    public var timedOut: Bool

    public init(stderr: String = "", message: String = "", exitCode: Int32? = nil, timedOut: Bool = false) {
        self.stderr = stderr
        self.message = message
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

// MARK: - Classification

/// Port of `classifySshError`. The pattern table, the order of the checks and every string are
/// the TypeScript's.
public func classifySshError(_ failure: SshFailure, host: String? = nil) -> SshErrorInfo {
    // `extractText` trims both sides before anything else looks at them.
    let rawStderr = JS.trim(failure.stderr)
    let message = JS.trim(failure.message)
    let stderr = stripBenign(rawStderr)
    let raw = !rawStderr.isEmpty ? rawStderr : (!message.isEmpty ? message : "Unknown error")
    let haystack = "\(stderr)\n\(message)"

    // Auth
    if authPattern.test(haystack) {
        return SshErrorInfo(
            kind: .auth,
            host: host,
            title: withHost("Authentication required", host),
            message: "SSH refused the non-interactive login (key, password, or 2FA needed).",
            hint: "Open in Terminal to authenticate, then come back.",
            raw: raw
        )
    }

    // Host key
    if hostKeyPattern.test(haystack) {
        return SshErrorInfo(
            kind: .hostKey,
            host: host,
            title: withHost("Host key changed", host),
            message: "The server's identity doesn't match ~/.ssh/known_hosts.",
            hint: host.map { "If you trust the new key, run: ssh-keygen -R \($0)" }
                ?? "If you trust the new key, run: ssh-keygen -R <host>",
            raw: raw
        )
    }

    // DNS
    if dnsPattern.test(haystack) {
        return SshErrorInfo(
            kind: .unknownHost,
            host: host,
            title: withHost("Unknown host", host),
            message: "DNS could not resolve the hostname.",
            hint: "Check HostName in ~/.ssh/config, your network, or your VPN.",
            raw: raw
        )
    }

    // Refused
    if refusedPattern.test(haystack) {
        return SshErrorInfo(
            kind: .refused,
            host: host,
            title: withHost("Connection refused", host),
            message: "The host responded but isn't accepting SSH connections.",
            hint: "Check that sshd is running on the host and the Port is correct.",
            raw: raw
        )
    }

    // Timeout (covers ETIMEDOUT, ConnectTimeout exit, and the SIGTERM we send on our own deadline)
    if timeoutPattern.test(haystack) || failure.timedOut {
        return SshErrorInfo(
            kind: .timeout,
            host: host,
            title: withHost("Connection timed out", host),
            message: "No response within the SSH connect window.",
            hint: "Check your VPN, your network, or that the host is online.",
            raw: raw
        )
    }

    // Network
    if networkPattern.test(haystack) {
        return SshErrorInfo(
            kind: .network,
            host: host,
            title: withHost("Network unreachable", host),
            message: "Your machine has no route to the host.",
            hint: "Check your network connection or VPN.",
            raw: raw
        )
    }

    // Remote command failure (squeue/scancel/scontrol etc. wrote something useful to stderr).
    if !stderr.isEmpty {
        return SshErrorInfo(
            kind: .remoteCmd,
            host: host,
            title: host.map { "\($0): command failed" } ?? "Remote command failed",
            message: firstLine(stderr),
            raw: raw
        )
    }

    return SshErrorInfo(
        kind: .unknown,
        host: host,
        title: withHost("SSH error", host),
        message: firstLine(!message.isEmpty ? message : raw),
        raw: raw
    )
}

/// Classify anything thrown. An already-classified `SshError` is only rehomed, exactly as the TS
/// does when a caller re-reports an error it caught.
public func classifySshError(_ error: any Error, host: String? = nil) -> SshErrorInfo {
    if let sshError = error as? SshError {
        var info = sshError.info
        info.host = info.host ?? host
        return info
    }
    return classifySshError(SshFailure(message: String(describing: error)), host: host)
}

/// `toSshError` — classify unless it is already an `SshError`.
public func toSshError(_ failure: SshFailure, host: String? = nil) -> SshError {
    SshError(classifySshError(failure, host: host))
}

public func toSshError(_ error: any Error, host: String? = nil) -> SshError {
    if let sshError = error as? SshError { return sshError }
    return SshError(classifySshError(error, host: host))
}

/// The alias is not in `~/.ssh/config` at all (`makeHostNotInConfigError`).
public func makeHostNotInConfigError(host: String) -> SshError {
    SshError(
        SshErrorInfo(
            kind: .hostNotInConfig,
            host: host,
            title: "Host '\(host)' is not in ~/.ssh/config",
            message: "There's no matching Host entry for this alias.",
            hint: "Add a Host entry to ~/.ssh/config or pick another host in \"Select Clusters\".",
            raw: "resolveHost('\(host)') returned null"
        )
    )
}

// MARK: - Text plumbing

/// Lines that stock SSH / remote login shells emit to stderr but that never indicate a real
/// failure.
///
/// The macOS GUI locale is the worst offender: Raycast (and any `.app`) inherits a CFLocale string
/// like `en_US@rg=…-u-ca-gregory-u-nu-latn`, Apple's stock `ssh_config` forwards it via
/// `SendEnv LANG LC_*`, and glibc greets us with `bash: warning: setlocale: LC_ALL: cannot change
/// locale (…)`. Without this filter that warning became the *message* of a genuinely-failed remote
/// command, hiding the real "Invalid job id specified". `OpenSshTransport` forces `LC_ALL=C` so it
/// should never fire, but clusters find other ways to inject it.
private let benignStderr: [Pattern] = [
    Pattern(#"warning:\s*setlocale"#, caseInsensitive: true),
    Pattern(#"cannot change locale"#, caseInsensitive: true),
    Pattern(#"^\s*Warning: Permanently added .* to the list of known hosts\.?\s*\z"#, caseInsensitive: true),
    Pattern(#"^\s*Pseudo-terminal will not be allocated"#, caseInsensitive: true),
]

func stripBenign(_ stderr: String) -> String {
    JS.trim(
        JS.split(stderr, "\n")
            .filter { line in !JS.trim(line).isEmpty && !benignStderr.contains { $0.test(line) } }
            .joined(separator: "\n")
    )
}

/// The first non-blank line, trimmed, truncated to `max` UTF-16 units with an ellipsis — JS
/// `String.length` / `slice` semantics, because that is what produced the strings the UI was
/// designed around.
func firstLine(_ s: String, max: Int = 200) -> String {
    let line = JS.split(s, "\n").first { !JS.trim($0).isEmpty }.map(JS.trim) ?? ""
    let units = Array(line.utf16)
    guard units.count > max else { return line }
    return String(decoding: units[0..<(max - 1)], as: UTF16.self) + "…"
}

private func withHost(_ s: String, _ host: String?) -> String {
    host.map { "\(s) — \($0)" } ?? s
}

private let authPattern = Pattern(
    #"Permission denied|publickey|password:|verification code|Two-factor|Could not request channel"#,
    caseInsensitive: true
)
private let hostKeyPattern = Pattern(
    #"Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED"#,
    caseInsensitive: true
)
private let dnsPattern = Pattern(
    #"Could not resolve hostname|nodename nor servname|Name or service not known|Temporary failure in name resolution"#,
    caseInsensitive: true
)
private let refusedPattern = Pattern(#"Connection refused"#, caseInsensitive: true)
private let timeoutPattern = Pattern(#"Connection timed out|Operation timed out|ETIMEDOUT"#, caseInsensitive: true)
private let networkPattern = Pattern(#"Network is unreachable|No route to host"#, caseInsensitive: true)
