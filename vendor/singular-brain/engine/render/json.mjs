// render/json.mjs — the machine-facing manifest.
//
// A deterministic JSON projection of the same entries the markdown manifest
// renders, plus freshness state and the LAST-VERIFIED hashes from the
// sidecar (not live file hashes — the sidecar hash is the "last verified"
// claim, which is the semantic payload; consumers wanting the live hash can
// compute it from the file). This is the ingestion bridge for platforms that
// consume the registry programmatically.

export const MANIFEST_SCHEMA = "singular-brain.manifest.v1";

// docsWithSections: [{ doc, section }] where section is the folder dir or
// the table title. states/sidecar may be empty/null when freshness is off.
export function renderManifestJson(scope, docsWithSections, states, nextSidecar) {
  const entries = [...docsWithSections]
    .sort((a, b) => (a.doc.rel < b.doc.rel ? -1 : a.doc.rel > b.doc.rel ? 1 : 0))
    .map(({ doc, section }) => {
      const entry = {
        path: doc.rel,
        section,
        adapter: doc.adapter,
        tier: doc.tier,
        title: doc.title,
      };
      if (doc.tier === 1) {
        const f = doc.fields;
        for (const [from, to] of [
          ["type", "type"],
          ["status", "status"],
          ["ratified", "ratified"],
          ["updated", "updated"],
          ["owner", "owner"],
          ["description", "description"],
          ["load-when", "loadWhen"],
          ["relates", "relates"],
          ["note", "note"],
        ]) {
          if (f[from] !== undefined) entry[to] = f[from];
        }
      } else {
        if (doc.excerpt) entry.excerpt = doc.excerpt;
        if (doc.hint) entry.statusHint = doc.hint;
        if (doc.updated) entry.updated = doc.updated;
      }
      if (scope.freshness.enabled && doc.tier === 1) {
        const rec = nextSidecar?.entries?.[doc.rel];
        entry.freshness = {
          state: states.get(doc.rel),
          ...(rec ? { meta: rec.meta, body: rec.body } : {}),
        };
      }
      return entry;
    });

  const manifest = {
    schema: MANIFEST_SCHEMA,
    scope: scope.name,
    title: scope.title,
    entries,
  };
  return `${JSON.stringify(manifest, null, 2)}\n`;
}
