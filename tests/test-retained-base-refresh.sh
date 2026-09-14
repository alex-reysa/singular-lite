#!/usr/bin/env bash
set -euo pipefail
# A retained worker branch falls behind the target whenever the reconciler
# commits control state there; the fresh-dispatch guard then refused it forever
# ("admitted base is not an ancestor"). singular_refresh_retained_branch merges
# the base in, once, without touching owned content — via the live checkout when
# one exists, via plumbing otherwise — and refuses real conflicts.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo"
git -C "$repo" init -q; git -C "$repo" config user.name f; git -C "$repo" config user.email f@x
git -C "$repo" checkout -qb target
printf 'base\n' >"$repo/owned.txt"; printf 'ctl0\n' >"$repo/control.txt"
git -C "$repo" add .; git -C "$repo" commit -qm base
git -C "$repo" branch work
git -C "$repo" checkout -q work; printf 'candidate\n' >"$repo/owned.txt"; git -C "$repo" commit -qam candidate
cand="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target; printf 'ctl1\n' >"$repo/control.txt"; git -C "$repo" commit -qam "control-state update"
target="$(git -C "$repo" rev-parse HEAD)"
export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
source "$ROOT/engine/lib.sh" >/dev/null

# 1. Plumbing path (branch not checked out anywhere).
new="$(singular_refresh_retained_branch "$repo" work "$target")" || fail "plumbing refresh failed"
git -C "$repo" merge-base --is-ancestor "$target" "$new" || fail "target not an ancestor after refresh"
git -C "$repo" merge-base --is-ancestor "$cand" "$new" || fail "candidate lost"
[[ "$(git -C "$repo" show "$new:owned.txt")" == candidate ]] || fail "owned content altered"
[[ "$(git -C "$repo" show "$new:control.txt")" == ctl1 ]] || fail "base content missing"
[[ "$(git -C "$repo" rev-parse work)" == "$new" ]] || fail "branch ref not moved"
[[ "$(git -C "$repo" rev-parse target)" == "$target" ]] || fail "target moved"
pass "plumbing refresh merges the base under the candidate without a checkout"

# 2. Idempotent: already a descendant -> prints the head, no new commit.
again="$(singular_refresh_retained_branch "$repo" work "$target")" || fail "idempotent call failed"
[[ "$again" == "$new" ]] || fail "idempotent call created a commit"
pass "already-fresh branch is left alone"

# 3. Checkout path: branch checked out in a clean linked worktree.
git -C "$repo" checkout -q target; printf 'ctl2\n' >"$repo/control.txt"; git -C "$repo" commit -qam "control-state update 2"
target2="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" worktree add -q "$tmp/wt" work
new2="$(singular_refresh_retained_branch "$repo" work "$target2" "$tmp/wt")" || fail "checkout refresh failed"
[[ "$(git -C "$tmp/wt" rev-parse HEAD)" == "$new2" ]] || fail "worktree HEAD not advanced with the ref"
[[ -z "$(git -C "$tmp/wt" status --porcelain)" ]] || fail "worktree left dirty"
[[ "$(cat "$tmp/wt/control.txt")" == ctl2 && "$(cat "$tmp/wt/owned.txt")" == candidate ]] || fail "worktree content wrong"
pass "checkout refresh advances the live worktree together with the ref"

# 4. Dirty checkout refuses; ref untouched.
git -C "$repo" checkout -q target; printf 'ctl3\n' >"$repo/control.txt"; git -C "$repo" commit -qam "control-state update 3"
target3="$(git -C "$repo" rev-parse HEAD)"
printf 'partial\n' >>"$tmp/wt/owned.txt"
if singular_refresh_retained_branch "$repo" work "$target3" "$tmp/wt" 2>/dev/null; then fail "dirty checkout was merged"; fi
[[ "$(git -C "$repo" rev-parse work)" == "$new2" ]] || fail "ref moved despite refusal"
git -C "$tmp/wt" checkout -q -- owned.txt
pass "dirty checkout is refused and the ref stays put"

# 5. Conflict refuses; ref untouched, no merge state left behind.
git -C "$repo" checkout -q target; printf 'conflict\n' >"$repo/owned.txt"; git -C "$repo" commit -qam "conflicting target edit"
target4="$(git -C "$repo" rev-parse HEAD)"
if singular_refresh_retained_branch "$repo" work "$target4" "$tmp/wt" 2>"$tmp/err"; then fail "conflict was merged"; fi
grep -q conflict "$tmp/err" || fail "conflict not reported: $(cat "$tmp/err")"
[[ "$(git -C "$repo" rev-parse work)" == "$new2" ]] || fail "ref moved despite conflict"
[[ ! -f "$tmp/wt/.git/MERGE_HEAD" && ! -f "$repo/.git/worktrees/wt/MERGE_HEAD" ]] || fail "merge state left behind"
pass "conflicting base is refused cleanly"
echo "test-retained-base-refresh: ok"
