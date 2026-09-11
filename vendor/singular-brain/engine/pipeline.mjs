// pipeline.mjs — the per-scope build: collect -> parse -> freshness -> render.
//
// Pure with respect to the filesystem inputs: (tree, committed sidecar) fully
// determine (markdown, json, next sidecar). gen and check run exactly this
// pipeline; only what happens to the result differs.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { collectScope } from "./walk.mjs";
import { parseMarkdownDoc } from "./adapters/markdown-doc.mjs";
import { parseClaudeSkill } from "./adapters/claude-skill.mjs";
import { loadSidecar, applyFreshness, serializeSidecar } from "./freshness.mjs";
import { renderScope } from "./render/markdown.mjs";
import { renderManifestJson } from "./render/json.mjs";
import { estimateTokens } from "./gates.mjs";

export class UnmappedError extends Error {}

// Sidecar gone but manifest present: regenerating would silently re-verify
// every entry (an untraceable `bless --all`). Fail closed unless the caller
// opts in via opts.allowMissingSidecar (only bless does).
export class SidecarMissingError extends Error {}

const ADAPTER_FNS = {
  "markdown-doc": parseMarkdownDoc,
  "claude-skill": parseClaudeSkill,
};

export function buildScope(scope, opts = {}) {
  const { bless = null, allowMissingSidecar = false, warn = (msg) => process.stderr.write(msg) } = opts;
  const { claimed, unmapped } = collectScope(scope);
  if (unmapped.length > 0) {
    throw new UnmappedError(
      `unmapped path(s) under ${scope.baseRel}/ — add to folders or exclude in the config (scope "${scope.name}"):\n  ${unmapped.join("\n  ")}`
    );
  }

  const sections = new Map();
  const tableDocs = scope.tables.map(() => []);
  const docsWithSections = [];
  for (const { rel, folder } of claimed) {
    const raw = readFileSync(join(scope.base, rel), "utf8");
    let doc;
    try {
      doc = ADAPTER_FNS[folder.adapter](rel, raw, warn);
    } catch (err) {
      throw new Error(`${rel}: ${err.message}`);
    }
    const tableIndex = scope.tables.findIndex((t) => t.match.test(rel));
    if (tableIndex >= 0) {
      tableDocs[tableIndex].push(doc);
      docsWithSections.push({ doc, section: scope.tables[tableIndex].title });
    } else {
      if (!sections.has(folder.dir)) sections.set(folder.dir, []);
      sections.get(folder.dir).push(doc);
      docsWithSections.push({ doc, section: folder.dir });
    }
  }

  let states = new Map();
  let nextSidecar = null;
  let sidecarText = null;
  if (scope.freshness.enabled) {
    // Missing sidecar + existing manifest = evidence wipe, not fresh adoption.
    // loadSidecar would stamp every entry clean; refuse unless bless opted in.
    if (!allowMissingSidecar && !existsSync(scope.freshness.sidecar) && existsSync(scope.output)) {
      throw new SidecarMissingError(
        `the freshness sidecar ${scope.freshness.sidecarRel} is missing but ${scope.outputRel} exists; ` +
          `regenerating would silently re-verify every entry (equivalent to bless --all); ` +
          `restore the sidecar from version control, or run \`singular-brain bless --all --scope ${scope.name}\` to explicitly re-verify`
      );
    }
    const prior = loadSidecar(scope.freshness.sidecar, scope.name);
    const allDocs = docsWithSections.map((d) => d.doc);
    ({ states, nextSidecar } = applyFreshness(scope.name, allDocs, prior, bless ?? {}));
    sidecarText = serializeSidecar(nextSidecar);
  }

  const rendered = renderScope(scope, sections, tableDocs, states);
  const renderedJson = scope.jsonOutput
    ? renderManifestJson(scope, docsWithSections, states, nextSidecar)
    : null;

  return {
    rendered,
    renderedJson,
    sidecarText,
    states,
    docsWithSections,
    tokens: estimateTokens(rendered),
  };
}
