import Foundation
import Testing

@testable import SlurmKit

// Port tests for `src/lib/ssh-config.ts`. Every case builds a throwaway `~/.ssh` in a temp
// directory and points the reader at it; nothing reads the developer's real config.

@Suite("SshConfig: load states")
struct SshConfigStateTests {

    @Test("a missing config file reports .missing with its path")
    func missing() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        let config = SshConfig(directory: dir.path, homeDirectory: dir.path)

        let state = config.loadConfigState()
        #expect(state.kind == "missing")
        #expect(state.path == dir.path + "/config")
        #expect(config.listHosts().hosts.isEmpty)
    }

    @Test("an empty config file reports .empty")
    func empty() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "")

        #expect(SshConfig(directory: dir.path, homeDirectory: dir.path).loadConfigState().kind == "empty")
    }

    @Test("a whitespace-only config is .empty; a comment-only one is .ok with no hosts")
    func blankVersusComments() {
        let blank = TempDir("sshcfg")
        let commented = TempDir("sshcfg")
        defer {
            blank.cleanUp()
            commented.cleanUp()
        }
        blank.write("config", "\n   \n\t\n")
        commented.write("config", "\n# just a comment\n\n")

        // The TS gate is `!text.trim()`, so only whitespace reaches `.empty`; a comment is
        // non-blank text that parses fine and simply declares nothing.
        #expect(SshConfig(directory: blank.path, homeDirectory: blank.path).loadConfigState().kind == "empty")
        let commentedResult = SshConfig(directory: commented.path, homeDirectory: commented.path).listHosts()
        #expect(commentedResult.state.kind == "ok")
        #expect(commentedResult.hosts.isEmpty)
    }

    @Test("a keyword with no value makes the config .unreadable")
    func unreadable() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "Host alpha\n  HostName\n")

        let state = SshConfig(directory: dir.path, homeDirectory: dir.path).loadConfigState()
        #expect(state.kind == "unreadable")
        #expect(state.path == dir.path + "/config")
        if case .unreadable(_, let reason) = state {
            #expect(reason.contains("HostName"))
        } else {
            Issue.record("expected .unreadable, got \(state)")
        }
        // …and listHosts reports it rather than pretending the config is empty.
        let result = SshConfig(directory: dir.path, homeDirectory: dir.path).listHosts()
        #expect(result.hosts.isEmpty)
        #expect(result.state.kind == "unreadable")
    }

    @Test("a well-formed config reports .ok")
    func ok() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "Host alpha\n  HostName alpha.example.edu\n")

        #expect(SshConfig(directory: dir.path, homeDirectory: dir.path).loadConfigState().kind == "ok")
    }
}

@Suite("SshConfig: hosts and compute")
struct SshConfigHostsTests {

    private func config(_ text: String) -> (SshConfig, TempDir) {
        let dir = TempDir("sshcfg")
        dir.write("config", text)
        return (SshConfig(directory: dir.path, homeDirectory: dir.path), dir)
    }

    @Test("listHosts skips wildcard and negated aliases, dedupes, and sorts case-insensitively")
    func listing() {
        let (config, dir) = config(
            """
            Host *
              User fallback

            Host zulu
              HostName zulu.example.edu

            Host Alpha alpha-gpu
              HostName alpha.example.edu

            Host *.internal ?box !bastion
              HostName never.example.edu

            Host zulu
              HostName second-take.example.edu
            """
        )
        defer { dir.cleanUp() }

        let hosts = config.listHosts().hosts
        #expect(hosts.map(\.name) == ["Alpha", "alpha-gpu", "zulu"])
        // First spelling wins for a repeated alias — `compute` still merges both blocks, and the
        // *first* HostName is the one that survives.
        #expect(hosts.first { $0.name == "zulu" }?.hostName == "zulu.example.edu")
    }

    @Test("Host * defaults merge into compute")
    func wildcardDefaults() {
        let (config, dir) = config(
            """
            Host *
              User shared
              Port 2222

            Host alpha
              HostName alpha.example.edu
              User specific
            """
        )
        defer { dir.cleanUp() }

        let alpha = config.listHosts().hosts.first { $0.name == "alpha" }
        // First obtained wins, and `Host *` is written first here — so its User beats the alias
        // block's. This is exactly why ssh_config(5) tells you to put `Host *` last, and the port
        // has to reproduce it rather than "fix" it.
        #expect(alpha?.user == "shared")
        #expect(alpha?.port == "2222")
        #expect(alpha?.hostName == "alpha.example.edu")

        // Same file with the wildcard last: now the alias's own User is the first obtained one.
        let (reordered, reorderedDir) = self.config(
            """
            Host alpha
              HostName alpha.example.edu
              User specific

            Host *
              User shared
              Port 2222
            """
        )
        defer { reorderedDir.cleanUp() }
        let specific = reordered.listHosts().hosts.first { $0.name == "alpha" }
        #expect(specific?.user == "specific")
        #expect(specific?.port == "2222")
    }

    @Test("the first obtained value wins, in file order")
    func firstValueWins() {
        let (config, dir) = config(
            """
            Host *
              User from-wildcard

            Host alpha
              HostName first.example.edu
              HostName second.example.edu
              User from-alias
            """
        )
        defer { dir.cleanUp() }

        let resolved = config.resolveHost("alpha")
        #expect(resolved?.hostName == "first.example.edu")
        // `Host *` precedes the alias block, so its User is the first obtained one.
        #expect(resolved?.user == "from-wildcard")
    }

    @Test("IdentityFile accumulates across every matching block")
    func identityFileAccumulates() {
        let (config, dir) = config(
            """
            Host alpha
              HostName alpha.example.edu
              IdentityFile ~/.ssh/id_alpha
              IdentityFile ~/.ssh/id_alpha_ed25519

            Host *
              IdentityFile ~/.ssh/id_default
            """
        )
        defer { dir.cleanUp() }

        #expect(
            config.resolveHost("alpha")?.identityFile == [
                "~/.ssh/id_alpha", "~/.ssh/id_alpha_ed25519", "~/.ssh/id_default",
            ]
        )

        // No IdentityFile at all stays `nil`, not `[]` — the TS carries `undefined` there.
        let (bare, bareDir) = self.config("Host alpha\n  HostName alpha.example.edu\n")
        defer { bareDir.cleanUp() }
        #expect(bare.resolveHost("alpha")?.identityFile == nil)
    }

    @Test("a negated pattern disqualifies the whole block")
    func negation() {
        let (config, dir) = config(
            """
            Host !bastion *
              User tunnelled

            Host bastion
              HostName bastion.example.edu

            Host worker
              HostName worker.example.edu
            """
        )
        defer { dir.cleanUp() }

        #expect(config.resolveHost("bastion")?.user == nil)
        #expect(config.resolveHost("worker")?.user == "tunnelled")
    }

    @Test("Key=Value and Key = Value parse like Key Value")
    func equalsForm() {
        let (config, dir) = config(
            """
            Host=alpha
            HostName=alpha.example.edu
            User = equals-spaced
            Port=2200
            """
        )
        defer { dir.cleanUp() }

        let hosts = config.listHosts().hosts
        #expect(hosts.map(\.name) == ["alpha"])
        #expect(hosts.first?.hostName == "alpha.example.edu")
        #expect(hosts.first?.user == "equals-spaced")
        #expect(hosts.first?.port == "2200")
    }

    @Test("hostName falls back to the alias, and quoted aliases keep their spaces")
    func hostNameFallback() {
        let (config, dir) = config(
            """
            Host plain "spaced alias"
              User someone
            """
        )
        defer { dir.cleanUp() }

        let hosts = config.listHosts().hosts
        #expect(hosts.map(\.name) == ["plain", "spaced alias"])
        #expect(hosts.first { $0.name == "plain" }?.hostName == "plain")
    }

    @Test("resolveHost is nil when nothing yields a HostName")
    func resolveHostNil() {
        let (config, dir) = config("Host alpha\n  User someone\n")
        defer { dir.cleanUp() }

        #expect(config.resolveHost("alpha") == nil)
        // …while listHosts still lists it, defaulting hostName to the alias.
        #expect(config.listHosts().hosts.first?.hostName == "alpha")
    }

    @Test("Match blocks never apply")
    func matchBlocksIgnored() {
        let (config, dir) = config(
            """
            Host alpha
              HostName alpha.example.edu

            Match host alpha
              User from-match
            """
        )
        defer { dir.cleanUp() }

        #expect(config.resolveHost("alpha")?.user == nil)
        #expect(config.listHosts().hosts.map(\.name) == ["alpha"])
    }
}

@Suite("SshConfig: Include expansion")
struct SshConfigIncludeTests {

    @Test("a glob include pulls in every matching file, dotfiles included, in sorted order")
    func globInclude() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "Include conf.d/*\n\nHost root-host\n  HostName root.example.edu\n")
        dir.write("conf.d/10-alpha.conf", "Host alpha\n  HostName alpha.example.edu\n")
        dir.write("conf.d/20-beta.conf", "Host beta\n  HostName beta.example.edu\n")
        dir.write("conf.d/.hidden.conf", "Host hidden\n  HostName hidden.example.edu\n")
        dir.makeDirectory("conf.d/subdir")

        let hosts = SshConfig(directory: dir.path, homeDirectory: dir.path).listHosts().hosts
        #expect(hosts.map(\.name) == ["alpha", "beta", "hidden", "root-host"])
    }

    @Test("includes recurse, and a cycle terminates instead of looping")
    func recursionAndCycle() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "Include conf.d/first.conf\n\nHost root-host\n  HostName root.example.edu\n")
        dir.write(
            "conf.d/first.conf",
            "Include second.conf\n\nHost first\n  HostName first.example.edu\n"
        )
        // Relative include patterns resolve against the ssh dir, not against the including file.
        dir.write(
            "second.conf",
            "Include config\n\nHost second\n  HostName second.example.edu\n"
        )

        let result = SshConfig(directory: dir.path, homeDirectory: dir.path).listHosts()
        #expect(result.state.kind == "ok")
        #expect(result.hosts.map(\.name) == ["first", "root-host", "second"])
    }

    @Test("a quoted include keeps spaces in the filename, and one line may carry several patterns")
    func quotedInclude() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", #"Include "conf.d/with space.conf" conf.d/plain.conf"# + "\n")
        dir.write("conf.d/with space.conf", "Host spaced\n  HostName spaced.example.edu\n")
        dir.write("conf.d/plain.conf", "Host plain\n  HostName plain.example.edu\n")

        let hosts = SshConfig(directory: dir.path, homeDirectory: dir.path).listHosts().hosts
        #expect(hosts.map(\.name) == ["plain", "spaced"])
    }

    @Test("~ expands against the injected home directory")
    func tildeInclude() {
        let home = TempDir("fakehome")
        defer { home.cleanUp() }
        let sshDir = home.makeDirectory(".ssh")
        home.write(".ssh/config", "Include ~/elsewhere/extra.conf\n")
        home.write("elsewhere/extra.conf", "Host tilde\n  HostName tilde.example.edu\n")

        let hosts = SshConfig(directory: sshDir, homeDirectory: home.path).listHosts().hosts
        #expect(hosts.map(\.name) == ["tilde"])
    }

    @Test("an absolute include is used as-is")
    func absoluteInclude() {
        let dir = TempDir("sshcfg")
        let other = TempDir("elsewhere")
        defer {
            dir.cleanUp()
            other.cleanUp()
        }
        other.write("extra.conf", "Host absolute\n  HostName absolute.example.edu\n")
        dir.write("config", "Include \(other.path)/extra.conf\n")

        #expect(SshConfig(directory: dir.path, homeDirectory: dir.path).listHosts().hosts.map(\.name) == ["absolute"])
    }

    @Test("an include that matches nothing contributes nothing and is not an error")
    func missingInclude() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "Include conf.d/*.conf\n\nHost alpha\n  HostName alpha.example.edu\n")

        let result = SshConfig(directory: dir.path, homeDirectory: dir.path).listHosts()
        #expect(result.state.kind == "ok")
        #expect(result.hosts.map(\.name) == ["alpha"])
    }

    @Test("an include contributes its lines in place, so file order decides who wins")
    func includeOrdering() {
        let dir = TempDir("sshcfg")
        defer { dir.cleanUp() }
        dir.write("config", "Include conf.d/early.conf\n\nHost alpha\n  HostName late.example.edu\n")
        dir.write("conf.d/early.conf", "Host alpha\n  HostName early.example.edu\n")

        #expect(SshConfig(directory: dir.path, homeDirectory: dir.path).resolveHost("alpha")?.hostName == "early.example.edu")
    }
}

@Suite("SshConfig: pattern matching")
struct SshPatternTests {

    @Test(
        "OpenSSH host patterns",
        arguments: [
            ("*", "anything", true),
            ("alpha", "alpha", true),
            ("alpha", "alpha2", false),
            ("alpha*", "alpha-gpu", true),
            ("*.example.edu", "gpu.example.edu", true),
            ("*.example.edu", "example.edu", false),
            ("?box", "abox", true),
            ("?box", "aabox", false),
            ("a*c*e", "abcde", true),
            ("a*c*e", "abcd", false),
            ("Alpha", "alpha", false),
        ]
    )
    func matches(pattern: String, candidate: String, expected: Bool) {
        #expect(SshPattern.matches(pattern, candidate) == expected)
    }
}
