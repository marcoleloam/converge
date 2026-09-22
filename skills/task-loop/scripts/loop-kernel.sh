#!/usr/bin/env bash
# loop-kernel.sh — Pass 8's actual loop.
#
# Until this existed, Converge's "loop" ran the eval once and reported RED or
# GREEN. Every spec declared budget_iterations / max_iterations /
# circuit_breaker_no_progress / on_terminal_failure and NOTHING enforced them —
# the same defect class as WP4's unenforced external_writes policy.
#
# This is the loop specification made executable: a trigger, a goal, a
# verification, a stopping rule and a memory. See references/loop-spec.md for
# the design and its sources.
#
# THE SHAPE
#   attempt -> verify -> (green ? tier-2 -> settle : learn) -> repeat, bounded
#
#   * Each attempt spawns a FRESH agent process. State lives on disk, never in a
#     conversation, because every retry otherwise re-reads all prior failures
#     and the cost curve is quadratic while attention degrades.
#   * Verification is the task's own Exit Check — a level-1 deterministic check
#     the agent cannot edit, because the eval is HMAC-sealed and sits outside
#     the contract's fs.write scope.
#   * A GREEN eval is necessary, not sufficient. With --verify, a DIFFERENT
#     engine reads the diff, the spec's intent and the holdout — never the
#     worker's transcript — and is prompted to refute. Tier 1 catches mechanical
#     wrongness; only tier 2 catches a lookup table that satisfies the assertion.
#
#     It is OPT-IN, because it costs a full extra engine dispatch per green run
#     and a slow judge can spend more than the work did. Making it the default
#     was a mistake paid for immediately: a judge timed out at 300s and, because
#     tier 2 fails closed, BLOCKED a task whose three evals had all passed. The
#     rigor is real and belongs on high blast radius; charging every run for it
#     is how a control gets switched off wholesale instead of aimed.
#   * Stopping is a named terminal state. An error or an exhausted budget is
#     NEVER success.
#   * Budgets are three-axis (iterations, wall-clock, tokens) and checked BEFORE
#     each engine call, because a post-flight check has already spent the money.
#
# TERMINAL STATES (only the first three exit 0)
#   SETTLED | LOCAL_SETTLED | NO_OP | BLOCKED | STALLED | EXHAUSTED | CANCELLED | ERROR
#
# Usage:
#   bash loop-kernel.sh --issue <id|slug|path> [--tasks-dir DIR]
#        [--agent claude|codex|kimi] [--no-agent]
#        [--max-iterations N] [--max-seconds N] [--max-tokens N]
#        [--allow-external-writes] [--dry-run] [--resume]
#        [--base BRANCH] [--contract PATH] [--legacy-no-contract]
#        [--isolation worktree|inplace]   (worktree is the DEFAULT)
#        [--verify] [--judge codex|kimi|claude|gemini]
#
# The last three are not the loop's own controls — they belong to the eval runner
# and the settler, and are forwarded verbatim so the kernel can sit in front of
# them without narrowing the surface that already existed.
#
# Exit codes: 0 settled/local/no-op · 1 blocked/stalled/exhausted · 2 usage · 3 cancelled · 4 error
#
# Bash 3.2 compatible (stock macOS).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_RUNNER="$SCRIPT_DIR/run-issue-eval.sh"
SETTLER="$SCRIPT_DIR/open-issue-pr.sh"
# CVG_ENGINES_DIR lets a test supply stub engines without writing into the
# shipped adapter directory. A suite that mutates the product it is testing can
# pass while the product is broken, and can break the product while it passes.
ENGINES_DIR="${CVG_ENGINES_DIR:-$SCRIPT_DIR/engines}"
# CVG_TRACKER_BRIDGE, same reasoning again: the TRACKER= accounting below can only
# be proven by a bridge whose success and failure are chosen by the test. Driving
# the real Linear bridge would need creds and a network, which is precisely what a
# hermetic suite must not need.
TRACKER_BRIDGE="${CVG_TRACKER_BRIDGE:-$SCRIPT_DIR/loop-tracker.sh}"
# Same reasoning as CVG_ENGINES_DIR: a hermetic suite must be able to supply a
# deterministic verdict without calling a real judge, and without editing the
# shipped verifier it is testing.
VERIFIER="${CVG_VERIFIER:-$SCRIPT_DIR/../../task-to-runtime-contract/scripts/verify-work.py}"

err() { printf 'ERROR: %s\n' "$*" >&2; }

ISSUE=""; TASKS_DIR=""; AGENT="claude"; AGENT_EXPLICIT=false; NO_AGENT=false
MAX_ITER=""; MAX_SECONDS=""; MAX_TOKENS=""
ALLOW_EXTERNAL=false; DRY_RUN=false; RESUME=false
BASE=""; CONTRACT=""; LEGACY_NO_CONTRACT=false
# Isolation is the DEFAULT. An unattended agent should not be able to touch the
# tree a human is reading, and a failed attempt should cost nothing to discard.
# `--isolation inplace` opts out when you want to watch files land live.
ISOLATION="worktree"
# A SETTLED run's worktree is a duplicate of state already committed to a branch,
# sitting in $TMPDIR where the OS will eventually delete it and leave git holding a
# stale registration. So settled runs clean up after themselves; --keep-worktree
# opts out. Runs that end with UNCOMMITTED work always keep it, flag or not.
KEEP_WORKTREE_FLAG=false
ESTIMATE=false
# Tier-2 is ON by default. An adversarial verifier you have to remember to run
# is one nobody runs on the unattended path.
JUDGE=""; VERIFY=false
# Whether the OPERATOR spoke about tier 2. Without this the lane's default and an
# explicit --no-verify are indistinguishable, and a FULL profile would silently
# re-enable a check the operator just switched off.
VERIFY_EXPLICIT=false
# The cost dial. Empty means "let the lane decide"; a value here beats the table.
LANE=""; MODEL_FLAG=""; EFFORT_FLAG=""; ATTEMPT_SECONDS_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)          [ $# -ge 2 ] || { err "--issue requires a value"; exit 2; }; ISSUE="$2"; shift 2 ;;
    --issue=*)        ISSUE="${1#--issue=}"; shift ;;
    --tasks-dir)      [ $# -ge 2 ] || { err "--tasks-dir requires a value"; exit 2; }; TASKS_DIR="$2"; shift 2 ;;
    --tasks-dir=*)    TASKS_DIR="${1#--tasks-dir=}"; shift ;;
    --agent)          [ $# -ge 2 ] || { err "--agent requires a value"; exit 2; }; AGENT="$2"; AGENT_EXPLICIT=true; shift 2 ;;
    --agent=*)        AGENT="${1#--agent=}"; AGENT_EXPLICIT=true; shift ;;
    --no-agent)       NO_AGENT=true; shift ;;
    --max-iterations) [ $# -ge 2 ] || { err "--max-iterations requires a value"; exit 2; }; MAX_ITER="$2"; shift 2 ;;
    --max-iterations=*) MAX_ITER="${1#--max-iterations=}"; shift ;;
    --max-seconds)    [ $# -ge 2 ] || { err "--max-seconds requires a value"; exit 2; }; MAX_SECONDS="$2"; shift 2 ;;
    --max-seconds=*)  MAX_SECONDS="${1#--max-seconds=}"; shift ;;
    --max-tokens)     [ $# -ge 2 ] || { err "--max-tokens requires a value"; exit 2; }; MAX_TOKENS="$2"; shift 2 ;;
    --max-tokens=*)   MAX_TOKENS="${1#--max-tokens=}"; shift ;;
    --allow-external-writes) ALLOW_EXTERNAL=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --resume)         RESUME=true; shift ;;
    --base)           [ $# -ge 2 ] || { err "--base requires a value"; exit 2; }; BASE="$2"; shift 2 ;;
    --base=*)         BASE="${1#--base=}"; shift ;;
    --contract)       [ $# -ge 2 ] || { err "--contract requires a value"; exit 2; }; CONTRACT="$2"; shift 2 ;;
    --contract=*)     CONTRACT="${1#--contract=}"; shift ;;
    --legacy-no-contract) LEGACY_NO_CONTRACT=true; shift ;;
    --isolation)      [ $# -ge 2 ] || { err "--isolation requires worktree|inplace"; exit 2; }; ISOLATION="$2"; shift 2 ;;
    --isolation=*)    ISOLATION="${1#--isolation=}"; shift ;;
    # A settled run's worktree is a duplicate of committed state, so it is removed
    # by default. This keeps it anyway — for inspecting HOW a green run got there,
    # which the committed diff alone does not show.
    --keep-worktree)  KEEP_WORKTREE_FLAG=true; shift ;;
    # Naming a judge IS asking for tier 2 — requiring --verify alongside it would
    # be a flag that silently does nothing, which is worse than a missing flag.
    --judge)          [ $# -ge 2 ] || { err "--judge requires a value"; exit 2; }; JUDGE="$2"; VERIFY=true; VERIFY_EXPLICIT=true; shift 2 ;;
    --judge=*)        JUDGE="${1#--judge=}"; VERIFY=true; VERIFY_EXPLICIT=true; shift ;;
    --verify)         VERIFY=true; VERIFY_EXPLICIT=true; shift ;;
    --no-verify)      VERIFY=false; VERIFY_EXPLICIT=true; shift ;;
    --lane)           [ $# -ge 2 ] || { err "--lane requires FAST|NORMAL|FULL"; exit 2; }; LANE="$2"; shift 2 ;;
    --lane=*)         LANE="${1#--lane=}"; shift ;;
    --model)          [ $# -ge 2 ] || { err "--model requires haiku|sonnet|opus"; exit 2; }; MODEL_FLAG="$2"; shift 2 ;;
    --model=*)        MODEL_FLAG="${1#--model=}"; shift ;;
    --effort)         [ $# -ge 2 ] || { err "--effort requires low|medium|high"; exit 2; }; EFFORT_FLAG="$2"; shift 2 ;;
    --effort=*)       EFFORT_FLAG="${1#--effort=}"; shift ;;
    --attempt-seconds)   [ $# -ge 2 ] || { err "--attempt-seconds requires a number"; exit 2; }; ATTEMPT_SECONDS_FLAG="$2"; shift 2 ;;
    --attempt-seconds=*) ATTEMPT_SECONDS_FLAG="${1#--attempt-seconds=}"; shift ;;
    --estimate)       ESTIMATE=true; shift ;;
    -h|--help)        grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                err "unknown argument '$1'"; exit 2 ;;
  esac
done

[ -n "$ISSUE" ] || { err "--issue is required. This loop never picks its own task."; printf 'TASK_LOOP=USAGE_ERROR\n'; exit 2; }
[ -f "$EVAL_RUNNER" ] || { err "eval runner missing: $EVAL_RUNNER"; printf 'TASK_LOOP=ERROR\n'; exit 4; }

# --------------------------------------------------------------------------
# Workspace discovery — identical rules to the rest of the task family
# --------------------------------------------------------------------------
INVOCATION_DIR="$PWD"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$GIT_ROOT" ] || { err "not inside a git repository"; printf 'TASK_LOOP=ERROR\n'; exit 4; }

if [ -z "$TASKS_DIR" ]; then
  if [ -n "${TASKSPEC_BACKLOG_DIR:-}" ]; then TASKS_DIR="$TASKSPEC_BACKLOG_DIR"
  elif [ -d "$INVOCATION_DIR/cvg/tasks" ]; then TASKS_DIR="cvg/tasks"
  else TASKS_DIR="tasks"; fi
fi
case "$TASKS_DIR" in
  /*) RESOLVED_TASKS_DIR="$TASKS_DIR" ;;
  *)  if [ -d "$INVOCATION_DIR/$TASKS_DIR" ]; then RESOLVED_TASKS_DIR="$INVOCATION_DIR/$TASKS_DIR"
      else RESOLVED_TASKS_DIR="$GIT_ROOT/$TASKS_DIR"; fi ;;
esac
WORKSPACE_ROOT="$(dirname "$RESOLVED_TASKS_DIR")"
[ "$(basename "$WORKSPACE_ROOT")" = "cvg" ] && WORKSPACE_ROOT="$(dirname "$WORKSPACE_ROOT")"
[ -d "$WORKSPACE_ROOT" ] || WORKSPACE_ROOT="$GIT_ROOT"

# --------------------------------------------------------------------------
# Resolve the spec ONCE and hand an exact path downstream, so the kernel and
# the eval runner can never disagree about which task is running.
# --------------------------------------------------------------------------
TASK_FILE=""
if [ -f "$ISSUE" ]; then
  TASK_FILE="$(cd "$(dirname "$ISSUE")" && pwd)/$(basename "$ISSUE")"
elif [ -f "$RESOLVED_TASKS_DIR/$ISSUE.md" ]; then
  TASK_FILE="$RESOLVED_TASKS_DIR/$ISSUE.md"
else
  for _f in "$RESOLVED_TASKS_DIR"/T-*.md; do
    [ -f "$_f" ] || continue
    case "$(basename "$_f" .md)" in
      *"$ISSUE") TASK_FILE="$_f"; break ;;
    esac
    grep -qE "^tracker_ref:.*[:/]${ISSUE}$" "$_f" 2>/dev/null && { TASK_FILE="$_f"; break; }
  done
fi
[ -n "$TASK_FILE" ] && [ -f "$TASK_FILE" ] || {
  err "could not resolve --issue '$ISSUE' under $RESOLVED_TASKS_DIR"
  printf 'TASK_LOOP=ERROR\n'; exit 4
}
TASK_ID="$(basename "$TASK_FILE" .md)"

# Bind names the runtime whose assurance was actually resolved. A caller may
# not silently execute through a different vendor and keep the old receipt.
# `generic` is the portable detect-only contract and remains compatible with
# any concrete engine; a vendor-specific profile either selects that engine or
# rejects an explicit mismatch.
ROUTING_CONTRACT="$CONTRACT"
[ -n "$ROUTING_CONTRACT" ] || ROUTING_CONTRACT="$WORKSPACE_ROOT/cvg/execution/$TASK_ID/execution-profile.yaml"
case "$ROUTING_CONTRACT" in
  /*) : ;;
  *)  if [ -f "$WORKSPACE_ROOT/$ROUTING_CONTRACT" ]; then
        ROUTING_CONTRACT="$WORKSPACE_ROOT/$ROUTING_CONTRACT"
      elif [ -f "$INVOCATION_DIR/$ROUTING_CONTRACT" ]; then
        ROUTING_CONTRACT="$INVOCATION_DIR/$ROUTING_CONTRACT"
      fi ;;
esac
if [ "$NO_AGENT" != true ] && [ -f "$ROUTING_CONTRACT" ]; then
  PROFILE_RUNTIME="$(python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1])).get("enforcement", {}).get("primary_runtime", "")
except Exception:
    value = ""
print(str(value).strip().lower())
' "$ROUTING_CONTRACT" 2>/dev/null || true)"
  case "$PROFILE_RUNTIME" in
    generic|"") : ;;
    claude|codex|kimi)
      if [ "$AGENT_EXPLICIT" = true ] && [ "$AGENT" != "$PROFILE_RUNTIME" ]; then
        err "execution profile is bound to '$PROFILE_RUNTIME', but --agent requested '$AGENT' — re-bind for that runtime or use --agent $PROFILE_RUNTIME"
        printf 'TASK_LOOP=USAGE_ERROR\n'
        exit 2
      fi
      AGENT="$PROFILE_RUNTIME"
      ;;
    *)
      err "execution profile names unsupported primary_runtime '$PROFILE_RUNTIME' — re-bind with generic|claude|codex|kimi"
      printf 'TASK_LOOP=ERROR\n'
      exit 4
      ;;
  esac
fi

# --------------------------------------------------------------------------
# Budgets — the spec declares them; flags may only TIGHTEN them.
# A loop whose ceiling can be raised at the call site has no ceiling.
# --------------------------------------------------------------------------
spec_num() {
  grep -m1 -E "^[[:space:]]*$1:" "$TASK_FILE" 2>/dev/null \
    | sed 's/.*: *//' | tr -d '"' | tr -cd '0-9'
}
SPEC_ITER="$(spec_num budget_iterations)"; : "${SPEC_ITER:=15}"
SPEC_CB="$(spec_num circuit_breaker_no_progress)"; : "${SPEC_CB:=3}"
SPEC_TOKENS="$(spec_num budget_tokens)"
SPEC_MINUTES="$(spec_num timeout_minutes)"; : "${SPEC_MINUTES:=90}"

tighter() {  # tighter <spec> <flag>  -> the smaller positive value
  if [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null; then
    if [ -z "$1" ] || [ "$2" -lt "$1" ] 2>/dev/null; then printf '%s\n' "$2"; return; fi
  fi
  printf '%s\n' "$1"
}
BUDGET_ITER="$(tighter "$SPEC_ITER" "$MAX_ITER")"
BUDGET_TOKENS="$(tighter "${SPEC_TOKENS:-}" "$MAX_TOKENS")"
BUDGET_SECONDS="$(tighter "$((SPEC_MINUTES * 60))" "$MAX_SECONDS")"

# --------------------------------------------------------------------------
# The cost dial — what ONE attempt may spend.
#
# There used to be exactly one setting for every task: bare `claude -p`, no
# model, no effort, flat 900s. So a four-file mechanical build drew the same
# engine at the same reasoning effort as a greenfield service. Measured on the
# first real run: 66 turns, 6,873,938 cache-read tokens, $7.91.
#
# `cvg lane` already classified work FAST | NORMAL | FULL and the verdict went
# nowhere — it routed which PASSES ran and never reached what an attempt costs.
# Now it does. The resolver is deliberately a separate script: the mapping is a
# policy table that wants to be read and argued with, not grep-able bash.
#
# It ROUTES, it never WAIVES. Everything below is a DEFAULT: the spec's declared
# budgets still pass through tighter(), so a lane can lower a ceiling and never
# raise one, and an explicit flag still beats the table.
# --------------------------------------------------------------------------
SPEC_EFFORT="$(grep -m1 -E '^effort:' "$TASK_FILE" 2>/dev/null | sed 's/.*: *//' | tr -d '" ')"
: "${SPEC_EFFORT:=M}"
COST_RESOLVER="$SCRIPT_DIR/../../task-to-runtime-contract/scripts/cost-profile.py"
COST_LANE=""; COST_MODEL=""; COST_REASONING=""
COST_ATTEMPT_SECONDS=""; COST_MAX_ITERATIONS=""; COST_VERIFY=""
if [ -f "$COST_RESOLVER" ]; then
  COST_ARGS=(--effort "$SPEC_EFFORT")
  [ -n "$LANE" ] && COST_ARGS+=(--lane "$LANE")
  COST_OUT="$(python3 "$COST_RESOLVER" "${COST_ARGS[@]}" 2>/dev/null || true)"
  case "$COST_OUT" in
    *COST_PROFILE=OK*) eval "$(printf '%s\n' "$COST_OUT" | grep -E '^COST_[A-Z_]+=')" ;;
    *) printf 'note: cost profile unavailable for effort %s — engine defaults apply\n' "$SPEC_EFFORT" ;;
  esac
fi
# A lane can only TIGHTEN the iteration ceiling, exactly like --max-iterations.
BUDGET_ITER="$(tighter "$BUDGET_ITER" "${COST_MAX_ITERATIONS:-}")"
# The per-attempt cap: an explicit --attempt-seconds wins, then the lane, then
# the historical flat default that the engine lib already carries.
ATTEMPT_SECONDS="${ATTEMPT_SECONDS_FLAG:-${COST_ATTEMPT_SECONDS:-}}"
# Tier 2 defaults from the lane (FULL asks for it) unless the operator spoke.
if [ "$VERIFY_EXPLICIT" != true ] && [ "${COST_VERIFY:-}" = "true" ]; then
  VERIFY=true
fi

# --------------------------------------------------------------------------
# Isolation — where the attempts actually happen
#
# In-place, a failed attempt leaves its wreckage in your working tree and the
# NEXT attempt inherits it. That is not a fresh start; it is a fresh context
# reading a dirty desk, and it is one reason a second attempt can be worse than
# the first.
#
# A worktree gives the run its own checkout of the same repository. Work is
# discarded wholesale on any non-green landing, so the cost of a bad run is
# exactly zero, and nothing an unattended agent does can touch the tree you are
# reading. One worktree per RUN, which is one per fix — matching the granularity
# the pattern is usually described at.
# --------------------------------------------------------------------------
# The exact commit this run forks from, captured BEFORE the worktree exists,
# because that is the moment the fork happens.
#
# The settlement guard must compare the work against THIS. It used to fall back
# to `main`, and `main...HEAD` is merge-base-relative: a loop branch cut from a
# feature branch shares its merge-base with `main` at the point that FEATURE
# branch diverged, so the diff swept in every commit on it. On the first real
# run that was 135 workspace paths judged against an fs.write scope of 4 — a
# green, correct, in-scope run refused settlement, and the guard was right about
# the diff it was shown and wrong about which diff to ask for.
LOOP_BASE_COMMIT="$(git -C "$GIT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
# ...and the BRANCH that commit sits on, captured here for the same reason: this
# is the last moment we are standing on it, before the worktree is cut. The diff
# question wants the commit; the "where does this PR land?" question wants the
# branch, and answering the second with the first is what made the first live PR
# attempt fail (`Base ref must be a branch`) on work that was already pushed.
LOOP_BASE_BRANCH="$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
[ "$LOOP_BASE_BRANCH" = "HEAD" ] && LOOP_BASE_BRANCH=""   # detached: no branch to name

ORIGINAL_WORKSPACE="$WORKSPACE_ROOT"
WORKTREE_DIR=""
if [ "$ISOLATION" = "worktree" ]; then
  if ! git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    err "--isolation worktree needs a git repository"; printf 'TASK_LOOP=ERROR\n'; exit 4
  fi
  WORKTREE_DIR="$(mktemp -d -t "cvg-wt-$TASK_ID.XXXXXX")"
  rm -rf "$WORKTREE_DIR"
  WT_BRANCH="loop/$TASK_ID-$$"
  if ! git -C "$GIT_ROOT" worktree add --quiet -b "$WT_BRANCH" "$WORKTREE_DIR" >/dev/null 2>&1; then
    err "could not create a worktree at $WORKTREE_DIR"; printf 'TASK_LOOP=ERROR\n'; exit 4
  fi
  # Re-point every workspace-relative path at the isolated checkout.
  #
  # Prefix-stripping is NOT safe here: on macOS `git rev-parse --show-toplevel`
  # returns the PHYSICAL path (/private/var/...) while $PWD is the symlinked one
  # (/var/...), so `${path#$prefix}` silently fails to match and the "relative"
  # remainder is still absolute — which then gets appended to the worktree and
  # produces /worktree/private/var/... Compute the relation exactly instead.
  rel_to() {  # rel_to <path> <base> — realpath-based, so symlinks cannot lie
    python3 -c 'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$1" "$2"
  }
  _rel_ws="$(rel_to "$ORIGINAL_WORKSPACE" "$GIT_ROOT")"
  _rel_tasks="$(rel_to "$RESOLVED_TASKS_DIR" "$ORIGINAL_WORKSPACE")"
  _rel_spec="$(rel_to "$TASK_FILE" "$ORIGINAL_WORKSPACE")"
  case "$_rel_ws" in .) WORKSPACE_ROOT="$WORKTREE_DIR" ;; *) WORKSPACE_ROOT="$WORKTREE_DIR/$_rel_ws" ;; esac
  RESOLVED_TASKS_DIR="$WORKSPACE_ROOT/$_rel_tasks"
  TASK_FILE="$WORKSPACE_ROOT/$_rel_spec"
  [ -f "$TASK_FILE" ] || {
    err "the spec is not present in the worktree ($TASK_FILE) — commit it before using --isolation worktree"
    printf 'TASK_LOOP=ERROR\n'; exit 4
  }
  printf 'isolation: worktree %s (branch %s)\n' "$WORKTREE_DIR" "$WT_BRANCH"
  # A worktree is a checkout of COMMITTED state. Uncommitted work in the main
  # tree is invisible to it — correct git semantics, and a genuinely confusing
  # way to start green if nobody says so out loud.
  _dirty="$(git -C "$GIT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${_dirty:-0}" -gt 0 ]; then
    printf 'NOTE: %s uncommitted change(s) in the main tree are NOT visible to the\n' "$_dirty"
    printf '      worktree — it checks out committed state. Commit them first, or\n'
    printf '      pass --isolation inplace to run against what you can see.\n'
  fi
fi

# Task-Spec's configured roots must follow the dispatch workspace too. Keeping
# the original checkout's absolute backlog here would let an isolated attempt
# append metrics or acceptance state outside its own worktree.
# 3.9 rebuild-state keeps path: repo-relative only when these match the
# physical Git toplevel. /tmp on macOS is a symlink of /private/tmp.
physical_dir() {
  _pd_target="$1"
  if [ -d "$_pd_target" ]; then
    (cd "$_pd_target" && pwd -P)
    return 0
  fi
  _pd_parent="$(dirname "$_pd_target")"
  if [ -d "$_pd_parent" ]; then
    printf '%s/%s\n' "$(cd "$_pd_parent" && pwd -P)" "$(basename "$_pd_target")"
    return 0
  fi
  printf '%s\n' "$_pd_target"
}
export TASKSPEC_BACKLOG_DIR="$(physical_dir "$RESOLVED_TASKS_DIR")"
export TASKSPEC_WORKSPACE_ROOT="$(physical_dir "$WORKSPACE_ROOT")"
export TASKSPEC_ACCEPTANCE_DIR="$(physical_dir "$(dirname "$RESOLVED_TASKS_DIR")/.taskspec/acceptance")"

# TaskHandoff/v3 is an ATTEMPT contract, not a bind-time project artifact. Mint
# it only after the final workspace and immutable base exist. This is what keeps
# worktree dispatch honest: a handoff issued in the original checkout names the
# wrong workspace and cannot be accepted in the isolated one.
ATTEMPT_HANDOFF=""
if [ "$LEGACY_NO_CONTRACT" != true ] && [ "$DRY_RUN" != true ]; then
  TASKSPEC_ENGINE="${CVG_TASKSPEC_BIN:-${TASKSPEC_BIN:-taskspec}}"
  ATTEMPT_HANDOFF="$WORKSPACE_ROOT/cvg/execution/$TASK_ID/task-handoff.json"
  _handoff_backend="$(grep -m1 '^execution_backend:' "$TASK_FILE" 2>/dev/null | awk '{print $2}')"
  : "${_handoff_backend:=any}"
  mkdir -p "$(dirname "$ATTEMPT_HANDOFF")"
  HANDOFF_OUT="$(
    cd "$WORKSPACE_ROOT" &&
      "$TASKSPEC_ENGINE" handoff "$TASK_FILE" --backend "$_handoff_backend" \
        --out "$ATTEMPT_HANDOFF" --force 2>&1
  )"
  HANDOFF_RC=$?
  printf '%s\n' "$HANDOFF_OUT"
  if [ "$HANDOFF_RC" -ne 0 ] || ! printf '%s\n' "$HANDOFF_OUT" | grep -q '^HANDOFF=WRITTEN '; then
    err "Task-Spec could not issue the dispatch handoff in the final workspace"
    printf 'TASK_LOOP=ERROR\n'
    exit 4
  fi
fi

# Discard the isolated checkout unless the run earned a keep. Registered on EXIT
# so a crash cannot leave orphaned worktrees accumulating on disk.
KEEP_WORKTREE=false
# Set by land() so the trap — which is called with no arguments — can tell a
# settled removal from an ordinary one.
CLEANUP_REASON=""
cleanup_worktree() {
  [ -n "$WORKTREE_DIR" ] || return 0
  if [ "$KEEP_WORKTREE" = true ]; then
    printf 'worktree KEPT for inspection: %s (branch %s)\n' "$WORKTREE_DIR" "$WT_BRANCH"
    printf '  the work is UNCOMMITTED and lives only here — resume, or remove it with:\n'
    printf '  git -C %s worktree remove --force %s\n' "$GIT_ROOT" "$WORKTREE_DIR"
    return 0
  fi
  git -C "$GIT_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
  git -C "$GIT_ROOT" branch -D "$WT_BRANCH" >/dev/null 2>&1 || true
  # A worktree removed by hand, or one whose $TMPDIR was reaped by the OS, leaves a
  # registration behind that `git worktree list` keeps reporting forever. Prune so
  # the repo's own account of itself stays true.
  git -C "$GIT_ROOT" worktree prune >/dev/null 2>&1 || true
  # Say it out loud on the settled path only. A silent removal after a run that
  # printed a $TMPDIR path throughout reads as "where did my work go" — and the
  # answer (a branch, plus the receipt that names it) is worth one line.
  if [ "$CLEANUP_REASON" = settled ]; then
    printf 'worktree removed — the work is committed on the task branch named in the receipt.\n'
  fi
  return 0
}
trap cleanup_worktree EXIT

# --------------------------------------------------------------------------
# Is the loop authorized to WRITE to the tracker?
#
# Posting to Linear is an external write — the same class of effect as a push or
# a PR, and WP4 established those are four distinct effects rather than one. The
# capability envelope says so explicitly: `tracker.write` carries its own grant,
# and `policy.external_writes` defaults to deny. Narrating progress to a board
# without that authority would be the loop quietly exceeding its contract, which
# is precisely the defect class this envelope exists to prevent.
#
# Denied is not broken: the run proceeds, fully, locally. It just does not speak.
# --------------------------------------------------------------------------
RESOLVED_CONTRACT="$CONTRACT"
[ -n "$RESOLVED_CONTRACT" ] || RESOLVED_CONTRACT="$WORKSPACE_ROOT/cvg/execution/$TASK_ID/execution-profile.yaml"
TRACKER_WRITE=false
if [ "$ALLOW_EXTERNAL" = true ]; then
  TRACKER_WRITE=true
elif [ -f "$RESOLVED_CONTRACT" ]; then
  _tw="$(python3 -c '
import json, sys
try:
    p = json.load(open(sys.argv[1]))
except Exception:
    print("deny"); raise SystemExit
if str(p.get("policy", {}).get("external_writes", "deny")) == "allow":
    print("allow"); raise SystemExit
grant = next((g for g in p.get("authority", {}).get("grants", [])
              if g.get("capability") == "tracker.write"), {})
print("allow" if grant.get("scope") else "deny")
' "$RESOLVED_CONTRACT" 2>/dev/null || printf 'deny')"
  [ "$_tw" = "allow" ] && TRACKER_WRITE=true
fi

# tracker <phase> [args...] — narrate ONLY when authorized, and never let a
# tracker failure change the verdict the evals produced.
#
# FAIL-SOFT IS NOT THE SAME AS SILENT.
# This used to be `( ... ) >/dev/null 2>&1 || true` — output and status both
# discarded. The run printed "tracker: authorized — the board will follow this
# run" and then nothing in its own output could confirm or deny that it had. On
# 2026-07-29 the board write was broken for weeks (a GraphQL type error) and the
# logs of every run looked identical to a run where it worked; the only way to
# find out was to go and look at Linear. A fail-soft call that reports nothing
# cannot be verified, and an unverifiable claim in a log is worse than no claim.
#
# So: still fail-soft (the verdict is the evals', never the board's), but now
# ACCOUNTED. Output goes to cvg/loop/<task>/tracker.log and the outcome is
# summarised in one token beside TASK_LOOP:
#   TRACKER=OK       every attempted call succeeded
#   TRACKER=FAILED   at least one call failed — the board may be behind
#   TRACKER=SKIPPED  not authorized, or no bridge present (the normal
#                    LOCAL_SETTLED case: nothing left the machine, so the board
#                    must not claim the work shipped)
TRACKER_STATE=SKIPPED
TRACKER_CALLS=0
TRACKER_FAILS=0
tracker() {
  [ "$TRACKER_WRITE" = true ] || return 0
  [ -f "$TRACKER_BRIDGE" ] || return 0
  # LOOP_DIR is defined just below; guard so an early call cannot break on it.
  _tlog="${LOOP_DIR:-${TMPDIR:-/tmp}}/tracker.log"
  mkdir -p "$(dirname "$_tlog")" 2>/dev/null || true
  TRACKER_CALLS=$((TRACKER_CALLS + 1))
  {
    printf '\n=== %s :: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
  } >> "$_tlog" 2>/dev/null || true
  if ( bash "$TRACKER_BRIDGE" --task "$TASK_FILE" "$@" ) >> "$_tlog" 2>&1; then
    [ "$TRACKER_STATE" = FAILED ] || TRACKER_STATE=OK
  else
    TRACKER_FAILS=$((TRACKER_FAILS + 1))
    TRACKER_STATE=FAILED
    printf 'tracker: call failed (phase %s) — board may be behind; see %s\n' \
      "${2:-?}" "${_tlog#"${WORKSPACE_ROOT:-}"/}" >&2
  fi
  return 0
}

# --------------------------------------------------------------------------
# Durable state — the loop's position must survive a crash, or a restart
# silently restarts the work and double-applies its side effects.
# --------------------------------------------------------------------------
LOOP_DIR="$WORKSPACE_ROOT/cvg/loop/$TASK_ID"
STATE_FILE="$LOOP_DIR/state.env"
ATTEMPTS_DIR="$LOOP_DIR/attempts"
HANDOFF="$LOOP_DIR/HANDOFF.md"
STOP_FILE="$LOOP_DIR/STOP"
mkdir -p "$ATTEMPTS_DIR"

ITER=0; STRIKES=0; TOKENS_USED=0; LAST_FINGERPRINT=""; STARTED_AT=""
# Wall-clock is ACCUMULATED WORKING TIME, not wall time since the first attempt.
#
# Persisting a start timestamp and resuming against it means the clock runs while
# the loop is not: pick a run up the next morning and `now - STARTED_AT` is ~20
# hours against a 90-minute budget, so it lands EXHAUSTED before making a single
# attempt — reporting a spent budget on a run that spent nothing. The budget is
# meant to bound what the loop DOES, so only time inside a session counts.
ELAPSED_PRIOR=0
if [ "$RESUME" = true ] && [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  printf 'resuming at iteration %s (strikes %s)\n' "$ITER" "$STRIKES"
fi
# SESSION_START is always now and is deliberately NOT restored from state.
SESSION_START="$(date -u +%s)"
[ -n "$STARTED_AT" ] || STARTED_AT="$SESSION_START"
case "$ELAPSED_PRIOR" in ''|*[!0-9]*) ELAPSED_PRIOR=0 ;; esac

elapsed() { echo $(( ELAPSED_PRIOR + $(date -u +%s) - SESSION_START )); }

save_state() {
  {
    printf 'ITER=%s\n' "$ITER"
    printf 'STRIKES=%s\n' "$STRIKES"
    printf 'TOKENS_USED=%s\n' "$TOKENS_USED"
    printf 'STARTED_AT=%s\n' "$STARTED_AT"
    # The running total, so the NEXT session resumes the budget rather than the
    # clock. Written every checkpoint; the in-memory ELAPSED_PRIOR never moves.
    printf 'ELAPSED_PRIOR=%s\n' "$(elapsed)"
    printf 'LAST_FINGERPRINT=%s\n' "$LAST_FINGERPRINT"
  } > "$STATE_FILE"
}

# --------------------------------------------------------------------------
# Terminal states. Exactly one is reached, it is always named, and an error
# never reports as success.
# --------------------------------------------------------------------------
land() {  # land <STATE> <exit-code> <why>
  _state="$1"; _rc="$2"; _why="${3:-}"
  save_state
  # Before anything else can discard the worktree: carry the evidence home.
  sync_receipt
  # Only a landing that produced something worth keeping keeps its worktree.
  # EXHAUSTED and STALLED keep it too: the handoff note is useless without the
  # work it describes, and --resume needs somewhere to resume into.
  case "$_state" in
    # THE RULE: keep the worktree exactly when the work exists NOWHERE ELSE.
    #
    # EXHAUSTED, STALLED and BLOCKED all end with the work UNCOMMITTED — it lives
    # only in the worktree, the handoff note is useless without it, and --resume
    # needs somewhere to resume into. BLOCKED's absence from this list once cost a
    # diagnosis: a run that went GREEN and then had settlement refused is exactly
    # when you most need to ask why.
    #
    # SETTLED and LOCAL_SETTLED are the opposite case, and they used to be here by
    # mistake. Settlement's whole job is to COMMIT the work onto a branch in the
    # shared repository, and sync_receipt (called above, before this decision) has
    # already carried the receipt home. So after a settled run the worktree holds
    # nothing that the repo does not — it is a duplicate under $TMPDIR that the OS
    # will delete out from under git, leaving a stale registration behind. Two
    # accumulated in one afternoon of a single task.
    EXHAUSTED|STALLED|BLOCKED) KEEP_WORKTREE=true ;;
    SETTLED|LOCAL_SETTLED)
      CLEANUP_REASON=settled
      if [ "$KEEP_WORKTREE_FLAG" = true ]; then KEEP_WORKTREE=true; fi
      ;;
    *) : ;;
  esac
  printf '\n────────────────────────────────────────────────────────\n'
  printf 'iterations %s/%s · elapsed %ss/%ss' "$ITER" "$BUDGET_ITER" "$(elapsed)" "$BUDGET_SECONDS"
  [ -n "$BUDGET_TOKENS" ] && printf ' · tokens %s/%s' "$TOKENS_USED" "$BUDGET_TOKENS"
  printf '\n'
  [ -n "$_why" ] && printf '%s\n' "$_why"
  [ -f "$HANDOFF" ] && printf 'handoff: %s\n' "${HANDOFF#"$WORKSPACE_ROOT"/}"
  write_state_md "$_state" "$_why"
  printf 'TASK_LOOP=%s\n' "$_state"
  # Narrate the outcome to the tracker. Fail-soft: a tracker that is down must
  # never change the verdict the evals produced.
  tracker --phase terminal --state "$_state" --note "$_why"
  # ...but SAY what happened. This token is informational and deliberately does
  # not affect $_rc: the evals decide the verdict, not the board.
  printf 'TRACKER=%s' "$TRACKER_STATE"
  [ "$TRACKER_CALLS" -gt 0 ] && printf ' (%s call(s), %s failed)' "$TRACKER_CALLS" "$TRACKER_FAILS"
  printf '\n'
  exit "$_rc"
}

write_handoff() {  # the planned landing — state and next steps, on disk
  _reason="$1"
  {
    printf '# Handoff — %s\n\n' "$TASK_ID"
    printf '**Why the loop stopped:** %s\n\n' "$_reason"
    # `printf '- ...'` makes bash read the FORMAT as an option and emit
    # "invalid option" — which is how the handoff note lost the very numbers it
    # exists to report. Put the leading dash in the ARGUMENT, never the format.
    printf '%s\n' "- iterations: $ITER / $BUDGET_ITER"
    printf '%s\n' "- elapsed: $(elapsed)s / ${BUDGET_SECONDS}s"
    [ -n "$BUDGET_TOKENS" ] && printf '%s\n' "- tokens: $TOKENS_USED / $BUDGET_TOKENS"
    printf '\n## Last failure\n\n```\n'
    if [ -f "$ATTEMPTS_DIR/$(printf '%03d' "$ITER").log" ]; then
      tail -40 "$ATTEMPTS_DIR/$(printf '%03d' "$ITER").log"
    else
      printf '(no attempt log)\n'
    fi
    printf '```\n\n## Next steps for whoever picks this up\n\n'
    printf '1. Read the failing eval above — it is the definition of done.\n'
    printf '2. `cvg loop --issue %s --resume` continues from iteration %s.\n' "$TASK_ID" "$ITER"
    printf '3. If the gap is upstream (a wrong ADR, a wrong plan, a wrong spec),\n'
    printf '   fix the pass that owns it rather than this task.\n'
  } > "$HANDOFF"
}

# --------------------------------------------------------------------------
# cvg/STATE.md — the one file a human glances at.
#
# state.env is for the machine and receipts are per-run evidence. Neither
# answers "what have the loops been doing?" at a glance, which is what an owner
# who is not tailing a terminal actually wants. Append-only: a log you can
# rewrite is a log you cannot trust.
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# The execution receipt has to land where a human and CI will look.
#
# The settler writes it relative to ITS workspace, which under isolation is the
# temporary worktree. So a run that genuinely settled wrote `result: pass` into
# $TMPDIR and left the repository holding a STALE receipt saying `blocked` — the
# durable, machine-readable proof of success living in a directory
# `git worktree prune` eventually deletes, while the repo asserted the opposite.
#
# STATE.md already went to ORIGINAL_WORKSPACE and the receipt did not: two
# evidence artifacts from one run, landing in two different roots. That is the
# same defect class as the eval CWD, the settlement base and the untracked diff —
# components privately deciding which root is authoritative.
# --------------------------------------------------------------------------
sync_receipt() {
  [ -n "$WORKTREE_DIR" ] || return 0                      # in-place: already home
  [ "$WORKSPACE_ROOT" != "$ORIGINAL_WORKSPACE" ] || return 0
  _rc_src="$WORKSPACE_ROOT/cvg/receipts/$TASK_ID.json"
  [ -f "$_rc_src" ] || return 0
  _rc_dst="$ORIGINAL_WORKSPACE/cvg/receipts/$TASK_ID.json"
  mkdir -p "$(dirname "$_rc_dst")" 2>/dev/null || return 0
  cp "$_rc_src" "$_rc_dst" 2>/dev/null || return 0
  printf 'receipt: %s (copied out of the worktree)\n' "${_rc_dst#"$ORIGINAL_WORKSPACE"/}"
  # Attempt receipts are per-run evidence too, and the path policy already
  # exempts them by name, so carrying them out cannot widen any scope.
  for _rc_att in "$WORKSPACE_ROOT/cvg/receipts/$TASK_ID.attempt-"*.json; do
    [ -f "$_rc_att" ] || continue
    cp "$_rc_att" "$ORIGINAL_WORKSPACE/cvg/receipts/" 2>/dev/null || true
  done
  return 0
}

write_state_md() {
  _sm_state="$1"; _sm_why="${2:-}"
  _sm_file="$ORIGINAL_WORKSPACE/cvg/STATE.md"
  mkdir -p "$(dirname "$_sm_file")" 2>/dev/null || return 0
  if [ ! -f "$_sm_file" ]; then
    {
      printf '# Loop state\n\n'
      printf 'Append-only. Written by `cvg loop` on every landing.\n'
      printf 'An error or an exhausted budget is never recorded as success.\n\n'
      printf '| when (UTC) | task | engine | state | iterations | note |\n'
      printf '|---|---|---|---|---|---|\n'
    } > "$_sm_file"
  fi
  printf '| %s | `%s` | %s | **%s** | %s/%s | %s |\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK_ID" \
    "$([ "$NO_AGENT" = true ] && echo none || echo "$AGENT")" \
    "$_sm_state" "$ITER" "$BUDGET_ITER" \
    "$(printf '%s' "${_sm_why:-—}" | tr '|' '/' | cut -c1-90)" >> "$_sm_file"
  return 0
}

# --------------------------------------------------------------------------
# The verification step — the task's own Exit Check. Level 1: an exit code.
# --------------------------------------------------------------------------
VERIFY_ARGS=(--issue "$TASK_FILE" --tasks-dir "$RESOLVED_TASKS_DIR")
[ -n "$CONTRACT" ] && VERIFY_ARGS+=(--contract "$CONTRACT")
[ "$LEGACY_NO_CONTRACT" = true ] && VERIFY_ARGS+=(--legacy-no-contract)

verify() {  # -> 0 GREEN, 1 RED, 2 unresolvable; output on stdout
  bash "$EVAL_RUNNER" "${VERIFY_ARGS[@]}" 2>&1
}

# A fingerprint of HOW it failed, not merely that it failed. Two identical
# fingerprints in a row is the stagnation signal — the loop is re-deriving the
# same wrong answer, and more iterations will not help.
#
# The eval runner stamps each line with a duration — `[fail] eval_1 (0s)` — and
# that duration MUST be stripped before hashing. Otherwise the same failure taking
# 1s instead of 0s under load reads as progress: the strike counter resets, the
# stagnation detector never fires, and the loop spends its whole budget (and real
# money) on precisely the case the detector exists to stop. A stopping rule that
# depends on machine load is not a stopping rule. Observed as a flaky brake test:
# the circuit breaker fired at 3 attempts on most runs and 6 on a slow one.
fingerprint() {
  printf '%s' "$1" \
    | grep -E '^\[(fail|pass)\]|^Exit Check:' \
    | sed -E 's/ \([0-9]+s\)$//' \
    | shasum -a 256 2>/dev/null | awk '{print $1}' \
    || printf 'nofp\n'
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
printf 'loop: %s\n' "$TASK_ID"
printf 'spec: %s\n' "${TASK_FILE#"$WORKSPACE_ROOT"/}"
printf 'budgets: %s iterations · %ss wall-clock' "$BUDGET_ITER" "$BUDGET_SECONDS"
[ -n "$BUDGET_TOKENS" ] && printf ' · %s tokens' "$BUDGET_TOKENS"
printf '\nstagnation: %s identical failures\n' "$SPEC_CB"
if [ "$TRACKER_WRITE" = true ]; then
  printf 'tracker: authorized — the board will follow this run\n'
else
  printf 'tracker: not authorized by the contract (external_writes deny) — local only\n'
fi
if [ "$NO_AGENT" = true ]; then
  printf 'engine: none (--no-agent: gate only, no attempts)\n'
else
  printf 'engine: %s\n' "$AGENT"
  # The dial, stated out loud. A run whose cost you cannot see before it starts
  # is a run you cannot authorize, and this is the line that got missed for the
  # first three: every task drew the top model at a flat 900s and nothing said so.
  if [ -n "$COST_LANE" ]; then
    printf 'lane: %s (effort %s) → model %s · reasoning %s · %ss per attempt\n' \
      "$COST_LANE" "$SPEC_EFFORT" \
      "${MODEL_FLAG:-$COST_MODEL}" "${EFFORT_FLAG:-$COST_REASONING}" \
      "${ATTEMPT_SECONDS:-${ENGINE_TIMEOUT:-900}}"
  fi
  if [ "$VERIFY" = true ]; then
    printf 'tier 2: ON%s — one extra engine dispatch on green\n' \
      "$([ -n "$JUDGE" ] && printf ' (judge %s)' "$JUDGE")"
  else
    printf 'tier 2: off (--verify to enable)\n'
  fi
fi
printf '────────────────────────────────────────────────────────\n'

# --------------------------------------------------------------------------
# --estimate — the CEILING, not a prediction.
#
# We deliberately do not guess what a run will cost. Engines frequently report
# no usage at all (the last codex run finished with TOKENS_USED=0), so any
# "estimate" would be a number we invented. What IS knowable is the bound: the
# most this run can consume before its own brakes stop it. That is the number
# worth reading before authorising something unattended.
# --------------------------------------------------------------------------
if [ "$ESTIMATE" = true ]; then
  _eng_cap="${ATTEMPT_SECONDS:-${ENGINE_TIMEOUT:-900}}"
  printf 'CEILING for this run — the most it can spend before the brakes stop it:\n'
  if [ -n "$COST_LANE" ]; then
    printf '  dial            : lane %s · effort %s · model %s · reasoning %s\n' \
      "$COST_LANE" "$SPEC_EFFORT" "${MODEL_FLAG:-$COST_MODEL}" "${EFFORT_FLAG:-$COST_REASONING}"
    printf '  tier 2          : %s\n' \
      "$([ "$VERIFY" = true ] && printf 'ON — one extra engine dispatch on green' || printf 'off')"
  fi
  printf '  attempts        : up to %s\n' "$BUDGET_ITER"
  printf '  per attempt     : up to %ss of engine wall-clock\n' "$_eng_cap"
  printf '  whole run       : hard stop at %ss, whichever comes first\n' "$BUDGET_SECONDS"
  if [ -n "$BUDGET_TOKENS" ]; then
    printf '  tokens          : hard stop at %s\n' "$BUDGET_TOKENS"
  else
    printf '  tokens          : NO ceiling declared — the spec sets no budget_tokens,\n'
    printf '                    and engines often report no usage, so this axis is\n'
    printf '                    not enforceable on this run. Bound it with\n'
    printf '                    --max-tokens, or rely on the two above.\n'
  fi
  printf '  worst case      : %s attempt(s) x %ss = %ss of engine time\n' \
    "$BUDGET_ITER" "$_eng_cap" "$((BUDGET_ITER * _eng_cap))"
  printf '  stagnation exit : after %s identical failures, usually far sooner\n' "$SPEC_CB"
  printf 'ESTIMATE=CEILING\n'
  exit 0
fi

if [ "$DRY_RUN" = true ]; then
  printf 'DRY-RUN: would loop up to %s attempts with %s, verifying after each.\n' "$BUDGET_ITER" "$AGENT"
  printf 'DRY_RUN=OK\n'; exit 0
fi

# An already-green task is a clean no-op, not a success we manufactured.
PRE_OUT="$(verify)"; PRE_RC=$?
if [ "$PRE_RC" -eq 2 ]; then
  printf '%s\n' "$PRE_OUT"
  land ERROR 4 "the task could not be resolved or its contract is missing"
fi
if [ "$PRE_RC" -eq 0 ]; then
  printf '%s\n' "$PRE_OUT" | tail -4
  land NO_OP 0 "already green on arrival — nothing to do"
fi
LAST_FINGERPRINT="$(fingerprint "$PRE_OUT")"
printf 'preflight: RED (expected — the work is not built yet)\n'

# The terrain pack for this task's swimlane, if Bind assembled one. Resolved from
# the spec's `parent:` the same way context-pack.py does, so the two cannot
# disagree about which lane a task belongs to.
PACK_FILE=""
_pack_parent="$(grep -m1 -E '^parent:' "$TASK_FILE" 2>/dev/null | sed 's/^parent:[[:space:]]*//' | tr -d '"'"'"' ')"
case "$_pack_parent" in
  *swimlane-*)
    _pack_lane="$(printf '%s\n' "$_pack_parent" | tr '/' '\n' | grep -m1 '^swimlane-')"
    _pack_try="$WORKSPACE_ROOT/cvg/execution/_packs/$_pack_lane.md"
    [ -f "$_pack_try" ] && PACK_FILE="$_pack_try"
    ;;
esac
if [ -n "$PACK_FILE" ]; then
  printf 'terrain: %s (%s bytes) inlined into every attempt\n\n' \
    "${PACK_FILE#"$WORKSPACE_ROOT"/}" "$(wc -c < "$PACK_FILE" | tr -d ' ')"
else
  printf 'terrain: no pack for this lane — the agent will rediscover it (run cvg bind)\n\n'
fi

# Claim the work in the tracker: this is where backlog becomes in-progress.
tracker --phase claim --agent "$AGENT"

# --------------------------------------------------------------------------
# The loop
# --------------------------------------------------------------------------
ENGINE="$ENGINES_DIR/$AGENT.sh"
if [ "$NO_AGENT" != true ]; then
  [ -f "$ENGINE" ] || land ERROR 4 "no engine adapter for '$AGENT' (looked in ${ENGINES_DIR#"$WORKSPACE_ROOT"/})"
  if ! bash "$ENGINE" --available >/dev/null 2>&1; then
    land ERROR 4 "engine '$AGENT' is not available on this host — install its CLI, choose another --agent, or run --no-agent for gate-only"
  fi
fi

while :; do
  # ---- brakes, checked BEFORE spending anything ----
  [ -f "$STOP_FILE" ] && { rm -f "$STOP_FILE"; land CANCELLED 3 "an external stop signal arrived"; }

  if [ "$ITER" -ge "$BUDGET_ITER" ]; then
    write_handoff "iteration budget exhausted ($BUDGET_ITER)"
    land EXHAUSTED 1 "iteration budget exhausted — work-in-progress and a handoff note are on disk"
  fi
  if [ "$(elapsed)" -ge "$BUDGET_SECONDS" ]; then
    write_handoff "wall-clock budget exhausted (${BUDGET_SECONDS}s)"
    land EXHAUSTED 1 "wall-clock budget exhausted"
  fi
  if [ -n "$BUDGET_TOKENS" ] && [ "$TOKENS_USED" -ge "$BUDGET_TOKENS" ]; then
    write_handoff "token budget exhausted ($BUDGET_TOKENS)"
    land EXHAUSTED 1 "token budget exhausted"
  fi
  if [ "$NO_AGENT" = true ]; then
    land BLOCKED 1 "gate-only mode: the eval is RED and no engine was allowed to attempt a fix"
  fi

  ITER=$((ITER + 1))
  LOG="$ATTEMPTS_DIR/$(printf '%03d' "$ITER").log"
  printf '── attempt %s/%s ──\n' "$ITER" "$BUDGET_ITER"

  # ---- the attempt: a FRESH process, briefed from disk ----
  BRIEF="$LOOP_DIR/brief-$(printf '%03d' "$ITER").md"
  {
    printf 'You are executing ONE Converge task under a signed contract.\n\n'
    printf 'Task-Spec (the only instruction source): %s\n' "${TASK_FILE#"$WORKSPACE_ROOT"/}"
    printf 'Task brief (what the runtime enforces): cvg/execution/%s/AGENTS.task.md\n\n' "$TASK_ID"
    printf 'Attempt %s of %s.\n\n' "$ITER" "$BUDGET_ITER"
    printf 'Done is the spec Exit Check exiting zero — not your judgement.\n'
    printf 'You may write ONLY inside the contract fs.write scope.\n'
    printf 'You may NOT edit the Task-Spec, its evals, or any test that grades you.\n\n'
    # The terrain, inlined. Passes 2-4 already settled the seam shape, the
    # governing decisions and the vocabulary; handing over a POINTER to them
    # meant rediscovering all of it every attempt, because the context is
    # deliberately fresh each time. One pack per swimlane, assembled at bind.
    if [ -n "$PACK_FILE" ] && [ -f "$PACK_FILE" ]; then
      printf '## Terrain you do not need to rediscover\n\n'
      cat "$PACK_FILE"
      printf '\n'
    fi
    printf '## The failing verification you must fix\n\n```\n'
    # Only the ASSERTIONS, not the runner's preamble. On attempt 1 the raw output
    # is ~20 lines of contract banner, absolute paths and "do not open a PR"
    # boilerplate wrapped around three `[fail]` lines — near-zero signal spent
    # where the terrain should have been. Fall back to the tail only if the
    # filter matches nothing, so an unexpected runner format still reports.
    _failing="$(printf '%s\n' "$PRE_OUT" | grep -E '^\s*\[(fail|pass)\]|^\s*Exit Check:|^(RED|GREEN)$' || true)"
    if [ -n "$_failing" ]; then
      printf '%s\n' "$_failing"
    else
      printf '%s\n' "$PRE_OUT" | tail -30
    fi
    printf '```\n'
    if [ "$ITER" -gt 1 ] && [ -f "$ATTEMPTS_DIR/$(printf '%03d' $((ITER - 1))).log" ]; then
      printf '\n## What the previous attempt did (do not repeat it)\n\n```\n'
      tail -25 "$ATTEMPTS_DIR/$(printf '%03d' $((ITER - 1))).log"
      printf '```\n'
    fi
  } > "$BRIEF"

  # Checkpoint BEFORE the attempt, not after. An engine call can run for many
  # minutes; if the process is killed during one, a checkpoint written only on
  # the way out means --resume has nothing to resume from and the whole attempt
  # is silently redone. The checkpoint must already exist when the loop pauses.
  save_state

  tracker --phase attempt --agent "$AGENT" --iteration "$ITER" --of "$BUDGET_ITER"

  # NOTE: this script runs under `set -uo pipefail` and deliberately NOT under
  # -e. Do not "restore" errexit here — `set -e` would ENABLE it, and the very
  # next RED verification would kill the loop instead of feeding the failure
  # into the next attempt. A loop that dies on its own red path is not a loop.
  # Reset per attempt: a leaked non-zero from an earlier iteration would report
  # every later attempt as a failed engine call.
  ENGINE_RC=0
  # The kernel spells no vendor and no model id — it forwards a neutral tier and
  # the adapter translates. An explicit flag beats the lane's default.
  ENGINE_ARGS=(--prompt-file "$BRIEF" --workdir "$WORKSPACE_ROOT")
  _eng_model="${MODEL_FLAG:-$COST_MODEL}"
  _eng_effort="${EFFORT_FLAG:-$COST_REASONING}"
  [ -n "$_eng_model" ]  && ENGINE_ARGS+=(--model "$_eng_model")
  [ -n "$_eng_effort" ] && ENGINE_ARGS+=(--effort "$_eng_effort")
  [ -n "$ATTEMPT_SECONDS" ] && ENGINE_ARGS+=(--timeout "$ATTEMPT_SECONDS")
  ENGINE_OUT="$(cd "$WORKSPACE_ROOT" && bash "$ENGINE" "${ENGINE_ARGS[@]}" 2>&1)" || ENGINE_RC=$?
  printf '%s\n' "$ENGINE_OUT" > "$LOG"

  # Engines report what they spent when they can; absence is not zero, it is
  # unknown, so an absent count must never look like a fresh budget.
  _spent="$(printf '%s' "$ENGINE_OUT" | grep -oE '^ENGINE_TOKENS=[0-9]+' | tail -1 | cut -d= -f2)"
  if [ -n "$_spent" ]; then TOKENS_USED=$((TOKENS_USED + _spent)); fi

  if [ "$ENGINE_RC" -ne 0 ]; then
    printf 'engine exited %s (see %s)\n' "$ENGINE_RC" "${LOG#"$WORKSPACE_ROOT"/}"
  fi

  # ---- verify: the check the agent cannot edit ----
  OUT="$(verify)"; RC=$?
  printf '%s\n' "$OUT" | grep -E '^\[(pass|fail)\]|^Exit Check:' | sed 's/^/    /'
  printf '%s\n' "$OUT" >> "$LOG"
  save_state

  if [ "$RC" -eq 0 ]; then
    printf '\nGREEN at iteration %s.\n' "$ITER"
    break
  fi
  if [ "$RC" -eq 2 ]; then
    land ERROR 4 "the verification step itself could not run"
  fi

  # ---- stagnation: same failure, same way, twice ----
  FP="$(fingerprint "$OUT")"
  if [ "$FP" = "$LAST_FINGERPRINT" ]; then
    STRIKES=$((STRIKES + 1))
    printf '    no progress (%s/%s identical failures)\n' "$STRIKES" "$SPEC_CB"
  else
    STRIKES=0
  fi
  LAST_FINGERPRINT="$FP"
  PRE_OUT="$OUT"
  save_state

  if [ "$STRIKES" -ge "$SPEC_CB" ]; then
    write_handoff "stagnation — the same check failed the same way $STRIKES times"
    land STALLED 1 "stagnation detector fired: more iterations will not help. This is usually an upstream gap, not a coding failure."
  fi
done

# The reference every downstream comparison is made against. An explicit --base
# wins; otherwise it is the commit this run forked from, which is exact rather
# than guessed.
SETTLE_BASE="$BASE"
[ -n "$SETTLE_BASE" ] || SETTLE_BASE="$LOOP_BASE_COMMIT"

# --------------------------------------------------------------------------
# Tier 2 — graded by an engine that did not do the work.
#
# The eval is authored by the same intelligence that implements against it and
# then grades itself. That catches mechanical wrongness and nothing else: a
# hardcoded lookup table satisfies the assertion, and the letter of the eval can
# be met while its intent is skirted. So a different-FAMILY judge reads the
# diff, the stated intent and the holdout — never the worker's transcript — and
# is prompted to REFUTE.
#
# It fails CLOSED. A refutation, a malformed verdict, a timeout or a judge that
# will not start all stop settlement. The only verdict that proceeds without an
# independent opinion is UNAVAILABLE, which verify-work.py itself permits only
# for low blast radius.
# --------------------------------------------------------------------------
if [ "$VERIFY" != true ]; then
  printf '\n── tier 2 ── not requested: settling on the sealed eval alone (--verify to enable)\n'
elif [ ! -f "$VERIFIER" ]; then
  printf '\n── tier 2 ── verifier not found at %s — skipping\n' "$VERIFIER"
else
  printf '\n── tier 2 · adversarial verification ──\n'
  VERIFY_CMD=(--task "$TASK_FILE" --repo "$WORKSPACE_ROOT")
  [ -n "$SETTLE_BASE" ] && VERIFY_CMD+=(--base "$SETTLE_BASE")
  [ -n "$JUDGE" ] && VERIFY_CMD+=(--judge "$JUDGE")
  V_RC=0
  case "$VERIFIER" in
    *.py) V_OUT="$(cd "$WORKSPACE_ROOT" && python3 "$VERIFIER" "${VERIFY_CMD[@]}" 2>&1)" || V_RC=$? ;;
    *)    V_OUT="$(cd "$WORKSPACE_ROOT" && bash "$VERIFIER" "${VERIFY_CMD[@]}" 2>&1)" || V_RC=$? ;;
  esac
  printf '%s\n' "$V_OUT"
  case "$V_OUT" in
    *CHECK_VERIFY=UPHELD*)      : ;;
    *CHECK_VERIFY=UNAVAILABLE*) : ;;
    *CHECK_VERIFY=REFUTED*)
      write_handoff "tier-2 refuted the work — the eval is green but the diff does not satisfy the intent"
      land BLOCKED 1 "tier-2 REFUTED: a green eval is necessary, not sufficient. Read the findings above." ;;
    *)
      write_handoff "tier-2 verification could not produce a verdict"
      land BLOCKED 1 "tier-2 returned no usable verdict (rc=$V_RC) — a verdict that cannot be obtained is never a pass." ;;
  esac
fi

# --------------------------------------------------------------------------
# Green, and independently upheld. Settlement is a separate effect with its own
# policy gate (WP4).
# --------------------------------------------------------------------------
printf '\n── settlement ──\n'
SETTLE_ARGS=(--issue "$TASK_FILE" --tasks-dir "$RESOLVED_TASKS_DIR" --agent "$AGENT")
[ "$ALLOW_EXTERNAL" = true ] && SETTLE_ARGS+=(--allow-external-writes)
[ -n "$SETTLE_BASE" ] && SETTLE_ARGS+=(--base "$SETTLE_BASE")
[ -n "$LOOP_BASE_BRANCH" ] && SETTLE_ARGS+=(--pr-base "$LOOP_BASE_BRANCH")
[ -n "$CONTRACT" ] && SETTLE_ARGS+=(--contract "$CONTRACT")
[ -n "$ATTEMPT_HANDOFF" ] && SETTLE_ARGS+=(--handoff "$ATTEMPT_HANDOFF")
[ "$LEGACY_NO_CONTRACT" = true ] && SETTLE_ARGS+=(--legacy-no-contract)
SETTLE_RC=0
SETTLE_OUT="$(cd "$WORKSPACE_ROOT" && bash "$SETTLER" "${SETTLE_ARGS[@]}" 2>&1)" || SETTLE_RC=$?
printf '%s\n' "$SETTLE_OUT"

case "$SETTLE_OUT" in
  *TASK_LOOP=SETTLED*)       land SETTLED 0 "" ;;
  *TASK_LOOP=LOCAL_SETTLED*) land LOCAL_SETTLED 0 "" ;;
esac
[ "$SETTLE_RC" -eq 0 ] && land SETTLED 0 ""
land BLOCKED 1 "the eval went green but settlement refused — read the guard verdict above"
