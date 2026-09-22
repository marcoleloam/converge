#!/usr/bin/env bash
# run-issue-eval.sh — resolve --issue N to its task-spec and run THAT task's own eval.
#
# This is the GATE of Pass 8 (The Loop). It takes ONE issue, finds the matching
# tasks/T-*.md, extracts the Success Criteria eval bodies + the Exit Check, runs
# each in an isolated `set -euo pipefail` subshell, and prints:
#   GREEN  — the Exit Check exited 0 (all evals passed)
#   RED    — the Exit Check exited non-zero (with the failing eval's output)
#
# It never picks the task — --issue N is required and comes from outside.
#
# Usage:
#   bash run-issue-eval.sh --issue <id|slug|path> [--tasks-dir DIR] [--quiet]
#                          [--contract PROFILE] [--legacy-no-contract]
#
# Resolution of --issue accepts, in order:
#   1. an exact path to a T-*.md file
#   2. a full task id            (T-20260625-bronze-views)
#   3. a bare slug / tail        (bronze-views  →  T-*-bronze-views.md)
#   4. a tracker ref             (matches linear_ref: / tracker_issue: N)
#
# Delegation: evaluation is owned by the independently installed Task-Spec
# engine. Converge resolves the task and workspace, then calls its public
# `taskspec run` surface. There is deliberately no embedded evaluator fallback:
# two implementations would create two meanings of the same sealed task.
#
# Exit codes:
#   0 — GREEN  (Exit Check exited 0)
#   1 — RED    (Exit Check exited non-zero)
#   2 — could not resolve / read the issue (a usage or upstream-gap error)
#
# bash-3.2-safe (macOS system bash): no mapfile, no `declare -A`, awk/grep/sed only.

set -euo pipefail

# ----- Resolve this script's dir + the skill root -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----- Error helper (mirrors the task-spec skill's ts_die style) -----
err() {
  echo "ERROR: $*" >&2
  exit 2
}

# ----- Args -----
ISSUE=""
TASKS_DIR=""
QUIET=false
CONTRACT=""
LEGACY_NO_CONTRACT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] || err "--issue requires a value"
      ISSUE="$2"; shift 2 ;;
    --issue=*)
      ISSUE="${1#--issue=}"; shift ;;
    --tasks-dir)
      [ $# -ge 2 ] || err "--tasks-dir requires a value"
      TASKS_DIR="$2"; shift 2 ;;
    --tasks-dir=*)
      TASKS_DIR="${1#--tasks-dir=}"; shift ;;
    --quiet|-q)
      QUIET=true; shift ;;
    --contract)
      [ $# -ge 2 ] || err "--contract requires a value"
      CONTRACT="$2"; shift 2 ;;
    --contract=*)
      CONTRACT="${1#--contract=}"; shift ;;
    --legacy-no-contract)
      LEGACY_NO_CONTRACT=true; shift ;;
    --help|-h)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      err "unknown argument: $1 (usage: run-issue-eval.sh --issue <id>)" ;;
  esac
done

# The loop NEVER picks the task — absence of --issue is an error, not triage.
if [ -z "$ISSUE" ]; then
  err "--issue N is required. This loop never picks a task; a human or CI passes the issue. (Choosing which issue to run is the future CI/CD Manager's job.)"
fi

# ----- Locate the repo root + tasks dir -----
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$GIT_ROOT" ]; then
  GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
fi
[ -n "$GIT_ROOT" ] || err "not inside a git repository"

if [ -z "$TASKS_DIR" ]; then
  # Same discovery order as the rest of the task family: an explicit env wins,
  # then the cvg/ workspace layout, then the bare one.
  if [ -n "${TASKSPEC_BACKLOG_DIR:-}" ]; then
    TASKS_DIR="$TASKSPEC_BACKLOG_DIR"
  elif [ -d "$PWD/cvg/tasks" ]; then
    TASKS_DIR="cvg/tasks"
  else
    TASKS_DIR="tasks"
  fi
fi
# Resolve a relative dir against the INVOCATION directory first, and only then
# against the repo root. A workspace nested inside a larger repo (a proving
# ground, a monorepo package) keeps its specs at <workspace>/cvg/tasks, and
# anchoring straight to the git root makes the loop look for them in the parent
# repo — where they have never been.
case "$TASKS_DIR" in
  /*) : ;;
  *)
    if [ -d "$PWD/$TASKS_DIR" ]; then
      TASKS_DIR="$PWD/$TASKS_DIR"
    else
      TASKS_DIR="$GIT_ROOT/$TASKS_DIR"
    fi
    ;;
esac

# The WORKSPACE is the parent of the tasks dir, and it is the only directory an
# eval's relative paths can sensibly be resolved against — a spec that creates
# `cvg/capture/orders.py` means relative to its own workspace, not to whatever
# repo happens to contain it.
# THE WORKSPACE IS THE ANCESTOR THAT CONTAINS `cvg/`.
#
# This used to be "the parent of the tasks dir, and strip one more level if it is
# named cvg". That is only correct while specs live at exactly <ws>/cvg/tasks. A
# spec that FINISHES moves to <ws>/cvg/tasks/done, and then the parent is
# `cvg/tasks`, whose basename is not `cvg`, so nothing was stripped and the
# workspace resolved to `<ws>/cvg/tasks`. Every eval's relative path
# (`cvg/capture/pipelines/x.py`) then missed and the Exit Check failed in 0s —
# so a completed task could no longer pass its own evals, and `cvg tasks accept`
# rejected work that was demonstrably done.
#
# Walking up to the `cvg` component instead is correct for tasks/, tasks/done/,
# tasks/archive/ and any future nesting, because it asks the structural question
# ("where does the workspace begin?") rather than counting levels.
#
# This is the sixth symptom of one root cause: every gate deriving its own answer
# to "where is the workspace / what did this run change". The durable fix is a
# single shared resolver; this makes the most-used derivation correct first.
_resolve_workspace_root() {  # _resolve_workspace_root <tasks-dir>
  _rw_d="$1"
  while [ "$_rw_d" != "/" ] && [ -n "$_rw_d" ] && [ "$_rw_d" != "." ]; do
    if [ "$(basename "$_rw_d")" = "cvg" ]; then
      dirname "$_rw_d"; return 0
    fi
    _rw_next="$(dirname "$_rw_d")"
    [ "$_rw_next" = "$_rw_d" ] && break
    _rw_d="$_rw_next"
  done
  # Flat layout (tasks/ with no cvg/ ancestor): the parent is the workspace.
  dirname "$1"
}
WORKSPACE_ROOT="$(_resolve_workspace_root "$TASKS_DIR")"
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
export TASKSPEC_WORKSPACE_ROOT="$(physical_dir "$WORKSPACE_ROOT")"
export TASKSPEC_BACKLOG_DIR="$(physical_dir "$TASKS_DIR")"

# ----- Resolve --issue to a task-spec file -----
# Portable, bash-3.2-safe: no arrays required for the happy paths.
resolve_task_file() {
  _issue="$1"

  # (1) exact path to a file
  if [ -f "$_issue" ]; then
    echo "$(cd "$(dirname "$_issue")" && pwd)/$(basename "$_issue")"
    return 0
  fi

  if [ ! -d "$TASKS_DIR" ]; then
    return 1
  fi

  # (2) full id → TASKS_DIR/<id>.md
  if [ -f "$TASKS_DIR/$_issue.md" ]; then
    echo "$TASKS_DIR/$_issue.md"; return 0
  fi
  # id already carrying .md
  if [ -f "$TASKS_DIR/$_issue" ]; then
    echo "$TASKS_DIR/$_issue"; return 0
  fi

  # (3) bare slug / tail → the unique T-*-<slug>.md
  _hit=""
  _count=0
  for _f in "$TASKS_DIR"/T-*"$_issue"*.md; do
    [ -f "$_f" ] || continue
    _hit="$_f"
    _count=$((_count + 1))
  done
  if [ "$_count" -eq 1 ]; then
    echo "$_hit"; return 0
  fi
  if [ "$_count" -gt 1 ]; then
    echo "AMBIGUOUS" >&2
    for _f in "$TASKS_DIR"/T-*"$_issue"*.md; do
      [ -f "$_f" ] && echo "  - $_f" >&2
    done
    return 2
  fi

  # (4) tracker ref → a task whose linear_ref:/tracker_issue: frontmatter matches.
  # Match the value as a whole token so `12` does not match `123`.
  for _f in "$TASKS_DIR"/T-*.md; do
    [ -f "$_f" ] || continue
    _fm="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$_f")"
    if printf '%s\n' "$_fm" \
      | grep -Eiq "^[[:space:]]*(tracker_issue|linear_ref)[[:space:]]*:[[:space:]]*#?${_issue}([[:space:]]|\$|,|\])"; then
      echo "$_f"; return 0
    fi
  done

  return 1
}

set +e
TASK_FILE="$(resolve_task_file "$ISSUE")"
RESOLVE_RC=$?
set -e

if [ "$RESOLVE_RC" -eq 2 ]; then
  err "issue '$ISSUE' is ambiguous — it matches more than one task-spec (see list above). Pass the full task id."
fi
if [ "$RESOLVE_RC" -ne 0 ] || [ -z "${TASK_FILE:-}" ] || [ ! -f "$TASK_FILE" ]; then
  # Degrade gracefully: say plainly there is no such task-spec, and show what IS here.
  echo "RED"
  echo "issue: $ISSUE"
  echo "reason: could not resolve --issue '$ISSUE' to a task-spec under $TASKS_DIR"
  if [ -d "$TASKS_DIR" ]; then
    _avail="$(ls "$TASKS_DIR"/T-*.md 2>/dev/null | sed "s#^$TASKS_DIR/##;s#\.md\$##" || true)"
    if [ -n "$_avail" ]; then
      echo "available task ids:"
      printf '%s\n' "$_avail" | sed 's/^/  - /'
    else
      echo "note: no tasks/T-*.md files exist yet (upstream Pass 5B has not produced any)."
    fi
  else
    echo "note: tasks dir '$TASKS_DIR' does not exist yet (upstream Pass 5B has not run)."
  fi
  echo "This loop never picks a task — pass an --issue that resolves to a real tasks/T-*.md."
  exit 2
fi

TASK_ID="$(basename "$TASK_FILE" .md)"

# ----- Pass 6 runtime contract -----
# New executions fail closed when the task is not bound. The explicit legacy
# escape hatch exists only for migration and keeps the old behavior visible.
if [ "$LEGACY_NO_CONTRACT" != true ]; then
  # The contract is a workspace artifact — `cvg bind` writes it next to the
  # specs, not at the git root.
  [ -n "$CONTRACT" ] || CONTRACT="$WORKSPACE_ROOT/cvg/execution/$TASK_ID/execution-profile.yaml"
  case "$CONTRACT" in /*) : ;; *) CONTRACT="$WORKSPACE_ROOT/$CONTRACT" ;; esac
  if [ ! -f "$CONTRACT" ]; then
    echo "RED"
    echo "issue: $ISSUE"
    echo "reason: Pass 6 runtime contract is missing: $CONTRACT"
    echo "next: cvg bind --task ${TASK_FILE#"$WORKSPACE_ROOT"/}"
    exit 2
  fi
  CONTRACT_CHECKER="$SCRIPT_DIR/../../task-to-runtime-contract/scripts/check-runtime-contract.py"
  if [ ! -f "$CONTRACT_CHECKER" ]; then
    err "runtime-contract checker is missing: $CONTRACT_CHECKER"
  fi
  CONTRACT_TOOL_HOME="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  set +e
  CONTRACT_OUT="$(python3 "$CONTRACT_CHECKER" \
    --profile "$CONTRACT" \
    --repo "$WORKSPACE_ROOT" \
    --tool-home "$CONTRACT_TOOL_HOME" 2>&1)"
  CONTRACT_RC=$?
  set -e
  if [ "$CONTRACT_RC" -ne 0 ]; then
    printf '%s\n' "$CONTRACT_OUT"
    echo "RED"
    echo "issue: $ISSUE"
    echo "reason: Pass 6 runtime contract is stale or invalid"
    exit 2
  fi
  if [ "$QUIET" != true ]; then
    printf '%s\n' "$CONTRACT_OUT"
  fi
else
  echo "WARN: --legacy-no-contract bypasses Pass 6 · Bind; supervised migration only." >&2
fi

# ----- Read a couple of frontmatter facts for the report header -----
fm_value() {
  # $1 = key. Prints the first frontmatter value (trimmed), or empty.
  # `|| true` so a missing key (grep -> 1 under pipefail) is not a failure.
  { awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$TASK_FILE" \
    | grep -Ei "^[[:space:]]*$1[[:space:]]*:" \
    | head -1 \
    | sed -E "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//'; } || true
}

TASK_TITLE="$(fm_value title)"
TASK_SIGNED="$(fm_value signed_off)"

if [ "$QUIET" != true ]; then
  echo "issue:  $ISSUE"
  echo "task:   $TASK_ID"
  [ -n "$TASK_TITLE" ] && echo "title:  $TASK_TITLE"
  echo "spec:   $TASK_FILE"
  echo "----------------------------------------------------------------------"
fi

# A signed_off:false spec is an upstream gap (Pass 5B gate not passed). We still
# RUN the eval (so RED is real), but we surface the warning so the caller knows.
if [ -n "$TASK_SIGNED" ] && printf '%s' "$TASK_SIGNED" | grep -qi '^false'; then
  echo "WARN: this task-spec is signed_off: false — running its eval anyway, but a" >&2
  echo "      PR should not be opened until Pass 5B signs it off." >&2
fi

# ----- Run the eval through the standalone Task-Spec engine -----
TASKSPEC_ENGINE="${CVG_TASKSPEC_BIN:-${TASKSPEC_BIN:-taskspec}}"
command -v "$TASKSPEC_ENGINE" >/dev/null 2>&1 \
  || err "Task-Spec engine is unavailable: $TASKSPEC_ENGINE (requires taskspec 3.8.x or 3.9.x)"
EVAL_OUT=""
EVAL_RC=0
set +e
EVAL_OUT="$(
  cd "$WORKSPACE_ROOT" &&
    "$TASKSPEC_ENGINE" run "$TASK_FILE" < /dev/null 2>&1
)"
EVAL_RC=$?
set -e

# ----- Verdict -----
if [ "$EVAL_RC" -eq 0 ]; then
  [ "$QUIET" != true ] && printf '%s\n' "$EVAL_OUT"
  echo "----------------------------------------------------------------------"
  echo "GREEN"
  echo "issue: $ISSUE  task: $TASK_ID"
  echo "The task's own eval (Exit Check) exited 0. This issue has converged."
  exit 0
else
  printf '%s\n' "$EVAL_OUT"
  echo "----------------------------------------------------------------------"
  echo "RED"
  echo "issue: $ISSUE  task: $TASK_ID"
  echo "The task's own eval exited non-zero. Do NOT open a PR."
  echo "Feed the failing output above back to --agent and revise inside touches_paths,"
  echo "or (if the budget is exhausted / it is an upstream gap) emit a blocked-task report:"
  echo "  .claude/skills/task-loop/references/blocked-task-report.md"
  exit 1
fi
