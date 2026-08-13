import AppKit
import Foundation
import SlurmKit

/// Opening a real Terminal window for password / 2FA, **without** Apple Events.
///
/// The Raycast extension drives Terminal with AppleScript. Doing that from a signed `.app`
/// requires `NSAppleEventsUsageDescription` and triggers the "SlurmBar wants to control
/// Terminal" consent prompt — a permission dialog for what is, from the user's point of view,
/// just "log me in". SPEC-P3 §6 takes the other route: write the interactive `ssh` invocation
/// into a temporary executable `.command` file and hand *that* to Terminal via `NSWorkspace`,
/// which is a plain document open. No entitlement, no prompt.
///
/// The file is a genuine artifact on disk, so `cleanUpStaleScripts()` runs at launch — a crash
/// between writing and opening would otherwise leave one behind forever.
enum TerminalLauncher {

    /// Everything this app ever writes into the temp dir is prefixed like this, which is what
    /// makes stale-file cleanup safe to do by pattern.
    private static let prefix = "slurmbar-connect-"

    enum LaunchError: LocalizedError {
        case terminalNotFound
        case write(String)

        var errorDescription: String? {
            switch self {
            case .terminalNotFound: return "Terminal.app could not be located."
            case .write(let reason): return "Couldn't write the connect script: \(reason)"
            }
        }
    }

    /// Open Terminal running `command`, with a short banner naming the host.
    ///
    /// The script `exec`s nothing and does not close the window: after `ssh -fN` returns, the
    /// user should see whether it worked. `ControlPersist` keeps the master alive afterwards,
    /// which is the entire point — the app's own `BatchMode=yes` connections then reuse it.
    @discardableResult
    static func run(command: String, host: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)\(sanitized(host))-\(UUID().uuidString.prefix(8)).command")

        let script = """
            #!/bin/sh
            # Written by SlurmBar. Safe to delete.
            echo "Connecting to \(host) — authenticate here, then return to SlurmBar."
            \(command)
            status=$?
            if [ "$status" -eq 0 ]; then
              echo "Connected. You can close this window."
            else
              echo "ssh exited with status $status."
            fi
            """

        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw LaunchError.write(error.localizedDescription)
        }

        guard let terminal = terminalURL() else { throw LaunchError.terminalNotFound }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
        return url
    }

    /// Delete `.command` files this app left in the temp directory on an earlier run.
    static func cleanUpStaleScripts() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in entries where name.hasPrefix(prefix) && name.hasSuffix(".command") {
            try? FileManager.default.removeItem(at: tmp.appending(path: name))
        }
    }

    private static func terminalURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    /// The host only ever reaches the *file name* here (the command itself is built by
    /// `interactiveOpenMasterCmd`, which shell-quotes it), but a `/` in an alias would still
    /// send the write somewhere unintended.
    private static func sanitized(_ host: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(host.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
