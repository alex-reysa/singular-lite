// claude-skill.mjs — adapter for vendored agent skill packs (SKILL.md).
//
// SKILL.md files are externally authored and often hash-locked, so this
// adapter must read them as-is: folded block scalars (`description: >-`) are
// supported and unparseable structures (nested maps like `metadata:`) are
// skipped leniently rather than failing the build. Routing metadata is the
// skill's own `name` + `description` — its native progressive-disclosure
// contract; no load-when is expected.

import { normalize, parseFrontmatter } from "../frontmatter.mjs";
import { deriveTitle } from "./markdown-doc.mjs";

export function parseClaudeSkill(rel, raw, warn = (msg) => process.stderr.write(msg)) {
  const lines = normalize(raw).split("\n");
  const fm = parseFrontmatter(lines, { allowFoldedScalars: true, lenient: true });
  const bodyStart = fm ? fm.bodyStart : 0;
  const fields = fm?.fields ?? {};
  const name =
    typeof fields.name === "string" && fields.name !== ""
      ? fields.name
      : deriveTitle(lines.slice(bodyStart), rel, warn);
  const entryFields = { type: "skill", status: "vendored" };
  if (typeof fields.description === "string" && fields.description !== "") {
    entryFields.description = fields.description;
  }
  return {
    rel,
    adapter: "claude-skill",
    tier: 1,
    title: name,
    fields: entryFields,
    bodyStart,
    bodyText: lines.slice(bodyStart).join("\n"),
  };
}
