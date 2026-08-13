import Foundation

/// Reader for `~/.ssh/config`. Port of `src/lib/ssh-config.ts`.
///
/// The config file is **read-only** to SlurmBar — it is never rewritten. The ssh directory and the
/// home directory used for `~` expansion are injected so tests (and, later, a preference) can point
/// the reader at a temp dir; the defaults are the real ones.
///
/// Active-host persistence (`getActiveHosts` and its legacy migration) is deliberately not ported:
/// the app keeps its own `UserDefaults` store (ARCHITECTURE.md § App design), so the Raycast
/// extension's `LocalStorage` state stays untouched.
public struct SshConfig: Sendable {

    /// The tagged load state the cluster picker renders. Each case carries the path so the UI can
    /// name the file it is complaining about.
    public enum ConfigState: Sendable {
        case ok(ParsedSshConfig)
        case missing(path: String)
        case empty(path: String)
        case unreadable(path: String, reason: String)
    }

    public struct ListHostsResult: Sendable {
        public let hosts: [SshHost]
        public let state: ConfigState

        public init(hosts: [SshHost], state: ConfigState) {
            self.hosts = hosts
            self.state = state
        }
    }

    /// `~/.ssh` unless injected.
    public let directory: String

    /// Used for `~`/`~/…` inside `Include` patterns. Injected so a test can fake `$HOME`.
    public let homeDirectory: String

    /// `FileManager` is not `Sendable`, so the reader holds none: every call uses
    /// `FileManager.default`, whose file-existence and directory-listing operations are
    /// thread-safe. Injection happens at the *path* level instead, which is all the tests need.
    private var fileManager: FileManager { .default }

    public init(directory: String? = nil, homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        self.directory = directory ?? (homeDirectory + "/.ssh")
    }

    /// `~/.ssh/config`.
    public var configPath: String { directory + "/config" }

    // MARK: - Loading

    public func loadConfigState() -> ConfigState {
        guard fileManager.fileExists(atPath: configPath) else {
            return .missing(path: configPath)
        }
        let includes = SshConfigIncludes(
            sshDirectory: directory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        // Mirrors `readMaybe`: a config that exists but cannot be read yields the empty string and
        // therefore reports `empty`, not `unreadable`. `unreadable` is reserved for text that fails
        // to parse — the same split the TS ends up with, now that `fast-glob`'s throw is gone.
        let text = includes.expand(path: configPath)
        if JS.trim(text).isEmpty { return .empty(path: configPath) }
        do {
            return .ok(try ParsedSshConfig.parse(text))
        } catch {
            return .unreadable(path: configPath, reason: String(describing: error))
        }
    }

    /// Every concrete alias, resolved through `compute`.
    ///
    /// Wildcard and negated aliases (`*`, `?`, `!`) are skipped — they are defaults, not something
    /// the user can connect to — and the first spelling of a repeated alias wins. Sorted
    /// case-insensitively by name, stably, so aliases that compare equal keep file order.
    public func listHosts() -> ListHostsResult {
        let state = loadConfigState()
        guard case .ok(let config) = state else { return ListHostsResult(hosts: [], state: state) }

        var seen: Set<String> = []
        var hosts: [SshHost] = []
        for alias in config.declaredAliases {
            if alias.contains("*") || alias.contains("?") || alias.contains("!") { continue }
            if seen.contains(alias) { continue }
            seen.insert(alias)

            let resolved = config.compute(alias)
            hosts.append(
                SshHost(
                    name: alias,
                    hostName: resolved.hostName ?? alias,
                    user: resolved.user,
                    port: resolved.port,
                    identityFile: resolved.identityFile
                )
            )
        }
        let sorted = hosts.stableSorted {
            $0.name.compare($1.name, options: [.caseInsensitive]) == .orderedAscending
        }
        return ListHostsResult(hosts: sorted, state: state)
    }

    /// Resolve a single alias, `nil` when the config is unusable or the alias resolves to no
    /// `HostName` at all (the TS `resolveHost`).
    public func resolveHost(_ name: String) -> SshHost? {
        guard case .ok(let config) = loadConfigState() else { return nil }
        let resolved = config.compute(name)
        guard let hostName = resolved.hostName else { return nil }
        return SshHost(
            name: name,
            hostName: hostName,
            user: resolved.user,
            port: resolved.port,
            identityFile: resolved.identityFile
        )
    }
}

extension SshConfig.ConfigState: Equatable {

    public static func == (lhs: SshConfig.ConfigState, rhs: SshConfig.ConfigState) -> Bool {
        switch (lhs, rhs) {
        case (.ok(let l), .ok(let r)): return l == r
        case (.missing(let l), .missing(let r)): return l == r
        case (.empty(let l), .empty(let r)): return l == r
        case (.unreadable(let lp, let lr), .unreadable(let rp, let rr)): return lp == rp && lr == rr
        default: return false
        }
    }
}

extension SshConfig.ConfigState {

    /// `state.kind` in the TS — handy for tests and for the picker's switch.
    public var kind: String {
        switch self {
        case .ok: return "ok"
        case .missing: return "missing"
        case .empty: return "empty"
        case .unreadable: return "unreadable"
        }
    }

    /// The config path the state refers to; the empty string for `.ok`, which carries none.
    public var path: String {
        switch self {
        case .ok: return ""
        case .missing(let path), .empty(let path), .unreadable(let path, _): return path
        }
    }
}
