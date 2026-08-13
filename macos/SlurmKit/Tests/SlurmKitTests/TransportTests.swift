import Foundation
import Testing

@testable import SlurmKit

// Port tests for `src/lib/ssh.ts`, run against `StubSsh` — a shell script in a temp directory.
// Nothing here opens a network connection; the ssh binary path, the control directory, the
// environment and the `~/.ssh/config` location are all injected.

@Suite("Transport: invocation shape")
struct TransportInvocationTests {

    @Test("run() passes the extension's flags, in order, then host and command")
    func argv() async throws {
        let harness = TransportHarness(stdout: "hello\n")
        defer { harness.cleanUp() }

        let out = try await harness.transport.run(host: "cluster", command: "squeue -h")
        #expect(out == "hello\n")

        let invocations = harness.stub.invocations
        #expect(invocations.count == 1)
        #expect(
            invocations.first
                == expectedBaseOptions(controlDirectory: harness.controlDir.path + "/sockets")
                    + ["cluster", "squeue -h"]
        )
    }

    @Test("the ControlPath is <controlDir>/ssh-%C and the directory is created 0700")
    func controlPath() async throws {
        let harness = TransportHarness()
        defer { harness.cleanUp() }

        let socketDir = harness.controlDir.path + "/sockets"
        #expect(harness.transport.controlPath == socketDir + "/ssh-%C")
        #expect(!FileManager.default.fileExists(atPath: socketDir))

        _ = try await harness.transport.run(host: "cluster", command: "true")

        let attributes = try FileManager.default.attributesOfItem(atPath: socketDir)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
    }

    @Test("ControlPersist comes from the configuration, defaulting to 12h when blank")
    func controlPersist() async throws {
        let harness = TransportHarness(controlPersist: " 4h ")
        defer { harness.cleanUp() }
        _ = try await harness.transport.run(host: "cluster", command: "true")
        #expect(harness.stub.invocations.first?.contains("ControlPersist=4h") == true)

        let blank = TransportHarness(controlPersist: "   ")
        defer { blank.cleanUp() }
        _ = try await blank.transport.run(host: "cluster", command: "true")
        #expect(blank.stub.invocations.first?.contains("ControlPersist=12h") == true)
    }

    @Test("the child gets LC_ALL=C and LANG=C on top of the inherited environment")
    func locale() async throws {
        // The setlocale incident: a mangled GUI locale forwarded via SendEnv produced a remote
        // warning that masqueraded as an SshError.
        let harness = TransportHarness()
        defer { harness.cleanUp() }

        _ = try await harness.transport.run(host: "cluster", command: "true")
        #expect(harness.stub.environments.first == ["LC_ALL=C", "LANG=C", "SLURMKIT_TEST=1"])
    }

    @Test("isMasterUp probes with -O check and never gates on ~/.ssh/config")
    func masterCheck() async {
        // The gate is skipped on purpose (`-O check` is a local socket probe, and gating it made
        // the picker O(N²) in config size), so an alias that is *not* in the config still probes.
        let harness = TransportHarness(configuredHosts: [])
        defer { harness.cleanUp() }

        #expect(await harness.transport.isMasterUp(host: "not-in-config"))
        #expect(
            harness.stub.invocations.first
                == expectedBaseOptions(controlDirectory: harness.controlDir.path + "/sockets")
                    + ["-O", "check", "not-in-config"]
        )
    }

    @Test("isMasterUp is false when ssh exits non-zero")
    func masterCheckDown() async {
        let harness = TransportHarness(stderr: "Control socket connect: No such file or directory", exitCode: 255)
        defer { harness.cleanUp() }
        #expect(await harness.transport.isMasterUp(host: "cluster") == false)
    }

    @Test("openMaster runs -fN")
    func openMaster() async throws {
        let harness = TransportHarness()
        defer { harness.cleanUp() }

        try await harness.transport.openMaster(host: "cluster")
        #expect(
            harness.stub.invocations.first
                == expectedBaseOptions(controlDirectory: harness.controlDir.path + "/sockets") + ["-fN", "cluster"]
        )
    }

    @Test("closeMaster runs -O exit and swallows failure")
    func closeMaster() async {
        let harness = TransportHarness(stderr: "Control socket connect: No such file", exitCode: 255)
        defer { harness.cleanUp() }

        await harness.transport.closeMaster(host: "cluster")  // must not throw
        #expect(
            harness.stub.invocations.first
                == expectedBaseOptions(controlDirectory: harness.controlDir.path + "/sockets") + ["-O", "exit", "cluster"]
        )
    }

    @Test("the interactive fallback drops BatchMode and quotes the host")
    func interactiveCommand() {
        let harness = TransportHarness()
        defer { harness.cleanUp() }
        let socketDir = harness.controlDir.path + "/sockets"

        let command = harness.transport.interactiveOpenMasterCmd(host: "cluster")
        #expect(
            command == "ssh -o ControlMaster=auto -o ControlPath=\(socketDir)/ssh-%C -o ControlPersist=12h "
                + "-o ServerAliveInterval=30 -o ConnectTimeout=10 -fN cluster"
        )
        #expect(!command.contains("BatchMode"))
        #expect(harness.transport.interactiveOpenMasterCmd(host: "we ird").hasSuffix("-fN 'we ird'"))
    }

    @Test("demo hosts bypass the config gate and the master lifecycle")
    func demoBypass() async throws {
        let harness = TransportHarness(configuredHosts: nil, isDemoHost: { $0 == "phoenix" })
        defer { harness.cleanUp() }

        #expect(await harness.transport.isMasterUp(host: "phoenix"))
        try await harness.transport.openMaster(host: "phoenix")
        await harness.transport.closeMaster(host: "phoenix")
        #expect(harness.stub.invocations.isEmpty, "no ssh should have been spawned for a demo host")
    }
}

@Suite("Transport: failure handling")
struct TransportFailureTests {

    @Test("a non-zero exit becomes a classified SshError carrying the host")
    func classifiedFailure() async {
        let harness = TransportHarness(
            stderr: "r.shaw@cluster: Permission denied (publickey,keyboard-interactive).",
            exitCode: 255
        )
        defer { harness.cleanUp() }

        await #expect(throws: SshError.self) {
            try await harness.transport.run(host: "cluster", command: "squeue")
        }
        do {
            _ = try await harness.transport.run(host: "cluster", command: "squeue")
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .auth)
            #expect(error.isAuth)
            #expect(error.info.host == "cluster")
            #expect(error.info.raw.contains("Permission denied"))
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }

    @Test("a remote command failure keeps Slurm's own message")
    func remoteCommandFailure() async {
        let harness = TransportHarness(stderr: "slurm_load_jobs error: Invalid job id specified", exitCode: 1)
        defer { harness.cleanUp() }

        do {
            _ = try await harness.transport.run(host: "cluster", command: "scontrol show job 1")
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .remoteCmd)
            #expect(error.info.message == "slurm_load_jobs error: Invalid job id specified")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }

    @Test("stderr on a successful command is ignored")
    func stderrOnSuccess() async throws {
        let harness = TransportHarness(
            stdout: "145789|gpu|train|RUNNING\n",
            stderr: "bash: warning: setlocale: LC_ALL: cannot change locale\n"
        )
        defer { harness.cleanUp() }

        #expect(try await harness.transport.run(host: "cluster", command: "squeue") == "145789|gpu|train|RUNNING\n")
    }

    @Test("a deadline kills the process and reports .timeout")
    func timeout() async throws {
        let harness = TransportHarness(stdout: "too late\n", delaySeconds: 1.5)
        defer { harness.cleanUp() }

        let started = ContinuousClock.now
        do {
            _ = try await harness.transport.run(host: "cluster", command: "sleep", timeout: .milliseconds(200))
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .timeout)
            #expect(error.info.host == "cluster")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
        #expect(started.duration(to: .now) < .seconds(1), "run() must return on its deadline, not on the child's")

        // The stub writes `completed` only *after* its delay, so its absence past the delay proves
        // the process was killed rather than merely abandoned.
        try await Task.sleep(for: .seconds(2))
        #expect(harness.stub.didComplete == false)
    }

    @Test("breaching the output cap kills the process and reports the overflow")
    func outputCap() async {
        let harness = TransportHarness(stdout: String(repeating: "x", count: 200_000), maxOutputBytes: 4096)
        defer { harness.cleanUp() }

        do {
            _ = try await harness.transport.run(host: "cluster", command: "squeue -h")
            Issue.record("expected a throw")
        } catch let error as SshError {
            // Node's wording for `maxBuffer` exceeded, so the classifier sees what it used to.
            #expect(error.info.kind == .unknown)
            #expect(error.info.message == "stdout maxBuffer length exceeded")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }

    @Test("cancelling the task kills the process")
    func cancellation() async throws {
        let harness = TransportHarness(delaySeconds: 1.5)
        defer { harness.cleanUp() }

        let task = Task { try await harness.transport.run(host: "cluster", command: "sleep", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        try await Task.sleep(for: .seconds(2))
        #expect(harness.stub.didComplete == false)
    }
}

@Suite("Transport: the ~/.ssh/config gate")
struct TransportHostGateTests {

    @Test("a missing config file produces the 'No ~/.ssh/config' error")
    func missingConfig() async {
        let harness = TransportHarness(configuredHosts: nil)
        defer { harness.cleanUp() }

        do {
            _ = try await harness.transport.run(host: "cluster", command: "true")
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .hostNotInConfig)
            #expect(error.info.title == "No ~/.ssh/config")
            #expect(error.info.message == "Cannot connect to 'cluster' — your SSH config file is missing.")
            #expect(error.info.hint == "Create \(harness.sshDir.path)/config with at least one Host entry.")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
        #expect(harness.stub.invocations.isEmpty, "the gate must run before any ssh is spawned")
    }

    @Test("an unparsable config produces the 'Couldn't read ~/.ssh/config' error")
    func unreadableConfig() async {
        let harness = TransportHarness()
        defer { harness.cleanUp() }
        harness.sshDir.write("config", "Host cluster\n  HostName\n")

        do {
            _ = try await harness.transport.run(host: "cluster", command: "true")
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .hostNotInConfig)
            #expect(error.info.title == "Couldn't read ~/.ssh/config")
            #expect(error.info.hint == "Fix permissions or syntax in \(harness.sshDir.path)/config.")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }

    @Test("an alias with no Host entry produces the not-in-config error")
    func aliasMissing() async {
        let harness = TransportHarness(configuredHosts: ["other"])
        defer { harness.cleanUp() }

        do {
            _ = try await harness.transport.run(host: "cluster", command: "true")
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .hostNotInConfig)
            #expect(error.info.title == "Host 'cluster' is not in ~/.ssh/config")
            #expect(error.info.raw == "resolveHost('cluster') returned null")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }

    @Test("positive results are memoized, negative ones are not")
    func memoization() async throws {
        let harness = TransportHarness(configuredHosts: ["other"])
        defer { harness.cleanUp() }

        // Negative: not memoized, so fixing the config and retrying works without a restart.
        await #expect(throws: SshError.self) { try await harness.transport.run(host: "cluster", command: "true") }
        harness.writeConfig(hosts: ["other", "cluster"])
        _ = try await harness.transport.run(host: "cluster", command: "true")

        // Positive: memoized, so the config can vanish underneath us and the host still resolves.
        harness.removeConfig()
        _ = try await harness.transport.run(host: "cluster", command: "true")
        #expect(harness.stub.invocations.count == 2)
    }
}

@Suite("Transport: streaming")
struct TransportStreamTests {

    @Test("spawnStream yields the process output and finishes on a clean exit")
    func streamsChunks() async throws {
        let harness = TransportHarness(stdout: "T 1\nG 0, A100, 50, 100, 200\nC 12.5 100 200\nE\n")
        defer { harness.cleanUp() }

        var received = ""
        for try await chunk in harness.transport.spawnStream(host: "cluster", command: "metrics") {
            received += chunk
        }
        #expect(received == "T 1\nG 0, A100, 50, 100, 200\nC 12.5 100 200\nE\n")
        #expect(harness.stub.invocations.first?.suffix(2) == ["cluster", "metrics"])
    }

    @Test("spawnStream reports a non-zero exit as a classified error")
    func streamFailure() async {
        let harness = TransportHarness(stderr: "srun: error: Unable to allocate resources", exitCode: 1)
        defer { harness.cleanUp() }

        do {
            for try await _ in harness.transport.spawnStream(host: "cluster", command: "metrics") {}
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .remoteCmd)
            #expect(error.info.message == "srun: error: Unable to allocate resources")
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
    }

    @Test("spawnStream applies the config gate before spawning")
    func streamGate() async {
        let harness = TransportHarness(configuredHosts: ["other"])
        defer { harness.cleanUp() }

        do {
            for try await _ in harness.transport.spawnStream(host: "cluster", command: "metrics") {}
            Issue.record("expected a throw")
        } catch let error as SshError {
            #expect(error.info.kind == .hostNotInConfig)
        } catch {
            Issue.record("expected SshError, got \(error)")
        }
        #expect(harness.stub.invocations.isEmpty)
    }
}
