import Foundation

/// One concrete alias from `~/.ssh/config`, resolved through `compute`. Port of the TS `Host`
/// type (`src/lib/ssh-config.ts:13`).
///
/// NAMING: the TypeScript calls this `Host`; on macOS `Foundation` already vends a `Host` class
/// (the Swift name of `NSHost`), and every file in this package imports Foundation. Shadowing it
/// module-wide would make `Host` ambiguous for the App target, which imports SlurmKit *and*
/// Foundation/SwiftUI — so the model is spelled `SshHost` here. Fields are otherwise
/// one-for-one with the TS shape.
public struct SshHost: Codable, Equatable, Sendable {

    /// The alias as written after `Host` — what the user picks and what is passed to `ssh`.
    public var name: String

    /// `HostName`, defaulting to `name` when the block does not set one (the TS `?? alias`).
    public var hostName: String

    public var user: String?

    /// Kept as a `String` because that is what `ssh_config` holds and what the TS carries; it is
    /// never arithmetic.
    public var port: String?

    /// Every `IdentityFile` that applies to this alias, in the order OpenSSH would try them.
    /// `nil` (not `[]`) when none apply, mirroring the TS `undefined`.
    public var identityFile: [String]?

    public init(name: String, hostName: String, user: String? = nil, port: String? = nil, identityFile: [String]? = nil) {
        self.name = name
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}
