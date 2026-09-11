# singular-brain — Audit Brief

**For:** a reviewing agent or engineer with no prior context on this work.
**Purpose of this document:** explain *why* singular-brain exists and what it is
trying to do, point you at everything you need to audit it, and frame the two
reviews we want — an **architecture / approach audit** and an **implementation /
code audit**. It deliberately does not tell you the answers. Form your own
judgment; challenge the premises. If we chose the wrong paradigm, say so.

---

## 1. What this is, in one paragraph

singular-brain generates **routing manifests over durable knowledge**. A
manifest is a Markdown (and optional JSON) index with one entry per durable
artifact — a doc, a session handoff, an agent skill — carrying a one-line
`description` and 2–4 `load-when` triggers. An agent reads the compact manifest
up front (cheap, always-loaded) and pulls the full artifact only when a trigger
matches. The manifest is **generated, never hand-edited**: a pure function of
the artifacts' own frontmatter, regenerated on demand, gated by a byte-compare
check. It is ~1,225 lines of dependency-free Node in one repo, plus a per-repo
JSON config.

## 2. The problem it targets

Two different problems get conflated in agent tooling; this tool is aimed
squarely at the second.

- **The search problem** — "given a question, find the relevant code/text."
  Grep, embeddings, symbol indexes all answer this. **Not our target.**
- **The prior-awareness problem** — "an agent is dropped into a repo. What
  durable knowledge *exists* that it doesn't yet know to look for?" You cannot
  query for a `ContextCapsule` or a superseded-but-load-bearing handoff you have
  no idea exists. The failure modes are concrete and expensive in dev
  environments: **re-derivation** (an agent rebuilds understanding that was
  already written down), **retrieval misses** (relevant prior knowledge existed
  and was never consulted), and **blind grep** (burning tokens searching for
  things whose existence is unknown).

The intended improvement: make "what durable knowledge exists and when it is
relevant" a cheap, always-present signal, so agents stop re-deriving and stop
searching blind. This is the **progressive disclosure** pattern (compact
metadata always loaded → bodies on demand), the same shape as Claude Agent
Skills and the repo's existing `docs/REGISTRY.md`.

**The core question for you: is that a real problem worth a standing artifact,
and is a generated routing manifest the right shape of solution?** Alternatives
the field uses — persistent embedding indexes, aider-style ephemeral repo maps,
pure index-free agentic search, auto-generated wikis (DeepWiki) — each answer a
different slice. We argue for a manifest that *composes* with search rather than
replacing it. Pressure-test that.

## 3. The principles it is built to honor (audit these as constraints)

These came from the consuming project's canon; the design treats them as hard
constraints. Judge whether the implementation actually upholds them.

1. **Rebuildable projection, never source truth.** Delete a manifest and you
   lose nothing; regenerate and you get the same bytes. Routing metadata lives
   on the source artifacts (frontmatter), not in the manifest. The named
   anti-pattern is a "central mutable brain" that agents write to silently and
   downstream work trusts as canonical — singular-brain is deliberately the
   inverse (hence the name).
2. **Determinism.** Output is a pure function of file contents — in-file dates
   only, never mtime, never git history — stable-sorted, LF, single trailing
   newline. This is what makes a byte-compare gate meaningful.
3. **Fail-closed coverage.** In an "exhaustive" scope, any file the config
   doesn't explicitly claim or exclude fails the build. Coverage is a decision,
   not an accident.
4. **Honest freshness.** An entry may not assert a description is current when
   the thing it describes has changed underneath it (see §5).

## 4. Where everything is (your map)

**Engine repo** (`singular-brain`, this repo) — the portable artifact:

| Path | What to look at it for |
| --- | --- |
| `engine/frontmatter.mjs` | the strict minimal-YAML parser + its two opt-in relaxations |
| `engine/walk.mjs` | discovery + folder-claiming; exhaustive vs non-exhaustive; `include`/`excludeLocal` |
| `engine/config.mjs` | config schema + validation (the largest module — most of the surface) |
| `engine/adapters/` | `markdown-doc` (tier-1/tier-2 derivation) and `claude-skill` |
| `engine/hash.mjs` + `engine/freshness.mjs` | the two-hash freshness state machine |
| `engine/render/` | `markdown.mjs` (human manifest) + `json.mjs` (machine manifest) |
| `engine/gates.mjs` | byte-compare, lint rules, token estimate |
| `engine/pipeline.mjs` + `engine/cli.mjs` | orchestration + command surface |
| `docs/spec.md` | the normative contract (frontmatter schema, tiering, scopes, freshness) |
| `tests/` | ~791 lines: `*.test.mjs` (node --test) + `test-engine-clean.sh` (abstraction gate) |

**Consumer adoption** (in the `PMGO-launch` repo) — proof it works on a real
corpus:

- `singular-brain.config.json` (repo root) — the two-scope config of record.
- `scripts/singular-brain/engine/` — the vendored copy (identical to this repo's
  `engine/`).
- `docs/REGISTRY.md` (docs scope) and `docs/KNOWLEDGE.md` + `.json` +
  `.knowledge-freshness.json` (knowledge scope) — generated outputs.
- `docs/core/doc-registry-and-frontmatter.md` — the consumer-normative spec layer.
- Commits: engine `119a1bb`; adoption `2d3e9b55`; docs `02139cdc`.

## 5. The one genuinely novel mechanism: two-hash freshness

Every hand-written routing description rots silently — the body changes, the
description no longer matches, and nothing catches it because the description
file didn't change. The proposed fix: store two hashes per entry in a committed
sidecar — the routing metadata (`description` + `load-when`) and the body it
describes. If the body changes but the metadata doesn't, flag the entry
`description_unverified` until a human re-reviews (editing the description *is*
the re-review) or `bless`es it.

**This is the mechanism most worth your skepticism.** Honest framing of what it
does and does not do:

- It detects that a body *changed*, not that a description is *wrong*. A
  cosmetic typo fix trips the flag; a subtle semantic change that makes the
  description a lie but happens to be reviewed still clears it. Is
  change-detection a useful proxy for staleness, or is it noise that trains
  people to reflexively `bless`?
- The meta-hash deliberately excludes `status`, `updated`, `relates`. Defensible
  (lifecycle churn shouldn't demand body re-review) or a hole?
- A rename is delete + add, so rename-plus-edit escapes the flag entirely
  (documented limitation). Acceptable for v1?
- It is off for the docs scope, on for the knowledge scope. Right call, or should
  the canon carry it too?

## 6. Decisions already made (audit the decisions, don't rediscover them)

We made these deliberately. Tell us where we were wrong.

- **Config is JSON with string-encoded regexes**, not executable JS — keeps
  config as inert data a future consumer (or kernel) can read without running
  it, at the cost of regex-escaping ergonomics.
- **The engine carries zero consumer tokens**, enforced by a banned-token grep
  gate (`tests/test-engine-clean.sh`). All project specifics live in the
  consumer's config. Same extraction pattern as a sibling orchestration engine.
- **Adoption is by vendoring** (copy `engine/` into the consumer), not a package
  install — so the consumer's CI is hermetic. Trade-off: resync is manual.
- **The markdown parser stays strict** (unparseable frontmatter is a build
  error); only the `claude-skill` adapter relaxes it (folded scalars, lenient
  skipping) because SKILL.md files are externally authored and hash-locked.
- **Tier-2 (frontmatter-less) entries are exempt from freshness** — their
  routing line is derived from the body, so it can't drift from it.
- **The excerpt/title derivation heuristics are frozen engine constants**, not
  config — this is what let the docs-scope output be proven byte-identical to
  the generator it replaced.

## 7. The two audits we want

### A. Architecture & approach audit

Judge the idea, not just the code. Some starting provocations (not a checklist —
go where the evidence leads):

- Is progressive-disclosure-via-generated-manifest the right paradigm for prior
  awareness, or does it lose to (a) pure agentic search, (b) an embedding index,
  (c) auto-generated wikis, (d) doing nothing? Where's the break-even corpus size?
- Does the "rebuildable projection, never source truth" stance actually hold end
  to end, or does the committed manifest + sidecar quietly become a thing people
  trust and edit?
- Is two-hash freshness a real guarantee or security theater (see §5)?
- The scope model (N manifests, exhaustive vs island-walking) — does it
  generalize, or is it overfit to this one repo's two scopes?
- The docs-vs-code boundary: the manifest indexes *understanding artifacts and
  docs, never raw code*. Is that the right line? What breaks when someone wants
  code routed?
- The JSON manifest is pitched as an ingestion bridge for a future platform
  kernel. Is that a real seam or speculative generality (YAGNI)?
- Does this measurably reduce token burn / re-derivation, and how would you prove
  it rather than assert it?

### B. Implementation & code audit

Standard correctness/quality review of ~1,225 LOC. Areas that carry the most
risk:

- **Determinism claim** — is output *actually* a pure function of file contents?
  Hunt for any ordering, locale, or environment dependence that would make the
  byte-compare gate flaky.
- **The freshness state machine** (`freshness.mjs`) — walk every transition in
  §5's table against the code. Does `bless` do exactly what it claims? Can the
  sidecar and the manifest ever disagree after a `gen`? Is `check` truly
  side-effect-free?
- **The walker / claiming logic** (`walk.mjs`) — folder precedence, `include`
  vs `excludeLocal` interaction, the exhaustive unmapped-path guard. Can a file
  be silently dropped? Double-counted across scopes?
- **The parser** (`frontmatter.mjs`) — the strict/lenient/folded-scalar modes.
  Adversarial frontmatter inputs. Does the "split on first `: `" rule bite?
- **Config validation** (`config.mjs`) — does every malformed config fail closed
  with a useful error, or are there inputs that pass validation and then crash or
  misbehave downstream?
- **The byte-identical port claim** — verify it yourself (commands below). If the
  new engine and the deleted generator ever diverge on the real corpus, that's a
  finding.
- **Test adequacy** — 82 cases / ~791 lines. What's *not* covered? The golden
  fixtures are self-generated then locked — is that circular, and does it matter
  given the independent byte-identical proof against the real repo?
- **Abstraction-gate integrity** — can consumer-specific logic leak into
  `engine/` in a way the banned-token grep wouldn't catch?

## 8. How to run and reproduce

```sh
# Engine repo: full suite + abstraction gate
cd singular-brain && bash tests/run-all.sh          # expect: 82 pass, gate clean

# Consumer: both manifests are current
cd PMGO-launch && node scripts/singular-brain/engine/cli.mjs check   # exit 0

# Re-prove the byte-identical port claim yourself:
#   check out the commit BEFORE the switch, run the OLD generator, save output,
#   run the new engine, diff. (Or inspect commit 2d3e9b55 — the only REGISTRY.md
#   delta at switch time was the one-line generator-name comment.)

# Exercise freshness on the real corpus (then revert):
#   append a line to a body under the knowledge scope → `check` fails →
#   `gen` surfaces the description_unverified flag → `bless` clears it.
```

## 9. Known limits we already see (not an exhaustive list — find more)

- Freshness detects change, not semantic wrongness (§5).
- Rename+edit escapes the freshness flag.
- Skill descriptions bypass lint length/trigger rules (they're upstream-owned).
- `make check` in the consumer cannot fully pass in a sandbox without a live
  Postgres (unrelated Go storage-proof tests) — the registry portion is green
  independently; don't let the red Go tests mislead you about the registry work.
- The kernel-side phases the parent proposal describes (per-Goal/role-scoped
  rendering, a retrieval ledger) are **not built** — this is only the repo-level
  slice. The JSON manifest is the intended-but-unproven bridge to them.

## 10. What a good review returns

Not a rubber stamp. We want: a verdict on whether the *approach* is sound or
should be replaced; a list of concrete correctness findings with repro; an
opinion on whether two-hash freshness earns its complexity; and a clear
statement of anything in §3's principles that the implementation violates.
Disagreement with the premise is a valid and welcome outcome.
