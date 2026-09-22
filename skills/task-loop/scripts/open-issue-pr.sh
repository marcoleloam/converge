#!/usr/bin/env bash
# open-issue-pr.sh — settle ONE issue: on GREEN open a PR that closes it; on RED
# emit the blocked-task report instead.
#
# This is Step 4 (SETTLE) of Pass 8. It runs the task's own eval via
# run-issue-eval.sh and branches on the verdict:
#
#   GREEN → ensure a `task/<id>-<slug>` branch, commit the working tree, push,
#           and open a PR (via gh) that Closes #<issue> with the green eval
#           output embedded in the body.
#   RED   → do NOT open a PR. Render the blocked-task report
#           (references/blocked-task-report.md) filled with the failing eval,
#           the last output, and the suspected upstream gap.
#
# Every gh / git-push / git-commit side effect is guarded by --dry-run so the
# script runs fully offline: it prints exactly what it WOULD do and stops before
# any network or history mutation.
#
# Usage:
#   bash open-issue-pr.sh --issue <id|slug|path> [--dry-run] [--base COMMIT]
#                         [--pr-base BRANCH]
#                         [--agent claude|codex|kimi|omp] [--tasks-dir DIR]
#                         [--contract PROFILE] [--handoff TaskHandoff/v3]
#                         [--legacy-no-contract]
#
# Exit codes:
#   0 — GREEN and the PR was opened (or, with --dry-run, would be)
#   1 — RED: a blocked-task report was emitted (no PR)
#   2 — could not resolve the issue / not a git repo / usage error
#
# bash-3.2-safe: no mapfile, no `declare -A`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_RUNNER="$SCRIPT_DIR/run-issue-eval.sh"
REPORT_TMPL="$SCRIPT_DIR/../references/blocked-task-report.md"

err() {
  echo "ERROR: $*" >&2
  exit 2
}

# ----- Args -----
ISSUE=""
DRY_RUN=false
# BASE is the DIFF reference (a commit — "what did this run change?").
# PR_BASE is the MERGE target (a branch — "where should this land?").
# They are not interchangeable; see the note at the GREEN PATH guard.
BASE=""
PR_BASE=""
AGENT="claude"
TASKS_DIR=""
CONTRACT=""
HANDOFF=""
LEGACY_NO_CONTRACT=false
ALLOW_EXTERNAL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)     [ $# -ge 2 ] || err "--issue requires a value"; ISSUE="$2"; shift 2 ;;
    --issue=*)   ISSUE="${1#--issue=}"; shift ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    --base)      [ $# -ge 2 ] || err "--base requires a value"; BASE="$2"; shift 2 ;;
    --base=*)    BASE="${1#--base=}"; shift ;;
    --pr-base)   [ $# -ge 2 ] || err "--pr-base requires a value"; PR_BASE="$2"; shift 2 ;;
    --pr-base=*) PR_BASE="${1#--pr-base=}"; shift ;;
    --agent)     [ $# -ge 2 ] || err "--agent requires a value"; AGENT="$2"; shift 2 ;;
    --agent=*)   AGENT="${1#--agent=}"; shift ;;
    --tasks-dir) [ $# -ge 2 ] || err "--tasks-dir requires a value"; TASKS_DIR="$2"; shift 2 ;;
    --tasks-dir=*) TASKS_DIR="${1#--tasks-dir=}"; shift ;;
    --contract)   [ $# -ge 2 ] || err "--contract requires a value"; CONTRACT="$2"; shift 2 ;;
    --contract=*) CONTRACT="${1#--contract=}"; shift ;;
    --handoff)    [ $# -ge 2 ] || err "--handoff requires a value"; HANDOFF="$2"; shift 2 ;;
    --handoff=*)  HANDOFF="${1#--handoff=}"; shift ;;
    --legacy-no-contract) LEGACY_NO_CONTRACT=true; shift ;;
    --allow-external-writes) ALLOW_EXTERNAL=true; shift ;;
    --help|-h)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           err "unknown argument: $1" ;;
  esac
done

[ -n "$ISSUE" ] || err "--issue N is required. This loop never picks a task."

# ----- Repo root and WORKSPACE -----
# These are not the same thing. Git operations (branch, commit, push) are
# repo-level; paths — the spec, the contract, the fs.write scope, the eval's
# own relative references — are WORKSPACE-level. A workspace nested inside a
# larger repo makes the difference load-bearing, and cd-ing to the git root
# silently reinterprets every one of those paths against the wrong directory.
INVOCATION_DIR="$PWD"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$GIT_ROOT" ] || err "not inside a git repository"

if [ -z "$TASKS_DIR" ]; then
  if [ -n "${TASKSPEC_BACKLOG_DIR:-}" ]; then
    TASKS_DIR="$TASKSPEC_BACKLOG_DIR"
  elif [ -d "$INVOCATION_DIR/cvg/tasks" ]; then
    TASKS_DIR="cvg/tasks"
  else
    TASKS_DIR="tasks"
  fi
fi
case "$TASKS_DIR" in
  /*) RESOLVED_TASKS_DIR="$TASKS_DIR" ;;
  *)  if [ -d "$INVOCATION_DIR/$TASKS_DIR" ]; then
        RESOLVED_TASKS_DIR="$INVOCATION_DIR/$TASKS_DIR"
      else
        RESOLVED_TASKS_DIR="$GIT_ROOT/$TASKS_DIR"
      fi ;;
esac
WORKSPACE_ROOT="$(dirname "$RESOLVED_TASKS_DIR")"
# In the cvg/ layout specs live at <workspace>/cvg/tasks, so the parent of the
# tasks dir is `cvg` — one level short of the workspace.
if [ "$(basename "$WORKSPACE_ROOT")" = "cvg" ]; then
  WORKSPACE_ROOT="$(dirname "$WORKSPACE_ROOT")"
fi
[ -d "$WORKSPACE_ROOT" ] || WORKSPACE_ROOT="$GIT_ROOT"
cd "$WORKSPACE_ROOT"
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
export TASKSPEC_BACKLOG_DIR="$(physical_dir "${TASKSPEC_BACKLOG_DIR:-$RESOLVED_TASKS_DIR}")"
export TASKSPEC_WORKSPACE_ROOT="$(physical_dir "${TASKSPEC_WORKSPACE_ROOT:-$WORKSPACE_ROOT}")"
export TASKSPEC_ACCEPTANCE_DIR="$(physical_dir "${TASKSPEC_ACCEPTANCE_DIR:-$(dirname "$RESOLVED_TASKS_DIR")/.taskspec/acceptance}")"

# ----- Run the gate first (RED/GREEN decides everything below) -----
EVAL_ARGS=(--issue "$ISSUE")
[ -n "$TASKS_DIR" ] && EVAL_ARGS+=(--tasks-dir "$TASKS_DIR")
[ -n "$CONTRACT" ] && EVAL_ARGS+=(--contract "$CONTRACT")
[ "$LEGACY_NO_CONTRACT" = true ] && EVAL_ARGS+=(--legacy-no-contract)

set +e
EVAL_OUT="$(bash "$EVAL_RUNNER" "${EVAL_ARGS[@]}" 2>&1)"
EVAL_RC=$?
set -e

# rc 2 = could not resolve the issue at all — pass that through as-is.
if [ "$EVAL_RC" -eq 2 ]; then
  printf '%s\n' "$EVAL_OUT"
  exit 2
fi

# Resolve the task file + id/slug again here so the branch name is derived from
# the real spec (single source of truth), independent of how --issue was typed.
resolve_task_file() {
  _issue="$1"
  if [ -f "$_issue" ]; then echo "$(cd "$(dirname "$_issue")" && pwd)/$(basename "$_issue")"; return 0; fi
  _td="$RESOLVED_TASKS_DIR"
  [ -d "$_td" ] || return 1
  [ -f "$_td/$_issue.md" ] && { echo "$_td/$_issue.md"; return 0; }
  [ -f "$_td/$_issue" ] && { echo "$_td/$_issue"; return 0; }
  _hit=""; _count=0
  for _f in "$_td"/T-*"$_issue"*.md; do
    [ -f "$_f" ] || continue; _hit="$_f"; _count=$((_count + 1))
  done
  [ "$_count" -eq 1 ] && { echo "$_hit"; return 0; }
  for _f in "$_td"/T-*.md; do
    [ -f "$_f" ] || continue
    _fm="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$_f")"
    printf '%s\n' "$_fm" \
      | grep -Eiq "^[[:space:]]*(tracker_issue|linear_ref)[[:space:]]*:[[:space:]]*#?${_issue}([[:space:]]|\$|,|\])" \
      && { echo "$_f"; return 0; }
  done
  return 1
}

set +e
TASK_FILE="$(resolve_task_file "$ISSUE")"
set -e
[ -n "${TASK_FILE:-}" ] && [ -f "$TASK_FILE" ] || err "could not resolve --issue '$ISSUE' to a task-spec"

TASK_ID="$(basename "$TASK_FILE" .md)"
PATH_POLICY_STATE="not-run"
[ -n "$CONTRACT" ] || CONTRACT="$WORKSPACE_ROOT/cvg/execution/$TASK_ID/execution-profile.yaml"
case "$CONTRACT" in /*) : ;; *) CONTRACT="$WORKSPACE_ROOT/$CONTRACT" ;; esac

# ----- Portable settlement guard -----
# A green eval cannot settle a forbidden diff. A bound run enforces both the
# standing repository gate and Task-Spec scope; supervised legacy mode lacks the
# latter but MUST still honor the repository gate.
if [ "$EVAL_RC" -eq 0 ]; then
  PATH_GUARD="$SCRIPT_DIR/../../task-to-runtime-contract/scripts/check-path-policy.py"
  if [ "$LEGACY_NO_CONTRACT" = true ]; then
    PATH_ARGS=(--gate-only --repo "$WORKSPACE_ROOT")
  else
    PATH_ARGS=(--profile "$CONTRACT" --repo "$WORKSPACE_ROOT")
  fi
  # Which reference does "what this run changed" mean?
  #
  # Guessing the default branch here was a real defect, not a rough edge.
  # `<base>...HEAD` is merge-base-relative, so on a branch cut from a FEATURE
  # branch the merge-base with `main` sits at the point that feature branch
  # diverged — and every commit on it lands in the diff. The first real run put
  # 135 workspace paths in front of a guard authorized for 4, and settlement was
  # refused on work that was entirely in scope.
  #
  # So: an explicit --base wins (the loop kernel always passes the exact commit
  # it forked from). Failing that, the branch's own upstream. Failing THAT we
  # compare nothing but the uncommitted work and say so out loud — a narrower
  # comparison is honest, whereas a wrong-but-wide one manufactures violations.
  POLICY_BASE="$BASE"
  if [ -z "$POLICY_BASE" ]; then
    POLICY_BASE="$(git rev-parse --quiet --verify '@{upstream}' 2>/dev/null || true)"
  fi
  if [ -n "$POLICY_BASE" ]; then
    PATH_ARGS+=(--base "$POLICY_BASE")
  else
    echo "note: no --base and no upstream — the guard compares uncommitted work only."
  fi
  set +e
  PATH_OUT="$(python3 "$PATH_GUARD" "${PATH_ARGS[@]}" 2>&1)"
  PATH_RC=$?
  set -e
  if [ "$PATH_RC" -ne 0 ]; then
    PATH_POLICY_STATE="fail"
    EVAL_RC=1
    EVAL_OUT="${EVAL_OUT}

${PATH_OUT}
RED — green eval rejected by the settlement path policy."
  else
    PATH_POLICY_STATE="pass"
    EVAL_OUT="${EVAL_OUT}

${PATH_OUT}"
    # Always surface the guard's verdict. It used to reach the operator only via
    # the PR body, so a run that settled locally hid whether the gate had passed.
    printf '%s\n' "$PATH_OUT"
  fi
fi

fm_value() {
  # Never fail the pipeline: a missing key is normal (grep -> 1 under pipefail).
  { awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$TASK_FILE" \
    | grep -Ei "^[[:space:]]*$1[[:space:]]*:" \
    | head -1 \
    | sed -E "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//'; } || true
}

# slug = the task id with a leading T-<date>- prefix stripped, else a sanitized id.
SLUG="$(printf '%s' "$TASK_ID" | sed -E 's/^T-[0-9]+-//')"
[ -n "$SLUG" ] && [ "$SLUG" != "$TASK_ID" ] || \
  SLUG="$(printf '%s' "$TASK_ID" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
BRANCH="task/$SLUG"

# ----- Structured execution receipt (WP4: BLOCKED path only) -----
# A SUCCESS receipt must not be written before the outcome it reports is known.
# Previously this ran here, ahead of branch/commit/push/PR, so a receipt could
# claim settlement that never happened. The blocked receipt still belongs here —
# a red run settles nothing, so there is nothing left to learn.
write_receipt() {  # write_receipt <result>
  local result="$1"
  [ "$LEGACY_NO_CONTRACT" = true ] && return 0
  [ "$DRY_RUN" = true ] && return 0
  local RECEIPT_WRITER RECEIPT_RESULT EVAL_TMP RECEIPT_OUT RECEIPT_RC
  RECEIPT_WRITER="$SCRIPT_DIR/../../task-to-runtime-contract/scripts/write-execution-receipt.py"
  RECEIPT_RESULT="$result"
  EVAL_TMP="$(mktemp -t cvg-eval-output.XXXXXX)"
  printf '%s\n' "$EVAL_OUT" > "$EVAL_TMP"
  set +e
  RECEIPT_OUT="$(python3 "$RECEIPT_WRITER" \
    --profile "$CONTRACT" \
    --repo "$WORKSPACE_ROOT" \
    --result "$RECEIPT_RESULT" \
    --eval-output "$EVAL_TMP" \
    --path-policy "$PATH_POLICY_STATE" \
    --agent "$AGENT" \
    --branch "$BRANCH" 2>&1)"
  RECEIPT_RC=$?
  set -e
  unlink "$EVAL_TMP"
  if [ "$RECEIPT_RC" -ne 0 ]; then
    printf '%s\n' "$RECEIPT_OUT"
    echo "RED — execution receipt could not be written."
    return 1
  fi
  printf '%s\n' "$RECEIPT_OUT"
  return 0
}

# A red run settles nothing: write the blocked receipt now and stop.
if [ "$EVAL_RC" -ne 0 ]; then
  write_receipt blocked || true
fi

# tracker issue number for the "Closes #N" line (linear_ref/tracker_issue).
TRACKER="$(fm_value tracker_issue)"
[ -z "$TRACKER" ] && TRACKER="$(fm_value linear_ref)"
# strip a leading '#'; treat the placeholder "(none)" as empty.
TRACKER="$(printf '%s' "$TRACKER" | sed -E 's/^#//')"
case "$TRACKER" in "(none)"|"none"|"") TRACKER="" ;; esac

# ----- run-cmd: echo under --dry-run, execute otherwise -----
run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would run: $*"
  else
    "$@"
  fi
}

# ============================ RED PATH ============================
if [ "$EVAL_RC" -ne 0 ]; then
  echo "RED — issue '$ISSUE' ($TASK_ID) did not converge. No PR."
  echo "Emitting the blocked-task report."
  echo "======================================================================"

  # Pull the last chunk of eval output as the "last output" evidence block.
  LAST_OUT="$(printf '%s\n' "$EVAL_OUT" | tail -n 40)"

  if [ -f "$REPORT_TMPL" ]; then
    # Render the template with the concrete facts substituted for its <...>
    # placeholders; leave the analysis prose for the agent to complete.
    sed \
      -e "s#<issue-id>#${ISSUE}#g" \
      -e "s#<task-id>#${TASK_ID}#g" \
      -e "s#<branch>#${BRANCH}#g" \
      -e "s#<agent>#${AGENT}#g" \
      "$REPORT_TMPL"
    echo
    echo "----- filled from this run -----"
  else
    echo "(blocked-task-report.md template not found at $REPORT_TMPL — emitting raw report)"
  fi

  echo "# Blocked Task Report"
  echo
  echo "- issue: ${ISSUE}"
  echo "- task-spec: ${TASK_FILE}"
  echo "- branch (intended): ${BRANCH}"
  echo "- agent: ${AGENT}"
  echo
  echo "## Failing eval (last output)"
  echo '```'
  printf '%s\n' "$LAST_OUT"
  echo '```'
  echo
  echo "## Suspected upstream gap"
  echo "- (fill in) Which decision/ADR/plan/runtime binding is missing or wrong upstream, and which Converge pass owns the fix (Pass 2 ADR, Pass 3 plan, Pass 5B task-spec, Pass 6 Bind)."
  echo
  echo "Do not open a PR. Do not hack the eval. Surface this report."
  exit 1
fi

# ============================ GREEN PATH ============================
echo "GREEN — issue '$ISSUE' ($TASK_ID) converged. Opening a PR."
echo "======================================================================"

# --- guard: never work off main directly; ensure the task branch ---
#
# `--base` and the PR's base are TWO DIFFERENT QUESTIONS and must not share one
# value. The path guard above asks "what did this run change?" and needs an EXACT
# COMMIT, which is why the kernel passes the sha it forked from. `gh pr create
# --base` asks "which branch should this merge into?" and a sha is not a legal
# answer — GitHub rejects it with `Base ref must be a branch`, and confusingly
# also `No commits between <sha> and <branch>` even when the branch is one commit
# ahead. Reusing $BASE for both meant the FIRST live PR attempt failed on work
# that was green, committed and already pushed.
#
# So the PR base is resolved independently: --pr-base wins (the kernel passes the
# branch it forked from), then the repo's default branch, then whatever branch we
# are on — and a value that is not a branch is refused rather than sent.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
DEFAULT_BASE="$PR_BASE"
if [ -z "$DEFAULT_BASE" ] && [ -n "$BASE" ] \
   && git show-ref --verify --quiet "refs/heads/$BASE" 2>/dev/null; then
  # An explicit --base that genuinely names a branch is still a fine PR target.
  DEFAULT_BASE="$BASE"
fi
if [ -z "$DEFAULT_BASE" ]; then
  # Prefer the repo's real default branch; fall back to main/master/current.
  DEFAULT_BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  [ -z "$DEFAULT_BASE" ] && DEFAULT_BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "branch $BRANCH already exists — switching to it."
  run_cmd git checkout "$BRANCH"
elif [ "$CURRENT_BRANCH" = "$BRANCH" ]; then
  echo "already on $BRANCH."
else
  echo "cutting branch $BRANCH off $DEFAULT_BASE."
  run_cmd git checkout -b "$BRANCH"
fi

# --- stage ONLY the paths the contract authorized (WP4) ---
# `git add -A` staged the whole working tree. The postflight guard inspects the
# DIFF, which never shows untracked files — so a brand-new file outside the
# task's scope could ride into the commit unseen. Stage from the contract
# instead, then prove nothing unauthorized got staged.
COMMIT_TITLE="$TASK_ID: green eval"
COMMIT_BODY="Implements ${TASK_ID}. The task's own eval (Exit Check) exits 0."

AUTHORIZED_PATHS=()
if [ "$LEGACY_NO_CONTRACT" != true ] && [ -f "$CONTRACT" ]; then
  while IFS= read -r scoped; do
    [ -n "$scoped" ] && AUTHORIZED_PATHS+=("$scoped")
  done < <(python3 -c '
import json, sys
profile = json.load(open(sys.argv[1]))
grant = next((g for g in profile.get("authority", {}).get("grants", [])
              if g.get("capability") == "fs.write"), {})
for path in grant.get("scope", []):
    print(path)
' "$CONTRACT" 2>/dev/null || true)
fi

if [ "${#AUTHORIZED_PATHS[@]}" -eq 0 ]; then
  if [ "$LEGACY_NO_CONTRACT" = true ]; then
    echo "legacy mode: no contract to scope staging by — staging tracked changes only."
    run_cmd git add -u
  else
    err "the contract declares no writable scope; refusing to stage anything"
  fi
else
  echo "staging only the ${#AUTHORIZED_PATHS[@]} path(s) the contract authorizes."
  for scoped in "${AUTHORIZED_PATHS[@]}"; do
    # A declared path may legitimately not exist (nothing was created there).
    run_cmd git add -- "$scoped" 2>/dev/null || true
  done
fi

# Prove it: every staged path must be inside the authorized scope.
if [ "$DRY_RUN" != true ] && [ "$LEGACY_NO_CONTRACT" != true ]; then
  STAGED="$(git diff --cached --relative --name-only 2>/dev/null || true)"
  if [ -n "$STAGED" ]; then
    UNAUTHORIZED="$(printf '%s\n' "$STAGED" | python3 -c '
import sys, json
sys.path.insert(0, sys.argv[2])
from _runtime_contract import path_matches
scope = json.load(open(sys.argv[1]))
grant = next((g for g in scope.get("authority", {}).get("grants", [])
              if g.get("capability") == "fs.write"), {})
allowed = grant.get("scope", [])
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if line and not any(path_matches(line, rule) for rule in allowed):
        print(line)
' "$CONTRACT" "$SCRIPT_DIR/../../task-to-runtime-contract/scripts" 2>/dev/null || true)"
    if [ -n "$UNAUTHORIZED" ]; then
      echo "RED — refusing to commit: these staged paths are outside the contract:" >&2
      printf '  %s\n' $UNAUTHORIZED >&2
      git reset >/dev/null 2>&1 || true
      write_receipt blocked || true
      exit 1
    fi
  fi
fi

if [ "$DRY_RUN" = true ]; then
  echo "DRY-RUN would run: git commit -m \"$COMMIT_TITLE\" -m \"$COMMIT_BODY\""
elif [ -n "$(git diff --cached --name-only 2>/dev/null)" ]; then
  git commit -m "$COMMIT_TITLE" -m "$COMMIT_BODY"
else
  echo "nothing authorized to commit (assuming the branch already carries the work)."
fi

# --- protected settlement: independent Task-Spec acceptance before publishing ---
# The worker's green eval and Converge path guard are necessary but not final.
# Task-Spec re-runs the eval, binds the immutable base/attempt/closure, and writes
# AcceptanceRecord/v1. No push or PR is allowed before this succeeds.
if [ "$LEGACY_NO_CONTRACT" != true ]; then
  if [ "$DRY_RUN" = true ]; then
    HANDOFF_PREVIEW="${HANDOFF:-cvg/execution/$TASK_ID/task-handoff.json}"
    echo "DRY-RUN would run: taskspec accept --handoff $HANDOFF_PREVIEW --stamp --accepted-by converge-loop $TASK_FILE"
  else
    [ -n "$HANDOFF" ] && [ -f "$HANDOFF" ] || {
      echo "RED — protected settlement requires the dispatch TaskHandoff/v3." >&2
      write_receipt blocked || true
      exit 1
    }
    # This receipt records execution + path-policy proof. If independent
    # acceptance rejects, it is immediately superseded by a blocked receipt.
    write_receipt pass || {
      echo "RED — execution proof could not be persisted before acceptance." >&2
      exit 1
    }
    TASKSPEC_ENGINE="${CVG_TASKSPEC_BIN:-${TASKSPEC_BIN:-taskspec}}"
    set +e
    ACCEPT_OUT="$(
      cd "$WORKSPACE_ROOT" &&
        "$TASKSPEC_ENGINE" accept --handoff "$HANDOFF" --stamp \
          --acceptance-dir "$TASKSPEC_ACCEPTANCE_DIR" \
          --accepted-by converge-loop "$TASK_FILE" 2>&1
    )"
    ACCEPT_RC=$?
    set -e
    printf '%s\n' "$ACCEPT_OUT"
    if [ "$ACCEPT_RC" -ne 0 ] || ! printf '%s\n' "$ACCEPT_OUT" | grep -q '^ACCEPTED=1$'; then
      write_receipt blocked || true
      echo "RED — Task-Spec protected acceptance rejected the attempted settlement." >&2
      exit 1
    fi

    ATTEMPT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["attempt"]["id"])' "$HANDOFF")"
    ACCEPTANCE_RECORD="$TASKSPEC_ACCEPTANCE_DIR/$TASK_ID/$ATTEMPT_ID.json"
    [ -f "$ACCEPTANCE_RECORD" ] || {
      write_receipt blocked || true
      err "Task-Spec accepted without writing the expected AcceptanceRecord/v1"
    }
    git add -- "$TASK_FILE" "$ACCEPTANCE_RECORD"
    [ -f "$RESOLVED_TASKS_DIR/_metrics.jsonl" ] && git add -- "$RESOLVED_TASKS_DIR/_metrics.jsonl"
    git commit -m "$TASK_ID: protected acceptance" \
      -m "Task-Spec independently accepted attempt $ATTEMPT_ID before publication."
  fi
fi

# --- external writes are a SEPARATE, policy-governed effect (WP4) ---
# The profile denies external writes by default, yet settlement used to push and
# open a PR unconditionally — the artifact said one thing and the code did another.
EXTERNAL_POLICY="deny"
if [ "$LEGACY_NO_CONTRACT" != true ] && [ -f "$CONTRACT" ]; then
  EXTERNAL_POLICY="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("policy", {}).get("external_writes", "deny"))
' "$CONTRACT" 2>/dev/null || echo deny)"
fi
if [ "$EXTERNAL_POLICY" != "allow" ] && [ "$ALLOW_EXTERNAL" != true ]; then
  echo
  echo "SETTLED LOCALLY — the commit is on '$BRANCH'."
  echo "external_writes policy is '$EXTERNAL_POLICY', so push and PR were NOT performed."
  echo "Re-run with --allow-external-writes (or set the policy to allow) to publish."
  echo "TASK_LOOP=LOCAL_SETTLED"
  exit 0
fi

# --- push (authorized) ---
run_cmd git push -u origin "$BRANCH"

# --- assemble the PR body with the green eval embedded ---
CLOSES_LINE=""
if [ -n "$TRACKER" ]; then
  CLOSES_LINE="Closes #${TRACKER}"
fi

PR_BODY_FILE="$(mktemp)"
{
  echo "## What"
  echo "Implements \`${TASK_ID}\` on branch \`${BRANCH}\` (agent: ${AGENT})."
  [ -n "$CLOSES_LINE" ] && { echo; echo "$CLOSES_LINE"; }
  echo
  echo "## Gate — GREEN eval"
  echo "The task's own eval (Exit Check from the task-spec) was RUN, not eyeballed, and exits 0."
  echo
  echo '```'
  printf '%s\n' "$EVAL_OUT"
  echo '```'
  echo
  echo "## Scope"
  echo "Stayed inside the spec's \`touches_paths\`; honored \`do-not-touch\`."
  echo
  echo "Task-spec: \`${TASK_FILE}\`"
} > "$PR_BODY_FILE"

PR_TITLE="$TASK_ID"

if command -v gh >/dev/null 2>&1; then
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would run: gh pr create --base $DEFAULT_BASE --head $BRANCH --title \"$PR_TITLE\" --body-file <rendered>"
    echo "----- PR body preview -----"
    cat "$PR_BODY_FILE"
  else
    gh pr create --base "$DEFAULT_BASE" --head "$BRANCH" \
      --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
  fi
else
  echo "NOTE: gh CLI not found — cannot open the PR automatically."
  echo "Push is done; open the PR manually against $DEFAULT_BASE with this body:"
  echo "----- PR body -----"
  cat "$PR_BODY_FILE"
fi

rm -f "$PR_BODY_FILE"

# --- the success receipt, written LAST (WP4) ---
# Only now is the outcome it reports actually known: branch cut, authorized paths
# staged and committed, push and PR performed under an explicit policy.
# The passing execution receipt was persisted before independent acceptance;
# publication is an additional effect and never retroactively creates proof.

echo "======================================================================"
if [ "$DRY_RUN" = true ]; then
  echo "DRY-RUN complete — nothing was committed, pushed, or opened."
else
  echo "PR opened for $TASK_ID. Stop here — merge order is the future CI/CD Manager's job."
fi
echo "TASK_LOOP=SETTLED"
exit 0
