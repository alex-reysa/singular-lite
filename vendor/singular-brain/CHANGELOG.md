# Changelog

## 0.2.0

Behavior fixes from an architecture + implementation audit. No config-schema
change (`SCHEMA_VERSION` unchanged).

- Unterminated frontmatter (an opening `---` with no closing exact `---` line)
  is now a hard parse error in strict mode; the `claude-skill` adapter's
  lenient mode treats it as no frontmatter. Near-misses (`----`, trailing
  whitespace) do not close a block.
- Table entries render even when their anchor folder is `optional` and its own
  section is empty, so entries are never silently dropped — the markdown and
  JSON manifests carry the same entry set (parity).
- Config validation rejects a non-object `freshness` and a non-array `tables`
  instead of failing obscurely later.
- Missing-sidecar guard: when freshness is enabled, the sidecar is missing, and
  the manifest already exists, `gen`/`check` fail (exit 2) rather than silently
  re-verifying every entry; `bless --all --scope <name>` is the explicit escape
  hatch.
- `check` is a raw byte-compare — no line-ending or BOM normalization — so a
  CRLF-converted manifest now reads as stale.
- `excludeLocal` is claim-and-suppress in both exhaustive and non-exhaustive
  scopes: a suppressed file is never re-claimed by a later overlapping folder.
- Fixed folder claiming for `dir: "."` with `scan: recursive` (and `noEntries`)
  so it claims the entire base subtree.

## 0.1.0

Initial release.

- Multi-scope registry generator: N configured scopes, each rendering a
  markdown routing manifest (and optionally a JSON manifest) over durable
  knowledge artifacts.
- Behavior-identical port of the proven single-file docs-registry generator:
  strict minimal frontmatter parser, tier-1/tier-2/table rendering, exhaustive
  fail-closed walking, deterministic output (in-file dates only, stable sort,
  LF, single trailing newline), byte-compare check gate with first-diff-line
  reporting, chars/4 token-budget warning.
- New over the port: per-repo JSON config (zero project symbols in the
  engine), non-exhaustive scopes with per-folder `include`/`excludeLocal`
  filters, multiple roots per scope, `claude-skill` adapter (folded scalars +
  lenient parsing for externally-authored SKILL.md files), two-hash freshness
  with committed sidecar and `description_unverified` flagging, `bless`
  command, `lint` command (frontmatter schema enforcement), JSON manifest
  renderer.
- Test suite (`node --test`) + abstraction gate (banned project tokens in
  `engine/` and `templates/`).
