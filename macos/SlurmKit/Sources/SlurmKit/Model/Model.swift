/// Umbrella namespace for the SlurmKit domain models.
///
/// The concrete types live alongside this file as top-level `public` values so they read
/// naturally at the call site (`Job`, `SlurmNode`, …) rather than as `Model.Job`. They mirror
/// the TypeScript extension's shapes one-for-one — field names included, since the golden
/// fixtures exported from `src/lib/*.ts` are decoded straight into them.
///
/// See macos/docs/ARCHITECTURE.md § "Repository layout".
public enum Model {

    /// Every model type declared here, by name. Kept as documentation and as the thing the
    /// scaffold test can point at; it carries no behaviour.
    public static let types: [String] = [
        "Job", "SlurmNode", "JobDetail", "QueueEntry", "RunningEntry", "PartitionActivity",
        "NodeJob", "MetricSample", "GpuSample", "MetricStreamResult", "GpuInfo",
        "JobStateCategory", "NodeStateCategory",
    ]
}
