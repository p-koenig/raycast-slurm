// Slurm hostlist expansion: "gpu[01-02,05],cpu7" → ["gpu01", "gpu02", "gpu05", "cpu7"].
// Lives in its own module (no imports) because both the UI and demo.ts need it,
// and demo.ts can't reach slurm.ts — ssh.ts already imports demo.ts, so that
// would close a require cycle.

export function expandHostlist(hl: string): string[] {
  if (!hl) return [];
  const out: string[] = [];
  for (const piece of splitTopLevel(hl, ",")) {
    const trimmed = piece.trim();
    if (!trimmed) continue;
    const m = /^([^[]*)\[([^\]]+)\](.*)$/.exec(trimmed);
    if (!m) {
      out.push(trimmed);
      continue;
    }
    const [, prefix, ranges, suffix] = m;
    for (const r of ranges.split(",")) {
      const rm = /^(\d+)(?:-(\d+))?$/.exec(r.trim());
      if (!rm) continue;
      const start = Number(rm[1]);
      const end = rm[2] ? Number(rm[2]) : start;
      const width = rm[1].length;
      for (let i = start; i <= end; i++) {
        out.push(`${prefix}${String(i).padStart(width, "0")}${suffix}`);
      }
    }
  }
  return out;
}

// Split on `sep`, ignoring separators inside a "[...]" range group.
function splitTopLevel(s: string, sep: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "[") depth++;
    else if (c === "]") depth--;
    else if (c === sep && depth === 0) {
      out.push(s.slice(start, i));
      start = i + 1;
    }
  }
  out.push(s.slice(start));
  return out;
}
