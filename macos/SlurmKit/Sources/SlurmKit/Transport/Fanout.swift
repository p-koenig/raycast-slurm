import Foundation

/// Per-cluster fanout. Port of `src/lib/multi.ts`.
///
/// The rule the whole multi-cluster UI rests on: **one cluster's failure never aborts another**.
/// Every view (jobs, all jobs, nodes, menu bar) renders successful clusters next to per-cluster
/// error rows, which is only possible because failures are values here, not thrown.

/// One cluster's outcome. The TS models this as a discriminated union on `ok`; an enum is the
/// same thing with the compiler checking the switch.
///
/// (ARCHITECTURE.md lists `ClusterResult` under `Model/`; it lives in `Transport/` because it is
/// inseparable from `SshErrorInfo` and because `Model/` is P1b's and read-only for this phase.)
public enum ClusterResult<Success: Sendable>: Sendable {
    case ok(host: String, data: Success)
    case failed(host: String, error: SshErrorInfo)

    public var host: String {
        switch self {
        case .ok(let host, _), .failed(let host, _): return host
        }
    }

    public var isOk: Bool {
        if case .ok = self { return true }
        return false
    }

    public var data: Success? {
        if case .ok(_, let data) = self { return data }
        return nil
    }

    public var error: SshErrorInfo? {
        if case .failed(_, let error) = self { return error }
        return nil
    }
}

extension ClusterResult: Equatable where Success: Equatable {}

/// Run `fn(host)` against every host in parallel and bucket the results per cluster.
///
/// Never throws. Failures are classified into a structured `SshErrorInfo` so the UI can render
/// kind-specific copy and actions (auth → "open in Terminal", DNS → "check your VPN", …). The
/// returned array is in **input order**, not completion order — the cluster list must not reshuffle
/// itself between polls.
public func fetchPerCluster<Success: Sendable>(
    hosts: [String],
    _ fn: @escaping @Sendable (String) async throws -> Success
) async -> [ClusterResult<Success>] {
    await withTaskGroup(of: (Int, ClusterResult<Success>).self) { group in
        for (index, host) in hosts.enumerated() {
            group.addTask {
                do {
                    return (index, .ok(host: host, data: try await fn(host)))
                } catch {
                    return (index, .failed(host: host, error: classifySshError(error, host: host)))
                }
            }
        }
        var collected: [(Int, ClusterResult<Success>)] = []
        collected.reserveCapacity(hosts.count)
        for await result in group { collected.append(result) }
        return collected.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

public func successes<Success: Sendable>(_ results: [ClusterResult<Success>]) -> [(host: String, data: Success)] {
    results.compactMap { result in
        guard case .ok(let host, let data) = result else { return nil }
        return (host: host, data: data)
    }
}

public func failures<Success: Sendable>(_ results: [ClusterResult<Success>]) -> [(host: String, error: SshErrorInfo)] {
    results.compactMap { result in
        guard case .failed(let host, let error) = result else { return nil }
        return (host: host, error: error)
    }
}
