# singular-brain — Specification

The normative contract for the engine: the frontmatter schema entries carry,
how they are classified and rendered, how scopes are configured, how two-hash
freshness works, and how generation is gated. A consumer repo's own spec doc
may reference this file and add project-specific conventions on top; the rules
here are what the engine enforces.

A manifest is a **generated** projection — one entry per durable artifact with
type, status, a one-line description, and load-when triggers — so agents load
the map cheaply (static context) and pull individual artifacts on demand
(dynamic context). It is never hand-edited and never source truth.

## Frontmatter Schema

Durable markdown artifacts carry a YAML frontmatter block: `---` on line 1,
fields, closing `---`. The parser is deliberately minimal; only two syntactic
forms are legal in the strict (default) mode:

```yaml
key: single-line value            # scalar — split on the FIRST ": "
key:                              # dash list
  - item one
  - item two
```

No nested maps, no multiline strings, no inline `[a, b]` arrays, no block
scalars. Colons and em-dashes inside values are safe unquoted. A line that
matches none of these forms is a hard parse error naming its line number — so
malformed frontmatter in an owned doc fails the build rather than being
silently dropped. An opening `---` that is never closed by an exact `---` line
is likewise a hard error (reported without a line number); a near-miss like
`----` or a line with trailing whitespace does not close the block.

The `claude-skill` adapter relaxes two rules for externally-authored files:
folded block scalars (`description: >-`, wrapped lines joined by spaces) are
read, and structures the minimal parser cannot represent (e.g. a nested
`metadata:` map) are skipped leniently instead of throwing. Its lenient mode
also treats an unterminated block as no frontmatter rather than an error.

### Fields

| Field | Required | Values / format |
| --- | --- | --- |
| `type` | yes | `vision` \| `architecture` \| `spec` \| `contract` \| `decision` \| `proposal` \| `case-study` \| `runbook` \| `plan` \| `report` \| `index` |
| `status` | yes | `idea` \| `backlog` \| `queued` \| `in-progress` \| `draft` \| `ratified` \| `implemented` \| `canonical` \| `superseded` |
| `ratified` | no | `YYYY-MM-DD` — set when status reaches `ratified` or later |
| `owner` | no | free text |
| `updated` | yes | `YYYY-MM-DD` |
| `description` | yes | one line, 1–2 sentences, ≤ ~180 chars |
| `load-when` | tier-1 | dash list of 2–4 trigger phrases: when an agent should load this artifact |
| `relates` | no | dash list of repo-relative paths |
| `note` | no | one line free text — ratification prose, tie-breaker caveats |

One `status` vocabulary serves both lifecycles:

```text
proposals:  idea -> backlog -> queued -> in-progress -> ratified -> implemented
canon:      draft -> canonical -> superseded
```

`lint` enforces this schema: bad `type`/`status`/date values are errors; an
over-long description or an off-count `load-when` is a warning. Tier-2 and
`claude-skill` entries are exempt (nothing authored to validate, or the
routing text is an upstream contract).

### Legacy header lines

Docs predating frontmatter used plain key-lines under the H1 (`Status:`,
`Owner:`, `Updated:`, `Depends on:`, and the bold `**Status:**` variant). When
a doc is backfilled, those lines are **removed and migrated** (`Depends on:` →
`relates:`, ratification prose → `note:`/`ratified:`). If a doc briefly carries
both, frontmatter wins. If another doc quotes a legacy status line verbatim,
keep the quoted phrase inside `note:` so the citation stays truthful.

## Tiering

| Tier | Which artifacts | Manifest entry |
| --- | --- | --- |
| 1 | Frontmattered docs; `claude-skill` packs | Full block: title, type/status/dates, description, load-when, relates/note |
| 2 | Durable docs without frontmatter | Auto-derived one-liner: H1 title + first-paragraph excerpt + legacy status hint |
| table | Files matching a scope `tables[].match` | Compact table row (Doc / Title / Status) — always, even if frontmattered |

Excerpt derivation (tier 2) starts at the first real prose paragraph after the
H1, skipping headings, lists, quotes, code fences, horizontal rules, and
`Key: value` metadata lines, and truncates at 120 chars on a word boundary.
These heuristics are fixed engine constants, not config, so output stays
identical across consumers.

Ephemeral trees never get per-entry rows. A folder marked `noEntries` (task
packets, live control state, archives) appears only as a row in the manifest's
Folder Map; the `exclude` and per-folder `excludeLocal` patterns drop
ephemeral material sitting inside otherwise-durable folders.

A compact table is anchored to a folder section via `afterSection`; it renders
even when that folder is `optional` and its own section is empty, so entries
routed into a table are never silently dropped. The markdown and JSON
manifests always carry the same entry set.

## Scopes

A **scope** is one manifest over one corpus. Config (`singular-brain.config.json`)
declares a `scopes` array; each scope has:

| Key | Meaning |
| --- | --- |
| `name` | kebab-case identifier (used by `--scope`) |
| `base` | directory the scope walks; entry paths render relative to it |
| `output` | markdown manifest path |
| `jsonOutput` | optional JSON manifest path |
| `title`, `header`, `rootLabel` | rendered manifest chrome |
| `tokenWarnThreshold` | budget above which `gen`/`check` warn (never fail) |
| `exhaustive` | true: every `.md` under `base` must be claimed/excluded or the build fails `unmapped`; false: walk only declared folders |
| `freshness` | `{ enabled, sidecar }` — see below |
| `folders` | ordered claim list; each `{ dir, title, character, purpose, scan: flat\|recursive, optional?, noEntries?, include?, adapter?, excludeLocal? }` |
| `exclude` | scope-wide path regexes applied before claiming |
| `tables` | `{ match, afterSection, title, intro }` — compact-table sub-sections |

`include` narrows a folder to matching files (others fall through, and in an
exhaustive scope become unmapped if nothing else claims them). `excludeLocal`
claims a file but emits no entry — a claim-and-suppress that holds in both
exhaustive and non-exhaustive scopes, so a suppressed file is never picked up
by a later overlapping folder. A folder with `dir: "."` claims against the
scope base: `scan: flat` takes the base's direct children, while
`scan: recursive` (or a `noEntries` folder) claims the entire base subtree.
Folder order is claim precedence and section order.

## Two-Hash Freshness

A hand-written routing `description` drifts silently: the body changes, the
description no longer matches, and no byte-compare catches it because the
description file did not change. Freshness closes this.

When `freshness.enabled`, the scope maintains a committed sidecar JSON mapping
each tier-1 entry path to two hashes at last verification:

- **meta** — sha256 of `description` + `load-when` (the routing metadata);
- **body** — sha256 of the content after the frontmatter block.

State machine, per tier-1 entry (tier-2 entries never participate — their
routing line is derived from the body, so it cannot drift from it):

| Prior record | meta | body | Result | Sidecar |
| --- | --- | --- | --- | --- |
| absent (new) | — | — | clean | stamp both |
| present | changed | any | clean — editing routing metadata *is* the re-review | restamp both |
| present | same | changed | `description_unverified` (flagged in manifest) | unchanged (still last-verified) |
| present | same | same | clean | unchanged |
| present, blessed | same | changed | clean | restamp body only |
| no longer indexed | — | — | — | pruned |

A flagged entry renders an extra grep-able line in the manifest. Clear it by
editing the description (auto-restamps) or running `bless <path>` after review.
`check` compares the manifest, the JSON manifest, and the sidecar; any drift
in any of the three is stale.

The sidecar carries no timestamps: it is a pure function of file contents, so
output is reproducible. Bless provenance is the sidecar's own git history.

**Missing-sidecar guard.** When freshness is enabled, the sidecar is missing,
but the manifest already exists, `gen` and `check` fail (exit 2) instead of
silently re-verifying every entry — regenerating over a wiped sidecar is an
untraceable `bless --all`. `bless --all --scope <name>` is the explicit path to
re-stamp, and the same command is the adoption path when first enabling
freshness on an existing manifest.

**Known limits (v1):** a rename is a delete + a new file, so a rename+body-edit
in one step escapes the flag; a cosmetic body edit (typo) flips it until
blessed. Editing any routing metadata — even a typo fix in the description —
restamps the body and clears a pending flag: the unit of review is the whole
entry, by design. Typed-diff classification (cosmetic vs. semantic) is deferred.

## Generation And Gate

```sh
singular-brain gen        # regenerate every scope's manifest(s) + sidecar(s)
singular-brain check      # byte-compare; exit 1 if any output is stale
```

Rules the engine enforces:

- **Never hand-edit a generated manifest or sidecar** — it is overwritten on
  regeneration and `check` fails when stale.
- **Determinism** — output is a pure function of file contents (in-file dates
  only; never mtime, never git history), stable-sorted, LF, single trailing
  newline.
- **Raw byte-compare** — `check` compares bytes with no line-ending or BOM
  normalization, so a CRLF-converted manifest reads as stale (and `gen` would
  rewrite it back to LF). Environment caveat: filename Unicode normalization
  differs across filesystems (macOS NFD vs Linux NFC), so a non-ASCII artifact
  filename can render different manifest bytes per OS.
- **Exhaustiveness** (exhaustive scopes) — any `.md` under `base` not covered
  by the folder config or exclude list fails with `unmapped path`. Adding a
  new folder is an explicit config decision.

## Authoring Checklist

1. Start a new durable doc with a frontmatter block (all required fields;
   write `load-when` from the reader's point of view: *when would an agent
   need this?*).
2. Place it where a scope folder claims it.
3. Run `singular-brain gen` and commit the regenerated manifest(s) with the
   doc. When editing a doc's body in a freshness-enabled scope, re-review the
   description and either update it or `bless` the entry.
