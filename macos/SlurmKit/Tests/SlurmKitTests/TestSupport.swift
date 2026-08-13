import Foundation

/// Filesystem anchors shared by the SlurmKit test suite.
///
/// The golden fixtures are checked into the repository and shared with the TypeScript
/// extension, so they are *not* copied into the test bundle as SPM resources. Tests
/// reach them by navigating from `#filePath` to the repo root, which works under
/// `swift test` with Command Line Tools alone as well as inside Xcode.
/// See macos/docs/ARCHITECTURE.md § "Testing & CI".
enum TestPaths {

    /// The `raycast-slurm` checkout root.
    ///
    /// This file lives at `<repo>/macos/SlurmKit/Tests/SlurmKitTests/TestSupport.swift`,
    /// so the root is five path components up. Keep this in sync if the package moves.
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/macos/SlurmKit/Tests/SlurmKitTests
            .deletingLastPathComponent()  // …/macos/SlurmKit/Tests
            .deletingLastPathComponent()  // …/macos/SlurmKit
            .deletingLastPathComponent()  // …/macos
            .deletingLastPathComponent()  // …  (repo root)
            .standardizedFileURL
    }()

    /// `<repo>/macos` — the native app subtree.
    static var macosRoot: URL { repoRoot.appending(path: "macos", directoryHint: .isDirectory) }

    /// `<repo>/fixtures` — golden test vectors exported from the TS parsers.
    ///
    /// Created by P1a (`npm run export-fixtures`); it does not exist yet at P0, which
    /// is why the scaffold test asserts on `repoRoot` rather than on this directory.
    static var fixturesRoot: URL { repoRoot.appending(path: "fixtures", directoryHint: .isDirectory) }

    /// `<repo>/fixtures/<kind>.json` for a fixture kind such as `jobs-user` or `nodes`.
    static func fixtureURL(kind: String) -> URL {
        fixturesRoot.appending(path: "\(kind).json", directoryHint: .notDirectory)
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    static func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
