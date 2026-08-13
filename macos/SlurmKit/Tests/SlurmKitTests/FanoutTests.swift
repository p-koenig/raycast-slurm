import Foundation
import Testing

@testable import SlurmKit

// Port tests for `src/lib/multi.ts`. The invariant every multi-cluster view depends on: one
// cluster's failure never affects another, and the result order is the input order.

@Suite("Fanout: fetchPerCluster")
struct FanoutTests {

    @Test("mixed success and failure: every host reports, in input order")
    func mixed() async {
        let hosts = ["phoenix", "nimbus", "kisski", "dws"]
        let results = await fetchPerCluster(hosts: hosts) { host -> String in
            switch host {
            case "nimbus":
                throw SshError(
                    SshErrorInfo(kind: .auth, host: host, title: "Authentication required", message: "m", raw: "r")
                )
            case "kisski":
                throw toSshError(
                    SshFailure(stderr: "ssh: connect to host kisski port 22: Connection refused", exitCode: 255),
                    host: host
                )
            default:
                return "\(host)-ok"
            }
        }

        #expect(results.map(\.host) == hosts)
        #expect(results.map(\.isOk) == [true, false, false, true])
        #expect(successes(results).map(\.data) == ["phoenix-ok", "dws-ok"])
        #expect(failures(results).map(\.host) == ["nimbus", "kisski"])
        // Raw throws are classified, and the host is stamped on the way out.
        #expect(failures(results).map(\.error.kind) == [.auth, .refused])
        #expect(failures(results).allSatisfy { $0.error.host == $0.host })
    }

    @Test("order is input order even when the slow host succeeds last")
    func orderIsInputOrder() async {
        let hosts = ["slow", "fast"]
        let results = await fetchPerCluster(hosts: hosts) { host -> String in
            if host == "slow" { try await Task.sleep(for: .milliseconds(120)) }
            return host
        }
        #expect(results.map(\.host) == hosts)
        #expect(results.map(\.data) == ["slow", "fast"])
    }

    @Test("a failure never aborts the other clusters")
    func failureIsIsolated() async {
        // The point of `Promise.allSettled` in the TS: `fetchPerCluster` itself cannot throw, and
        // the healthy clusters still return their data.
        let results = await fetchPerCluster(hosts: ["broken", "healthy"]) { host -> [Job] in
            if host == "broken" { throw SshError(SshErrorInfo(kind: .timeout, title: "t", message: "m", raw: "r")) }
            return [Job(jobId: "1", partition: "gpu", name: "train", state: "RUNNING", elapsed: "1:00", timeLimit: "2:00", nodes: "1", cpus: "8", reasonOrNodeList: "gpu01", tres: "")]
        }
        #expect(results.count == 2)
        #expect(results[0].error?.kind == .timeout)
        #expect(results[1].data?.count == 1)
    }

    @Test("a non-SshError throw is classified too")
    func arbitraryErrorsAreClassified() async {
        struct Boom: Error {}
        let results = await fetchPerCluster(hosts: ["phoenix"]) { _ -> Int in throw Boom() }
        #expect(results.first?.error?.kind == .unknown)
        #expect(results.first?.error?.host == "phoenix")
    }

    @Test("no hosts is not an error")
    func emptyInput() async {
        let results = await fetchPerCluster(hosts: []) { (_: String) -> Int in 0 }
        #expect(results.isEmpty)
        #expect(successes(results).isEmpty)
        #expect(failures(results).isEmpty)
    }

    @Test("fanning out over real clients keeps per-cluster data apart")
    func overClients() async throws {
        // The shape the views actually use: one client per active cluster over a shared transport.
        let transport = DemoFixtures.transport()
        let results = await fetchPerCluster(hosts: ["phoenix", "nimbus", "not-a-cluster"]) { host in
            try await SlurmClient(host: host, transport: transport).listNodes()
        }

        #expect(results.map(\.isOk) == [true, true, false])
        let phoenix = try #require(results[0].data)
        let nimbus = try #require(results[1].data)
        #expect(phoenix.first?.name != nimbus.first?.name)
        #expect(results[2].error?.kind == .remoteCmd)
    }
}
