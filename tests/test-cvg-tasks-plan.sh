#!/usr/bin/env bash
# Prove `cvg tasks plan` is a byte-transparent Task-Spec delegation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CVG="$ROOT/bin/cvg"
ROOM="$(mktemp -d -t cvg-tasks-plan.XXXXXX)"
trap 'rm -rf "$ROOM"' EXIT
STUB="$ROOM/taskspec"
ARGS="$ROOM/args"

cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  printf '3.8.0\n'
  exit 0
fi
printf '%s\n' "$@" > "$TASKSPEC_STUB_ARGS"
printf 'TASK_PLAN=OK\n'
exit 0
STUB
chmod +x "$STUB"

OUT="$(
  cd "$ROOM" || exit 1
  CVG_HOME="$ROOT" CVG_PROJECT_ROOT="$ROOM" \
    CVG_TASKSPEC_BIN="$STUB" TASKSPEC_STUB_ARGS="$ARGS" \
    "$CVG" tasks plan --manifest seamwise/task-plan.json
)"
RC=$?

test "$RC" -eq 0
test "$OUT" = "TASK_PLAN=OK"
test "$(sed -n '1p' "$ARGS")" = "plan"
test "$(sed -n '2p' "$ARGS")" = "--manifest"
test "$(sed -n '3p' "$ARGS")" = "seamwise/task-plan.json"
test "$(wc -l < "$ARGS" | tr -d ' ')" -eq 3

if grep -R -n -E "cvg-plan-tasks|Yields at Pass 5B" "$ROOT/bin" "$ROOT/package.json" >/dev/null; then
  echo "Converge still packages an internal task planner" >&2
  echo "TASKS_PLAN_TESTS=FAIL"
  exit 1
fi

# 3.9.0 is accepted. 3.10.0 is not. On a macOS /tmp symlink, the engine must
# see the physical workspace so rebuild-state does not embed an absolute path.
VER39="$ROOM/taskspec39"
VER310="$ROOM/taskspec310"
ENVFILE="$ROOM/env"
cat > "$VER39" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  printf '3.9.0\n'
  exit 0
fi
if [ "${1:-}" = rebuild-state ]; then
  printf '%s\n' "$TASKSPEC_WORKSPACE_ROOT" > "$TASKSPEC_STUB_ENV"
  printf '%s\n' "$TASKSPEC_BACKLOG_DIR" >> "$TASKSPEC_STUB_ENV"
  exit 0
fi
printf 'unexpected %s\n' "$1" >&2
exit 9
STUB
cat > "$VER310" <<'STUB'
#!/usr/bin/env bash
printf '3.10.0\n'
exit 0
STUB
chmod +x "$VER39" "$VER310"

VER_OUT="$(
  cd "$ROOM" || exit 1
  CVG_HOME="$ROOT" CVG_PROJECT_ROOT="$ROOM" CVG_TASKSPEC_BIN="$VER39" \
    "$CVG" version
)"
printf '%s\n' "$VER_OUT" | grep -q 'task-spec 3.9.0'

set +e
CVG_HOME="$ROOT" CVG_PROJECT_ROOT="$ROOM" CVG_TASKSPEC_BIN="$VER310" \
  "$CVG" version >/dev/null 2>"$ROOM/rejected"
REJECT_RC=$?
set -e
test "$REJECT_RC" -eq 3
grep -q "requires 3.8.x or 3.9.x" "$ROOM/rejected"

LINK="/tmp/cvg-tasks-plan-$$"
rm -rf "$LINK"
mkdir -p "$LINK/cvg/tasks"
trap 'rm -rf "$ROOM" "$LINK"' EXIT
PHYS="$(cd "$LINK" && pwd -P)"
REBUILD_OUT="$(
  cd "$LINK" || exit 1
  CVG_HOME="$ROOT" CVG_PROJECT_ROOT="$LINK" CVG_TASKSPEC_BIN="$VER39" \
    TASKSPEC_STUB_ENV="$ENVFILE" \
    "$CVG" tasks rebuild-state
)"
test -z "$REBUILD_OUT"
test "$(sed -n '1p' "$ENVFILE")" = "$PHYS"
test "$(sed -n '2p' "$ENVFILE")" = "$PHYS/cvg/tasks"
case "$(sed -n '1p' "$ENVFILE")" in
  /*) ;;
  *) echo "workspace root handed to Task-Spec was not absolute physical" >&2; exit 1 ;;
esac

echo "TASKS_PLAN_TESTS=PASS"
