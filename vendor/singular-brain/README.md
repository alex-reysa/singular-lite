# singular-brain

A portable, zero-dependency generator for **routing manifests over durable
knowledge artifacts** — one entry per artifact carrying a one-line
`description` and `load-when` triggers, so an agent knows *what durable
knowledge exists and when it is relevant* without paying to search for it.

It is the progressive-disclosure pattern (compact always-loaded metadata →
bodies pulled on trigger), applied to a project's own knowledge corpus:
durable docs, session handoffs, decision logs, agent skill packs, and any
other markdown-shaped understanding.

## Not a brain — a projection of one

The anti-pattern this tool is named against is a *central mutable brain*: an
opaque store that agents write to silently and downstream work trusts as
canonical. singular-brain is the inverse. Every manifest is a **rebuildable
projection** — a pure function of the artifacts' own metadata, regenerated
and never hand-edited. Delete a manifest and you lose nothing; regenerate it
and you get the same bytes back. Routing metadata lives on the source
artifacts (frontmatter); the manifest only transcribes.

The one exception is the freshness sidecar: it is not a projection but a small
committed **ledger** — a function of file contents *and its own prior value* —
that records each entry's last-verified state. Delete it and that state is
lost, which is why the engine refuses to regenerate over a missing sidecar and
`bless --all` is the explicit override.

## What it produces, per scope

- a **markdown manifest** (`REGISTRY.md`-style) for humans and agents;
- optionally a **JSON manifest** — the same entries as machine-readable data,
  the ingestion bridge for a platform that consumes the registry
  programmatically;
- optionally a **freshness sidecar** (see Two-hash freshness) when the scope
  opts into drift detection.

## Quickstart

```sh
# From a repo containing singular-brain.config.json:
node <engine>/cli.mjs gen        # regenerate every scope's manifest(s)
node <engine>/cli.mjs check      # exit 1 if any manifest/sidecar is stale
node <engine>/cli.mjs lint       # frontmatter schema check
node <engine>/cli.mjs bless P    # re-verify a drifted entry after review
```

Config discovery walks upward from the cwd for `singular-brain.config.json`,
or pass `--config <path>`. Narrow to one scope with `--scope <name>`.

Exit codes: `0` ok · `1` stale or lint errors · `2` config/parse/unmapped
error.

## Scopes

A **scope** is one manifest over one corpus. A config declares N scopes; each
has its own base directory, folder taxonomy, output file(s), token budget,
and freshness policy. Two scopes over the same repo is the common shape: a
`docs` scope over the canonical docs tree, and a `knowledge` scope over
handoffs, decision logs, and skill packs that live outside it.

Scopes are `exhaustive` (every `.md` under the base must be claimed or
excluded — new paths fail the build until mapped, so coverage is a decision,
not an accident) or non-exhaustive (walk only declared folders; nothing is
ever unmapped — for corpora that are islands inside a larger tree).

## Two-hash freshness

The failure mode of any hand-written routing description is silent semantic
drift: the body changes, the description no longer reflects it, and no test
fails. singular-brain closes this with two hashes per entry, stored in a
committed sidecar:

- **meta** — the routing metadata a reader relies on (`description` +
  `load-when`);
- **body** — the artifact content that metadata describes.

When a body changes but its routing metadata does not, the entry is flagged
`description_unverified` in the manifest until a human re-reviews and either
edits the description (which auto-clears the flag, because touching the
routing metadata *is* the re-review) or runs `bless` to affirm the existing
description still holds. This is a **review ratchet**, not a correctness
oracle: the flag means the body *changed* since the description was last
affirmed, not that the description is *wrong* — it is a demand for human
re-review, and its value depends on blessing honestly. Freshness is per-scope
opt-in. See `docs/spec.md` for the full state machine and its known limits.

## Adopting it in a repo

singular-brain is designed to be **vendored**: copy `engine/` into the
consumer repo (e.g. `scripts/singular-brain/engine/`), commit a
`singular-brain.config.json`, and wire `gen`/`check` into the build. No
install step, no global state, no network — `check` runs anywhere Node runs.
The engine stays generic; every project-specific fact lives in the config.
`tests/test-engine-clean.sh` enforces that separation: no consumer domain
token may appear in `engine/` or `templates/`.

## Layout

```
VERSION SCHEMA_VERSION      engine + config-schema versions
engine/                     the portable core (zero deps, Node builtins only)
  cli.mjs                   command dispatch
  config.mjs                load + validate singular-brain.config.json
  walk.mjs                  deterministic discovery + folder claiming
  frontmatter.mjs           strict minimal-YAML parser
  adapters/                 markdown-doc (default) + claude-skill
  hash.mjs freshness.mjs    two-hash freshness
  render/                   markdown + json manifests
  gates.mjs                 check / lint / token budget
templates/                  starter config
migrations/                 config-schema migration chain
docs/spec.md                the normative spec: frontmatter, tiers, freshness
tests/                      node --test suite + abstraction gate
```

## Provenance

Extracted from the docs-registry generator that PM-GO/Singular dogfooded, and
generalized into a portable engine — the same extraction pattern as the
orchestration engine. Its rendering is a behavior-identical superset of that
generator; the additions are per-repo config, multi-scope, the `claude-skill`
adapter, two-hash freshness, and the JSON manifest.
