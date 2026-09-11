// walk.mjs — deterministic file discovery and folder claiming.
//
// Two scope modes:
//   - exhaustive: walk the scope base recursively; every .md must be excluded
//     or claimed by a folder, otherwise it is reported as unmapped (the
//     caller fails closed). This preserves the "new paths are explicit config
//     decisions" contract.
//   - non-exhaustive: walk only the declared folders (flat = direct children,
//     recursive = subtree); nothing is ever unmapped. For corpora of islands
//     inside a large tree (e.g. base = repo root).
//
// Determinism: directory entries are byte-sorted by name; claiming follows
// config folder order (first match wins).

import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

export function walkMd(absDir, relDir, recursive) {
  const out = [];
  if (!existsSync(absDir)) return out;
  for (const entry of readdirSync(absDir, { withFileTypes: true }).sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  )) {
    const rel = relDir === "." ? entry.name : `${relDir}/${entry.name}`;
    if (entry.isDirectory()) {
      if (recursive) out.push(...walkMd(join(absDir, entry.name), rel, true));
    } else if (entry.name.endsWith(".md")) {
      out.push(rel);
    }
  }
  return out;
}

function isExcluded(scope, rel) {
  return scope.exclude.some((re) => re.test(rel));
}

// Exhaustive claiming. A folder claims a file when the file sits in its dir
// (flat: direct child; recursive: anywhere below). A folder with dir "."
// spans the scope base: flat claims direct children of the base (parent dir
// "."), recursive/noEntries claim the entire subtree. `include` narrows a
// folder's claim — a dir-matching file that fails `include` falls through to
// later folders (and becomes unmapped if nothing claims it). `excludeLocal`
// claims the file but yields no entry (suppresses it without unmapped noise).
function claimingFolder(scope, rel) {
  for (const f of scope.folders) {
    if (f.noEntries) {
      if (f.dir === "." || rel === f.dir || rel.startsWith(`${f.dir}/`)) return { folder: f, entry: false };
      continue;
    }
    let dirMatch = false;
    if (f.scan === "flat") {
      const dir = rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : ".";
      dirMatch = dir === f.dir;
    } else if (f.scan === "recursive") {
      dirMatch = f.dir === "." || rel.startsWith(`${f.dir}/`);
    }
    if (!dirMatch) continue;
    if (f.include && !f.include.test(rel)) continue;
    if (f.excludeLocal.some((re) => re.test(rel))) return { folder: f, entry: false };
    return { folder: f, entry: true };
  }
  return null;
}

// Returns { claimed: [{ rel, folder }], unmapped: string[] }.
export function collectScope(scope) {
  const claimed = [];
  const unmapped = [];
  if (scope.exhaustive) {
    for (const rel of walkMd(scope.base, ".", true)) {
      if (isExcluded(scope, rel)) continue;
      const claim = claimingFolder(scope, rel);
      if (!claim) {
        unmapped.push(rel);
        continue;
      }
      if (claim.entry) claimed.push({ rel, folder: claim.folder });
    }
    return { claimed, unmapped };
  }
  const seen = new Set();
  for (const f of scope.folders) {
    if (f.noEntries) continue;
    for (const rel of walkMd(join(scope.base, f.dir), f.dir, f.scan === "recursive")) {
      if (seen.has(rel)) continue;
      if (isExcluded(scope, rel)) continue;
      if (f.include && !f.include.test(rel)) continue;
      // excludeLocal is claim-and-suppress: mark seen so a later overlapping
      // folder cannot re-claim the file (matches exhaustive-mode semantics).
      // (include-failing files intentionally fall through to later folders.)
      if (f.excludeLocal.some((re) => re.test(rel))) {
        seen.add(rel);
        continue;
      }
      seen.add(rel);
      claimed.push({ rel, folder: f });
    }
  }
  return { claimed, unmapped };
}
