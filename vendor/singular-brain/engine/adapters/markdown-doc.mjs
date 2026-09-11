// markdown-doc.mjs — the default adapter: durable markdown docs.
//
// Docs WITH frontmatter become tier-1 entries (authored routing metadata);
// docs without become tier-2 entries (auto-derived one-liner: H1 title +
// first-paragraph excerpt + legacy status hint). The derivation heuristics
// are deliberate engine constants, not config — they are generic
// English-document heuristics, and freezing them protects byte-identical
// replication across consumers.

import { normalize, parseFrontmatter } from "../frontmatter.mjs";

const LEGACY_KEY_LINE =
  /^(?:\*\*)?(Status|Owner|Updated|Depends on):(?:\*\*)?\s*(.+?)\s*$/;

// Generic "Key: value" metadata line (Audience:, Scope:, Date:, …) — skipped
// when deriving excerpts so summaries start at real prose, not header
// metadata.
const META_KEY_LINE = /^(?:\*\*)?[A-Z][A-Za-z0-9 /&-]{1,24}:(?:\*\*)?\s/;

export function deriveTitle(lines, rel, warn) {
  for (const line of lines) {
    const m = line.match(/^#\s+(.+?)\s*$/);
    if (m) return m[1];
  }
  warn(`warn: no H1 in ${rel}; using filename\n`);
  const base = rel.slice(rel.lastIndexOf("/") + 1);
  return base.replace(/\.md$/, "");
}

function deriveLegacy(lines, bodyStart) {
  // Legacy key-lines live in the first ~15 body lines after the H1.
  const legacy = {};
  let h1Seen = false;
  let inspected = 0;
  for (let i = bodyStart; i < lines.length && inspected < 15; i += 1) {
    const line = lines[i];
    if (!h1Seen) {
      if (/^#\s+/.test(line)) h1Seen = true;
      continue;
    }
    inspected += 1;
    const m = line.match(LEGACY_KEY_LINE);
    if (m) legacy[m[1]] = m[2];
  }
  return legacy;
}

export function statusHint(rawStatus) {
  // Only recognized lifecycle words become hints; free-text status prose is
  // dropped (it survives in the doc itself and in tier-1 `note:` after
  // backfill). Keeps tier-2 lines clean and the registry lean.
  if (!rawStatus) return null;
  const ratified = rawStatus.match(/RATIFIED\s+(\d{4}-\d{2}-\d{2})/i);
  if (ratified) return { status: "ratified", ratified: ratified[1] };
  const decided = rawStatus.match(/DECIDED\s+(\d{4}-\d{2}-\d{2})/i);
  if (decided) return { status: `decided ${decided[1]}` };
  const lead = rawStatus.match(/^(canonical|draft|superseded)\b/i);
  if (lead) return { status: lead[1].toLowerCase() };
  if (/SUPERSEDED/i.test(rawStatus)) return { status: "superseded" };
  return null;
}

function deriveExcerpt(lines, bodyStart) {
  let h1Seen = false;
  const para = [];
  const limit = Math.min(lines.length, bodyStart + 40);
  for (let i = bodyStart; i < limit; i += 1) {
    const line = lines[i];
    if (!h1Seen) {
      if (/^#\s+/.test(line)) h1Seen = true;
      continue;
    }
    const skip =
      /^\s*$/.test(line) ||
      /^#{1,6}\s/.test(line) ||
      /^\s*(>|\||```|<!--|[-*]\s|\d+\.\s)/.test(line) ||
      /^\s*[-*_]{3,}\s*$/.test(line) ||
      LEGACY_KEY_LINE.test(line) ||
      META_KEY_LINE.test(line);
    if (para.length === 0) {
      if (!skip) para.push(line.trim());
    } else if (skip) {
      break;
    } else {
      para.push(line.trim());
    }
  }
  if (para.length === 0) return null;
  const text = para.join(" ");
  if (text.length <= 120) return text;
  const cut = text.slice(0, 120);
  const lastSpace = cut.lastIndexOf(" ");
  return `${cut.slice(0, lastSpace > 60 ? lastSpace : 120)}…`;
}

export function parseMarkdownDoc(rel, raw, warn = (msg) => process.stderr.write(msg)) {
  const lines = normalize(raw).split("\n");
  const fm = parseFrontmatter(lines);
  const bodyStart = fm ? fm.bodyStart : 0;
  const title = deriveTitle(lines.slice(bodyStart), rel, warn);
  const bodyText = lines.slice(bodyStart).join("\n");
  if (fm) {
    return { rel, adapter: "markdown-doc", tier: 1, title, fields: fm.fields, bodyStart, bodyText };
  }
  const legacy = deriveLegacy(lines, bodyStart);
  return {
    rel,
    adapter: "markdown-doc",
    tier: 2,
    title,
    excerpt: deriveExcerpt(lines, bodyStart),
    hint: statusHint(legacy["Status"]),
    updated: (legacy["Updated"] || "").match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? null,
    bodyStart,
    bodyText,
  };
}
