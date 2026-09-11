// gates.mjs — verification gates: byte-compare check, lint, token budget.

// Field vocabulary for lint. Generic lifecycle/type words; the claude-skill
// adapter's synthetic values are exempted at the rule level, not added here.
export const TYPE_ENUM = [
  "vision",
  "architecture",
  "spec",
  "contract",
  "decision",
  "proposal",
  "case-study",
  "runbook",
  "plan",
  "report",
  "index",
];
export const STATUS_ENUM = [
  "idea",
  "backlog",
  "queued",
  "in-progress",
  "draft",
  "ratified",
  "implemented",
  "canonical",
  "superseded",
];

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// current may be null (missing file). rendered is the freshly generated text.
export function byteCompare(current, rendered) {
  if (current === rendered) return { ok: true, firstDiffLine: null };
  let firstDiff = 1;
  if (current !== null) {
    const a = current.split("\n");
    const b = rendered.split("\n");
    while (
      firstDiff <= Math.min(a.length, b.length) &&
      a[firstDiff - 1] === b[firstDiff - 1]
    ) {
      firstDiff += 1;
    }
  }
  return { ok: false, firstDiffLine: firstDiff };
}

export function estimateTokens(rendered) {
  return Math.round(rendered.length / 4);
}

// Lint applies only to authored tier-1 markdown-doc entries: tier-2 entries
// have nothing authored to violate, and claude-skill entries are externally
// authored, hash-locked files whose description length is the upstream
// routing contract.
export function lintEntries(entries) {
  const issues = [];
  const push = (rel, level, message) => issues.push({ rel, level, message });
  for (const e of entries) {
    if (e.tier !== 1 || e.adapter !== "markdown-doc") continue;
    const f = e.fields;
    if (f.type === undefined) push(e.rel, "error", "missing required field: type");
    else if (!TYPE_ENUM.includes(f.type)) {
      push(e.rel, "error", `type ${JSON.stringify(f.type)} not in enum (${TYPE_ENUM.join("|")})`);
    }
    if (f.status === undefined) push(e.rel, "error", "missing required field: status");
    else if (!STATUS_ENUM.includes(f.status)) {
      push(e.rel, "error", `status ${JSON.stringify(f.status)} not in enum (${STATUS_ENUM.join("|")})`);
    }
    if (typeof f.description !== "string" || f.description === "") {
      push(e.rel, "error", "missing required field: description");
    } else if (f.description.length > 180) {
      push(e.rel, "warn", `description is ${f.description.length} chars (norm: <= 180)`);
    }
    if (f.updated === undefined) push(e.rel, "warn", "missing field: updated");
    else if (typeof f.updated !== "string" || !DATE_RE.test(f.updated)) {
      push(e.rel, "error", `updated must be YYYY-MM-DD, got ${JSON.stringify(f.updated)}`);
    }
    if (f.ratified !== undefined && (typeof f.ratified !== "string" || !DATE_RE.test(f.ratified))) {
      push(e.rel, "error", `ratified must be YYYY-MM-DD, got ${JSON.stringify(f.ratified)}`);
    }
    const lw = f["load-when"];
    if (!Array.isArray(lw) || lw.length === 0) {
      push(e.rel, "warn", "missing load-when triggers (tier-1 norm: 2-4)");
    } else if (lw.length < 2 || lw.length > 4) {
      push(e.rel, "warn", `load-when has ${lw.length} items (norm: 2-4)`);
    }
  }
  return issues;
}
