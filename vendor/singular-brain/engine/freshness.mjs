// freshness.mjs — two-hash freshness over tier-1 entries.
//
// Each sidecar record stores the hashes at last verification:
//   meta — routing metadata (description + load-when) the reader relies on
//   body — the artifact content that metadata describes
// State machine per entry:
//   new file                        -> clean, auto-stamp both
//   meta changed                    -> clean, restamp both (touching the
//                                      routing metadata IS the re-review)
//   meta same, body changed         -> description_unverified (record kept —
//                                      it is still the last-verified state)
//   meta same, body same            -> clean
//   blessed + body changed          -> clean, restamp body only
//   path no longer indexed          -> record pruned
// Tier-2 entries never participate: their routing line is derived from the
// body, so it cannot drift from it by construction.
//
// No timestamps anywhere — the sidecar is a pure function of file contents
// (+ the prior sidecar); bless provenance is the sidecar's git history.

import { existsSync, readFileSync } from "node:fs";
import { metaHash, bodyHash } from "./hash.mjs";

export const CLEAN = "clean";
export const DESCRIPTION_UNVERIFIED = "description_unverified";

export function loadSidecar(absPath, scopeName) {
  if (!absPath || !existsSync(absPath)) {
    return { schemaVersion: 1, scope: scopeName, entries: {} };
  }
  const parsed = JSON.parse(readFileSync(absPath, "utf8"));
  return {
    schemaVersion: parsed.schemaVersion ?? 1,
    scope: parsed.scope ?? scopeName,
    entries: parsed.entries ?? {},
  };
}

// Pure. entries: parsed adapter entries (any tier); sidecar: prior sidecar.
// Returns { states: Map(rel -> state), nextSidecar }.
export function applyFreshness(scopeName, entries, sidecar, bless = {}) {
  const { blessAll = false, blessPaths = [] } = bless;
  const blessSet = new Set(blessPaths);
  const states = new Map();
  const next = {};
  for (const e of entries) {
    if (e.tier !== 1) continue;
    const meta = metaHash(e);
    const body = bodyHash(e);
    const rec = sidecar.entries[e.rel];
    if (!rec || rec.meta !== meta) {
      next[e.rel] = { meta, body };
      states.set(e.rel, CLEAN);
      continue;
    }
    if (rec.body !== body) {
      if (blessAll || blessSet.has(e.rel)) {
        next[e.rel] = { meta, body };
        states.set(e.rel, CLEAN);
      } else {
        next[e.rel] = rec;
        states.set(e.rel, DESCRIPTION_UNVERIFIED);
      }
      continue;
    }
    next[e.rel] = rec;
    states.set(e.rel, CLEAN);
  }
  const entriesSorted = {};
  for (const k of Object.keys(next).sort()) entriesSorted[k] = next[k];
  return {
    states,
    nextSidecar: { schemaVersion: 1, scope: scopeName, entries: entriesSorted },
  };
}

export function serializeSidecar(sidecar) {
  return `${JSON.stringify(sidecar, null, 2)}\n`;
}
