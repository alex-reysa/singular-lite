// render/markdown.mjs — the human/agent-facing manifest.
//
// Rendering is a behavior-identical port of the proven docs-registry
// generator: tier-1 multi-line blocks, tier-2 one-liners, compact table
// sections, Folder Map, stable sort by path, LF, single trailing newline.
// The only addition is the freshness FLAG line on drifted tier-1 entries —
// fixed text, grep-able.

import { basename } from "node:path";
import { DESCRIPTION_UNVERIFIED } from "../freshness.mjs";

export const FLAG_LINE =
  "FLAG: description_unverified — body changed since routing metadata was last verified (re-review, then bless or edit the description).";

export function renderTier1(doc, state) {
  const f = doc.fields;
  const out = [];
  out.push(`- **\`${doc.rel}\`** — ${doc.title}`);
  const meta = [`\`${f.type ?? "?"}\``, f.status ?? "?"];
  if (f.ratified) meta.push(`ratified ${f.ratified}`);
  if (f.updated) meta.push(`updated ${f.updated}`);
  if (f.owner) meta.push(`owner: ${f.owner}`);
  out.push(`  ${meta.join(" · ")}`);
  if (f.description) out.push(`  ${f.description}`);
  const loadWhen = f["load-when"];
  if (Array.isArray(loadWhen) && loadWhen.length > 0) {
    out.push(`  Load when: ${loadWhen.join(" · ")}.`);
  }
  const tail = [];
  const relates = f.relates;
  if (Array.isArray(relates) && relates.length > 0) {
    tail.push(`Relates: ${relates.map((r) => `\`${r}\``).join(", ")}.`);
  }
  if (f.note) tail.push(`Note: ${f.note}`);
  if (tail.length > 0) out.push(`  ${tail.join(" ")}`);
  if (state === DESCRIPTION_UNVERIFIED) out.push(`  ${FLAG_LINE}`);
  return out.join("\n");
}

export function renderTier2(doc) {
  let line = `- \`${doc.rel}\` — ${doc.title}`;
  if (doc.excerpt) line += ` — ${doc.excerpt}`;
  const parenthetical = [];
  if (doc.hint) {
    parenthetical.push(
      doc.hint.ratified ? `ratified ${doc.hint.ratified}` : doc.hint.status
    );
  }
  if (doc.updated) parenthetical.push(`updated ${doc.updated}`);
  if (parenthetical.length > 0) line += ` _(${parenthetical.join(", ")})_`;
  return line;
}

export function renderTableRow(doc) {
  const status =
    doc.tier === 1
      ? doc.fields.status ?? "—"
      : doc.hint
        ? doc.hint.ratified
          ? `ratified ${doc.hint.ratified}`
          : doc.hint.status
        : "—";
  return `| \`${doc.rel}\` | ${doc.title} | ${status} |`;
}

function byRel(a, b) {
  return a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0;
}

// sections: Map(folder.dir -> doc[]); tableDocs: doc[][] parallel to
// scope.tables; states: Map(rel -> freshness state) (empty when freshness is
// off).
export function renderScope(scope, sections, tableDocs, states) {
  const out = [];
  out.push(`# ${scope.title}`);
  out.push("");
  for (const line of scope.header) out.push(line);
  out.push("");
  out.push("## Folder Map");
  out.push("");
  out.push("| Folder | Character | Purpose |");
  out.push("| --- | --- | --- |");
  for (const f of scope.folders) {
    const label =
      f.dir === "."
        ? scope.rootLabel ?? `\`${basename(scope.base)}/\` (root)`
        : `\`${f.dir}/\``;
    out.push(`| ${label} | ${f.character} | ${f.purpose} |`);
  }
  out.push("");

  for (const f of scope.folders) {
    if (f.noEntries) continue;
    const docs = (sections.get(f.dir) ?? []).sort(byRel);
    // An optional empty folder is skipped only when no table anchored to it
    // still has pending docs; otherwise those entries would vanish from the
    // manifest while remaining in the JSON manifest (coverage must not drift).
    const hasPendingTable = scope.tables.some(
      (t, i) => t.afterSection === f.dir && tableDocs[i].length > 0
    );
    if (docs.length === 0 && f.optional && !hasPendingTable) continue;
    out.push(`## ${f.title}`);
    out.push("");
    for (const doc of docs) {
      out.push(doc.tier === 1 ? renderTier1(doc, states.get(doc.rel)) : renderTier2(doc));
    }
    out.push("");
    for (let t = 0; t < scope.tables.length; t += 1) {
      const table = scope.tables[t];
      const docsForTable = tableDocs[t];
      if (table.afterSection !== f.dir || docsForTable.length === 0) continue;
      out.push(`## ${table.title}`);
      out.push("");
      for (const line of table.intro) out.push(line);
      if (table.intro.length > 0) out.push("");
      out.push("| Doc | Title | Status |");
      out.push("| --- | --- | --- |");
      for (const doc of docsForTable.sort(byRel)) {
        out.push(renderTableRow(doc));
      }
      out.push("");
    }
  }

  return `${out.join("\n").replace(/\n+$/, "")}\n`;
}
