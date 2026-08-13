import Foundation

/// `Include` expansion, ported from `inlineIncludes` (`src/lib/ssh-config.ts:44`).
///
/// The npm `ssh-config` parser does not follow `Include` directives, so the extension expands them
/// by hand before parsing; this is that expander, minus `fast-glob`. Behaviours that are
/// contractual (each one is exercised by a test):
/// * recursion — an included file may itself include others;
/// * cycle safety — a `visited` set of *resolved absolute paths*, so a file already expanded
///   contributes the empty string instead of looping;
/// * an unreadable or missing include contributes the empty string rather than failing the load;
/// * `~` / `~/…` expand against the (injectable) home directory;
/// * a relative pattern resolves against the ssh directory, not the process CWD;
/// * quoted tokens keep their spaces, and several patterns may share one `Include` line;
/// * globs match dotfiles and directories are skipped (`fast-glob`'s `{ dot: true, onlyFiles: true }`).
struct SshConfigIncludes {

    let sshDirectory: String
    let homeDirectory: String
    let fileManager: FileManager

    /// Expand `path` and everything it includes into one config text.
    func expand(path: String) -> String {
        var visited: Set<String> = []
        return expand(path: path, visited: &visited)
    }

    private func expand(path: String, visited: inout Set<String>) -> String {
        let absolute = Self.resolve(path)
        if visited.contains(absolute) { return "" }
        visited.insert(absolute)

        guard let text = try? String(contentsOfFile: absolute, encoding: .utf8) else { return "" }

        var out: [String] = []
        for line in ParsedSshConfig.splitLines(text) {
            guard let match = includeLine.exec(line), let patterns = match[1] else {
                out.append(line)
                continue
            }
            for token in ParsedSshConfig.tokenize(patterns) {
                let unquoted = stripQuotes(token)
                let expanded = expandTilde(unquoted)
                let pattern = expanded.hasPrefix("/") ? expanded : Self.resolve(sshDirectory + "/" + expanded)
                for file in FileGlob.matchingFiles(pattern: pattern, fileManager: fileManager) {
                    out.append(expand(path: file, visited: &visited))
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// `/^"|"$/g` — a leading and a trailing quote, each optional.
    private func stripQuotes(_ token: String) -> String {
        var s = Substring(token)
        if s.hasPrefix("\"") { s = s.dropFirst() }
        if s.hasSuffix("\"") { s = s.dropLast() }
        return String(s)
    }

    private func expandTilde(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + "/" + String(path.dropFirst(2)) }
        return path
    }

    /// `path.resolve` — absolute and normalised (`.`/`..` collapsed), without resolving symlinks.
    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
    }
}

// `/^\s*Include\s+(.+?)\s*$/i`, applied per line — `$` is JS end-of-input, hence `\z`.
private let includeLine = Pattern(#"^\s*Include\s+(.+?)\s*\z"#, caseInsensitive: true)

/// The `fast-glob` replacement: expand a shell pattern to the regular files it matches.
///
/// Matching is done component by component with `fnmatch(3)` (flags `0`, so a leading `.` *is*
/// matched by a wildcard — `fast-glob`'s `dot: true`). Results are sorted, which `glob(3)` does
/// and `fast-glob` does not promise; determinism matters because include order decides which
/// duplicate keyword wins.
///
/// `**` is not treated as a recursive globstar: it behaves as an ordinary wildcard inside its own
/// path component. OpenSSH itself does not document globstar support for `Include`.
enum FileGlob {

    static func matchingFiles(pattern: String, fileManager: FileManager = .default) -> [String] {
        var candidates = [pattern.hasPrefix("/") ? "/" : "."]
        for component in pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if hasMagic(component) {
                var next: [String] = []
                for directory in candidates {
                    let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
                    for entry in entries.sorted() where fnmatch(component, entry, 0) == 0 {
                        next.append(join(directory, entry))
                    }
                }
                candidates = next
            } else {
                candidates = candidates.map { join($0, component) }
            }
            if candidates.isEmpty { return [] }
        }
        return candidates.filter { isRegularFile($0, fileManager: fileManager) }.sorted()
    }

    private static func hasMagic(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }

    private static func join(_ directory: String, _ entry: String) -> String {
        directory.hasSuffix("/") ? directory + entry : directory + "/" + entry
    }

    /// `onlyFiles: true` — symlinks are followed (`fast-glob`'s default), directories dropped.
    private static func isRegularFile(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
