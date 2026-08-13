import Foundation
import SlurmKit

/// Full-dataset search, ported from `src/lib/search.ts:5`.
///
/// Lowercase, split on whitespace, **AND** over every term, plain substring containment. The
/// jobs and nodes lists own their search (Raycast's built-in filtering is disabled there) so a
/// query spans the whole dataset rather than the visible rows; SPEC-P3 §3 keeps those semantics
/// even though SwiftUI has no pagination to work around.
enum Search {

    static func matches(_ haystack: String, _ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        if terms.isEmpty { return true }
        let hay = haystack.lowercased()
        return terms.allSatisfy { hay.contains($0) }
    }

    /// `jobHaystack` (`manage-jobs.tsx:171`) — the all-jobs variant adds `%u`, which is already
    /// covered because `Job.user` is `nil` on the per-user list.
    static func jobHaystack(host: String, job: Job) -> String {
        [host, job.jobId, job.partition, job.state, job.name, job.user ?? "", job.reasonOrNodeList]
            .joined(separator: " ")
    }

    /// `nodeHaystack` (`node-utilization.tsx:207`).
    static func nodeHaystack(host: String, node: SlurmNode) -> String {
        ([host, node.name, node.state] + node.partitions + [node.features]).joined(separator: " ")
    }
}

/// The cluster/partition filter shared by the jobs and nodes tabs. Port of
/// `src/lib/components/ClusterFilter.tsx`.
///
/// Selecting a cluster **drops the other clusters' rows entirely** — which is precisely why
/// every view computes its error rows from the *unfiltered* results, so a filter can never hide
/// a cluster that is failing.
enum ClusterFilter: Hashable {
    case all
    case mine
    case cluster(host: String, partition: String?)

    /// The stable string form, used as the `Picker` tag and as a `UserDefaults`-free identity.
    var id: String {
        switch self {
        case .all: return "all"
        case .mine: return "mine"
        case .cluster(let host, let partition):
            return partition.map { "cluster:\(host):\($0)" } ?? "cluster:\(host)"
        }
    }

    var host: String? {
        if case .cluster(let host, _) = self { return host }
        return nil
    }

    /// Apply to per-cluster results. `partitions` yields an item's partition(s); `isMine` powers
    /// the nodes tab's "My jobs only" mode and is absent everywhere else.
    static func apply<T: Sendable>(
        _ results: [ClusterResult<[T]>],
        filter: ClusterFilter,
        partitions: (T) -> [String],
        isMine: ((String, T) -> Bool)? = nil
    ) -> [ClusterResult<[T]>] {
        switch filter {
        case .all:
            return results
        case .mine:
            guard let isMine else { return results }
            return results.map { result in
                guard case .ok(let host, let data) = result else { return result }
                return .ok(host: host, data: data.filter { isMine(host, $0) })
            }
        case .cluster(let host, let partition):
            return results
                .filter { $0.host == host }
                .map { result in
                    guard let partition, case .ok(let h, let data) = result else { return result }
                    return .ok(host: h, data: data.filter { partitions($0).contains(partition) })
                }
        }
    }

    /// Per-cluster partition lists for the dropdown, sorted. Failing clusters still get an entry
    /// (with no partitions) so their section header appears.
    static func partitionsByCluster<T: Sendable>(
        _ results: [ClusterResult<[T]>],
        partitions: (T) -> [String]
    ) -> [(host: String, partitions: [String])] {
        results.map { result in
            guard case .ok(let host, let data) = result else { return (host: result.host, partitions: []) }
            var set: Set<String> = []
            for item in data {
                for p in partitions(item) where !p.isEmpty { set.insert(p) }
            }
            return (host: host, partitions: set.sorted())
        }
    }
}
