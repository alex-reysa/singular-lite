# Review policy

Programmable bound on how many times a logical change is reviewed, which
finding severities block acceptance, and how extra rounds are granted.

The engine module is `engine/review_policy.py`. Drive it with
`singular review-policy <verb>` (sources `lib.sh` so repo config is applied)
or `python3 engine/review_policy.py <verb>`.

## Settings

`reviewPolicy` in `singular.config.json`:

```json
{
  "version": 1,
  "maxReviewRounds": 2,
  "blockingSeverities": ["P0", "P1"],
  "requireClassification": true
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `version` | `1` | Policy schema version. |
| `maxReviewRounds` | `2` | Completed schema-valid verdicts allowed per candidate before exhaustion: the initial review plus one follow-up. High-risk tasks are capped by this too (their two-repair ceiling becomes reachable only when a project sets `3`). |
| `blockingSeverities` | `["P0","P1"]` | Severities that keep a `needs-fix` verdict blocking. |
| `requireClassification` | `true` | Missing `classifiedFindings` fail-safe: findings stay blocking. |

### Precedence

Environment overrides win over JSON; defaults last. Invalid values are a hard
error (exit 2) and are never silently defaulted.

| Env | JSON | Notes |
| --- | --- | --- |
| `SINGULAR_REVIEW_MAX_ROUNDS` | `maxReviewRounds` | Integer `>= 1`. |
| `SINGULAR_REVIEW_BLOCKING_SEVERITIES` | `blockingSeverities` | Comma list from `P0,P1,P2,P3`. |
| `SINGULAR_REVIEW_REQUIRE_CLASSIFICATION` | `requireClassification` | `0` or `1`. |

`lib.sh` also projects the JSON object to `SINGULAR_REVIEW_POLICY_JSON` so a
frozen campaign pins it. A broken policy refuses the drive before paid work.

Inspect the resolved policy with `singular review-policy effective`.

## Logical change and lanes

The logical change id is `dagNode` when non-empty, otherwise `taskId`.
Successor tasks for the same node share it. Maintenance lanes pass an explicit
id such as `maintenance:<slug>`.

Native L1 drives record `--lane native`. Maintenance and consultant lanes use
the same ledger; they are bounded by the same `maxReviewRounds` plus any
exception whose `taskId` is null or equals the current task.

## Rounds and budget

A **round** is one completed schema-valid verdict for a candidate of the
logical change. The first is `initial`; later ones are `followup`. Transport
failures and invalid verdicts never reach `record`, so they never count.
An `accepted` verdict closes that candidate; a later dispatch of the same id
starts a fresh budget. Unaccepted rounds (including historical `backfill`)
still count until acceptance.

Allowed rounds = `maxReviewRounds` + the sum of `additionalRounds` on active
(unconsumed) exceptions whose `taskId` is null or equals the current task.
`check` refuses when `used >= allowed` (exit 4).

The L1 driver also bounds product repair retries to
`min(productRepairMax, maxReviewRounds - 1)` (floor 0) so a repair cannot be
spent on a review the policy will refuse. Exhaustion is terminal:
`escalate-parked` with `terminal_authority=policy`, failure class
`review-rounds-exhausted`. It does not consume product repair budget and does
not call the decider.

## Severities

`classifiedFindings[]` items: required `id`, `severity` (`P0`..`P3`),
`summary`; optional `trigger`, `impact`, `requirement`, `location`.

| Original verdict | Classification | Effective verdict |
| --- | --- | --- |
| not `needs-fix` | unchanged | original; findings are informational |
| `needs-fix` with classified items | P0/P1 missing non-blank `trigger`+`impact`+`requirement` are downgraded to P2 (`unsupported-blocking-claim`, never silent) | `accepted` if nothing remains in `blockingSeverities` (remaining items go to the backlog); otherwise `needs-fix` |
| `needs-fix` with empty/absent `classifiedFindings` | fail-safe: every `findings[]`/`requiredFixes[]` string is `unclassified` and blocking | `needs-fix`; `unclassifiedCount` and reason `classification-missing` |

P2/P3 never block under the default `blockingSeverities`.

## Exceptions

`singular review-policy grant --logical-change ID --rounds N --reason TEXT --evidence PATH... --authority NAME [--task TASK]`

Grant refuses when:

- an active (unconsumed) exception already exists for that logical change
- `additionalRounds > maxReviewRounds`
- reason or evidence is missing

Evidence paths are hashed at grant time. A second grant before the extra
rounds are spent is refused. Historical rounds added with `backfill` count
toward `used`.

## Ledger and backlog

- Ledger: `$SINGULAR_STATE_DIR/review-policy/ledger.json`, schema
  `singular.review-policy.ledger.v1`, atomic write under `fcntl` lock file
  `ledger.lock`.
- Backlog: `$SINGULAR_STATE_DIR/review-policy/backlog.ndjson` (one JSON line
  per non-blocking item).

Statuses: `open`, `accepted`, `exhausted`.

## CLI

```text
singular review-policy effective
singular review-policy show [--logical-change ID]
singular review-policy check --logical-change ID --task TASK
singular review-policy record --logical-change ID --task TASK --run RUN \
  --attempt N --verdict PATH --head SHA [--campaign BINDING] [--lane native] \
  [--reviewer-runner NAME] [--reviewer-model M] [--reviewer-effort E] [--apply]
singular review-policy grant --logical-change ID --rounds N --reason TEXT \
  --evidence PATH... [--task TASK] --authority NAME
singular review-policy backfill --file PATH
singular review-policy backlog [--logical-change ID]
```

Exit codes: `0` ok, `2` usage/invalid config, `3` ledger/IO error, `4`
exhausted (`check` only). JSON on stdout. Never prints secrets.

`--apply` writes `<verdict>.pre-policy.json` if anything changes and sets
`verdict` to the effective verdict. The top-level `reviewPolicy` stamp is
added only to `audit-verdict.v1` documents; legacy v0 verdicts are left
without it (their schema forbids unknown members) and the round record
`review-policy-attempt-<n>.json` carries the classification instead.

## Compatibility

Old `audit-verdict.v1` documents without `classifiedFindings` or
`reviewPolicy` keep validating (`additionalProperties` remains false; the new
members are optional). Host identity binding still requires
`verdict == accepted` at acceptance edges; the host applies policy before
that read, so a P2-only `needs-fix` can become `accepted` without a second
auditor launch.
