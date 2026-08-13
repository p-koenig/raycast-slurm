import Foundation
import Testing

@testable import SlurmKit

@Suite("P0 scaffold")
struct ScaffoldTests {

    @Test("SlurmKit module builds and exposes its namespaces")
    func moduleLinks() {
        // Placeholder namespaces from ARCHITECTURE.md's source tree. P1b/P2 replace the
        // bodies; this assertion only proves the module compiles and links.
        #expect(String(describing: Model.self) == "Model")
        #expect(String(describing: Parse.self) == "Parse")
        #expect(String(describing: SshConfig.self) == "SshConfig")
        #expect(String(describing: Transport.self) == "Transport")
        #expect(String(describing: Demo.self) == "Demo")
    }

    @Test("Repo root resolves from #filePath")
    func repoRootResolves() {
        #expect(
            TestPaths.directoryExists(TestPaths.repoRoot),
            "repo root does not exist: \(TestPaths.repoRoot.path(percentEncoded: false))"
        )

        // Anchors that prove we landed on the repo root and not on some ancestor:
        // the Raycast extension manifest and this document tree.
        #expect(TestPaths.fileExists(TestPaths.repoRoot.appending(path: "package.json")))
        #expect(TestPaths.directoryExists(TestPaths.macosRoot.appending(path: "docs")))
        #expect(TestPaths.directoryExists(TestPaths.macosRoot.appending(path: "SlurmKit")))

        // fixturesRoot is derived, not asserted: P1a creates `fixtures/`.
        #expect(TestPaths.fixturesRoot.lastPathComponent == "fixtures")
        #expect(TestPaths.fixtureURL(kind: "jobs-user").lastPathComponent == "jobs-user.json")
    }
}
