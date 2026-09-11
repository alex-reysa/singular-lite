// hash.mjs — content hashing for two-hash freshness.
//
// metaHash covers exactly the routing metadata a reader relies on to decide
// whether to load the artifact: description + load-when triggers. Lifecycle
// fields (status, updated, relates, …) are deliberately excluded — changing
// them must not demand a body re-review.
// bodyHash covers the LF-normalized, BOM-stripped content after the
// frontmatter block (the whole file when there is none).

import { createHash } from "node:crypto";

export function sha256(text) {
  return `sha256:${createHash("sha256").update(text, "utf8").digest("hex")}`;
}

export function metaHash(entry) {
  const f = entry.fields ?? {};
  const parts = [typeof f.description === "string" ? f.description : ""];
  const loadWhen = f["load-when"];
  if (Array.isArray(loadWhen)) parts.push(...loadWhen);
  return sha256(parts.join("\n"));
}

export function bodyHash(entry) {
  return sha256(entry.bodyText ?? "");
}
