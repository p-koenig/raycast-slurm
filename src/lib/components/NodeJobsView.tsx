import { useEffect, useMemo } from "react";
import { Action, ActionPanel, Color, Icon, List, useNavigation } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { listNodeJobs, type NodeJob, type SlurmNode } from "../slurm";
import { classifySshError } from "../errors";
import { ClusterAuthRow } from "./ClusterAuthRow";
import { JobDetailView } from "./JobDetailView";
import {
  fitSubtitleToRow,
  gpuCountFromTres,
  gpuLabelFromTres,
  memFromTres,
  nodeStateColor,
  nodeUtilTags,
  stateColor,
} from "../format";

// Who is on one node — pushed from the Node Utilization list. The node row you
// pressed Enter on is repeated at the top (same chips, same tint) so the numbers
// you drilled into stay on screen, and every job holding part of the node is
// listed below it with its owner. Enter on a job continues into the shared
// JobDetailView, the same way the All Jobs list does.
//
// Refreshed on the same 10 s tick as the job lists (the parent node list polls
// at 30 s — but here you're watching a single node, so match the job cadence).
export function NodeJobsView({ node, host, meUser }: { node: SlurmNode; host: string; meUser?: string }) {
  const {
    data,
    isLoading,
    error,
    revalidate: revalidateJobs,
  } = useCachedPromise((h: string, n: string) => listNodeJobs(h, n), [host, node.name], {
    keepPreviousData: true,
    // ClusterAuthRow is the error surface here (it carries the reauth action);
    // without this, useCachedPromise's default toast would also fire — once per
    // 10 s poll tick — for the same failure.
    onError: () => {},
  });

  useEffect(() => {
    const t = setInterval(() => revalidateJobs(), 10_000);
    return () => clearInterval(t);
  }, [revalidateJobs]);

  const jobs = useMemo(() => sortByFootprint(data ?? []), [data]);
  const userCount = useMemo(() => new Set(jobs.map((j) => j.user)).size, [jobs]);

  return (
    <List
      isLoading={isLoading}
      navigationTitle={`${node.name} — ${host}`}
      searchBarPlaceholder="Filter jobs on this node…"
    >
      {error ? <ClusterAuthRow host={host} info={classifySshError(error, host)} onReauth={revalidateJobs} /> : null}

      <List.Section title="Node">
        <List.Item
          title={node.name}
          subtitle={node.partitions.join(",")}
          icon={{ source: Icon.Circle, tintColor: nodeStateColor(node.state) }}
          keywords={[host, node.state, ...node.partitions, node.features]}
          accessories={nodeUtilTags(node).map((tag) => ({ tag }))}
          actions={
            <ActionPanel>
              <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={() => revalidateJobs()} />
              <ActionPanel.Section>
                <Action.CopyToClipboard title="Copy Node Name" content={node.name} />
                {node.reason ? <Action.CopyToClipboard title="Copy Reason" content={node.reason} /> : null}
              </ActionPanel.Section>
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section
        title="Running Jobs"
        subtitle={jobs.length ? `${plural(jobs.length, "job")} · ${plural(userCount, "user")}` : undefined}
      >
        {jobs.length === 0 && !isLoading && !error ? (
          <List.Item
            title="No running jobs"
            subtitle="Nothing is allocated on this node right now."
            icon={{ source: Icon.Moon, tintColor: Color.SecondaryText }}
          />
        ) : null}
        {jobs.map((job) => (
          <NodeJobRow key={job.jobId} job={job} host={host} meUser={meUser} />
        ))}
      </List.Section>
    </List>
  );
}

// Biggest consumer first: this view exists to explain the node row's "gpu 6/8"
// and CPU chips, so the jobs accounting for most of them lead.
function sortByFootprint(jobs: NodeJob[]): NodeJob[] {
  return [...jobs].sort((a, b) => {
    const gpu = gpuCountFromTres(b.tres) - gpuCountFromTres(a.tres);
    if (gpu) return gpu;
    const cpu = (Number(b.cpus) || 0) - (Number(a.cpus) || 0);
    if (cpu) return cpu;
    return a.jobId.localeCompare(b.jobId);
  });
}

function NodeJobRow({ job, host, meUser }: { job: NodeJob; host: string; meUser?: string }) {
  const { push } = useNavigation();
  const owned = !!meUser && job.user === meUser;
  const spansNodes = (Number(job.nodeCount) || 1) > 1;

  const rowTexts = [job.jobId, job.user, `${job.elapsed} / ${job.timeLimit}`, `${job.cpus} CPU`];
  const accessories: List.Item.Accessory[] = [
    // Your own jobs carry the yellow the node list uses to mark "you have jobs
    // here", so that signal survives the drill-down; everyone else stays blue.
    { tag: { value: job.user, color: owned ? Color.Yellow : Color.Blue } },
    { text: `${job.elapsed} / ${job.timeLimit}` },
    { text: `${job.cpus} CPU` },
  ];
  const mem = memFromTres(job.tres);
  if (mem) {
    accessories.push({ text: mem });
    rowTexts.push(mem);
  }
  const gpu = gpuLabelFromTres(job.tres);
  if (gpu) {
    accessories.push({ text: gpu });
    rowTexts.push(gpu);
  }
  // The figures above are the job's whole allocation, so flag the rows that
  // aren't all on this node rather than letting them read as this node's share.
  if (spansNodes) {
    const label = `${job.nodeCount} nodes`;
    accessories.push({ tag: { value: label, color: Color.SecondaryText } });
    rowTexts.push(label);
  }

  return (
    <List.Item
      title={job.jobId}
      // Same budgeting as the All Jobs rows: the name is the only element that
      // can overflow, so give it whatever width the chips leave behind.
      subtitle={fitSubtitleToRow(job.name, rowTexts)}
      keywords={[job.user, job.name, job.partition, job.jobId]}
      icon={{ source: Icon.Hammer, tintColor: stateColor("RUNNING") }}
      accessories={accessories}
      actions={
        <ActionPanel>
          <Action
            title="View Details"
            icon={Icon.Eye}
            onAction={() => push(<JobDetailView host={host} jobId={job.jobId} owned={owned} />)}
          />
          <ActionPanel.Section>
            <Action.CopyToClipboard
              title="Copy Job ID"
              content={job.jobId}
              shortcut={{ modifiers: ["cmd"], key: "." }}
            />
            <Action.CopyToClipboard title="Copy User" content={job.user} />
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}

function plural(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? "" : "s"}`;
}
