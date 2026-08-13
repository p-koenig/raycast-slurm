import Foundation
import Observation
import SlurmKit

/// Jobs across every active cluster: the per-user list (My Jobs), the cluster-wide list
/// (All Jobs), and the cheap brief list the menubar label runs on.
///
/// Every fetch is `fetchPerCluster`-shaped, so one cluster's failure never blanks another —
/// the rule the whole multi-cluster UI rests on.
@Observable
@MainActor
final class JobsStore {

    private let transport: any SshTransport

    init(transport: any SshTransport) {
        self.transport = transport
    }

    // MARK: - State

    /// Remote account per host, from `whoami`. My Jobs is gated on this: without it there is no
    /// `-u` to pass, and All Jobs needs it only to decide `owned` per row.
    private(set) var users: [String: String] = [:]
    private(set) var userErrors: [String: SshErrorInfo] = [:]

    private(set) var mine: [ClusterResult<[Job]>] = []
    private(set) var all: [ClusterResult<[Job]>] = []

    /// What the menubar label counts. Fed by the 10 s `mine` poll while the popover is open and
    /// by the 30 s `listJobsBrief` tick while it is closed, so the label is never stale for long
    /// and never pays for the AllocTRES join it does not read.
    private(set) var label: [ClusterResult<[Job]>] = []

    private(set) var isLoadingMine = false
    private(set) var isLoadingAll = false
    private(set) var hasLoadedMine = false
    private(set) var hasLoadedAll = false

    private var hosts: [String] = []

    /// Notified with the raw per-cluster results of **every** my-jobs poll — the 10 s one while
    /// the popover is open and the 30 s label tick while it is closed. `JobNotifier` is the only
    /// subscriber (SPEC-P4); it is wired in `AppModel.start()`, so the snapshot runner, which
    /// never calls `start()`, never triggers a notification.
    ///
    /// Deliberately synchronous: the callback must finish its bookkeeping before this poll
    /// returns, or two overlapping polls could diff against the same snapshot.
    var onMyJobsPoll: (@MainActor ([ClusterResult<[Job]>]) -> Void)?

    /// My Jobs' gate (`manage-jobs.tsx:48`): at least one host, and a detected user for each.
    var ready: Bool { !hosts.isEmpty && hosts.allSatisfy { users[$0]?.isEmpty == false } }

    func setHosts(_ hosts: [String]) {
        guard hosts != self.hosts else { return }
        self.hosts = hosts
        // Drop rows for hosts that are gone so a deselected cluster disappears immediately
        // rather than lingering until the next poll lands.
        mine = mine.filter { hosts.contains($0.host) }
        all = all.filter { hosts.contains($0.host) }
        label = label.filter { hosts.contains($0.host) }
        hasLoadedMine = false
        hasLoadedAll = false
    }

    // MARK: - Derived

    var allJobsForCounts: [Job] {
        label.compactMap(\.data).flatMap { $0 }
    }

    var counts: [String: Int] { Display.countByState(allJobsForCounts) }

    var anyClusterFailing: Bool { label.contains { !$0.isOk } }

    /// Per-host set of nodes the user has RUNNING jobs on — the nodes tab's "My jobs only"
    /// filter and its yellow person marker (`node-utilization.tsx:66`).
    var myNodeSets: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for result in mine {
            guard case .ok(let host, let jobs) = result else { continue }
            var set: Set<String> = []
            for job in jobs where job.state == "RUNNING" {
                for node in Hostlist.expand(job.reasonOrNodeList) { set.insert(node) }
            }
            out[host] = set
        }
        return out
    }

    func owns(host: String, user: String?) -> Bool {
        guard let user, let me = users[host] else { return false }
        return user == me
    }

    // MARK: - Fetching

    /// `whoami` per host, 10 s deadline (`useSlurmUsers`, `session.ts:62`).
    func refreshUsers() async {
        let transport = self.transport
        let results = await fetchPerCluster(hosts: hosts) { host in
            try await SlurmClient(host: host, transport: transport).detectUser()
        }
        var users: [String: String] = [:]
        var errors: [String: SshErrorInfo] = [:]
        for result in results {
            switch result {
            case .ok(let host, let user): users[host] = user
            case .failed(let host, let error): errors[host] = error
            }
        }
        self.users = users
        self.userErrors = errors
    }

    func refreshMine() async {
        guard ready else { return }
        isLoadingMine = true
        defer {
            isLoadingMine = false
            hasLoadedMine = true
        }
        let transport = self.transport
        let users = self.users
        mine = await fetchPerCluster(hosts: hosts) { host in
            try await SlurmClient(host: host, transport: transport).listJobs(user: users[host] ?? "")
        }
        // The popover being open is exactly when the label should be freshest, and `mine` is a
        // superset of what the brief tick would have fetched.
        label = mine
        onMyJobsPoll?(mine)
    }

    /// All Jobs does **not** wait for `whoami` (`all-jobs.tsx`): the user is only needed to mark
    /// rows as owned, so the list renders while identity is still resolving.
    func refreshAll() async {
        guard !hosts.isEmpty else { return }
        isLoadingAll = true
        defer {
            isLoadingAll = false
            hasLoadedAll = true
        }
        let transport = self.transport
        all = await fetchPerCluster(hosts: hosts) { host in
            try await SlurmClient(host: host, transport: transport).listAllJobs()
        }
    }

    /// The background label tick: one `squeue`, no AllocTRES join.
    func refreshLabel() async {
        guard ready else { return }
        let transport = self.transport
        let users = self.users
        label = await fetchPerCluster(hosts: hosts) { host in
            try await SlurmClient(host: host, transport: transport).listJobsBrief(user: users[host] ?? "")
        }
        // The popover spends almost all of its life closed, so this — not `refreshMine` — is the
        // tick that actually delivers job notifications.
        onMyJobsPoll?(label)
    }

    // MARK: - Actions

    func cancel(host: String, jobId: String) async throws {
        try await SlurmClient(host: host, transport: transport).cancelJob(jobId: jobId)
    }
}

/// Nodes across every active cluster. Backs both the Nodes tab (30 s) and the Info tab, which
/// reads the same data at half the cadence (60 s) because a hardware inventory does not move.
@Observable
@MainActor
final class NodesStore {

    private let transport: any SshTransport

    init(transport: any SshTransport) {
        self.transport = transport
    }

    private(set) var results: [ClusterResult<[SlurmNode]>] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    private var hosts: [String] = []

    func setHosts(_ hosts: [String]) {
        guard hosts != self.hosts else { return }
        self.hosts = hosts
        results = results.filter { hosts.contains($0.host) }
        hasLoaded = false
    }

    func refresh() async {
        guard !hosts.isEmpty else {
            results = []
            hasLoaded = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        let transport = self.transport
        results = await fetchPerCluster(hosts: hosts) { host in
            try await SlurmClient(host: host, transport: transport).listNodes()
        }
    }

    /// One node by (host, name) — how a pushed `NodeJobs` screen keeps its header row live
    /// against the parent's polling instead of freezing a copy at push time.
    func node(host: String, name: String) -> SlurmNode? {
        for result in results where result.host == host {
            return result.data?.first { $0.name == name }
        }
        return nil
    }
}
