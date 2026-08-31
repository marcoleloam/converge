#!/usr/bin/env bash
# Deterministic three-engine composed demo in a fresh Git repository.
# The executor is a local fixture; Seamwise and Task-Spec are real binaries.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKSPEC_BIN="${CVG_TASKSPEC_BIN:-taskspec}"
SEAMWISE_BIN="${CVG_SEAMWISE_BIN:-seamwise}"
DEMO_AGENT="${COMPOSE_DEMO_AGENT:-deterministic}"
EXPECTED_TASKSPEC_COMMIT="0e6180cfc3009bd4ef9cf7ab050b463e10d4af91"
EXPECTED_SEAMWISE_COMMIT="5a398169c3fefcb65eb1a47c0cb4f967dfdc0515"
TASKSPEC_SOURCE_ROOT="${CVG_TASKSPEC_SOURCE_ROOT:-}"
SEAMWISE_SOURCE_ROOT="${CVG_SEAMWISE_SOURCE_ROOT:-}"
REQUIRE_ENGINE_PROVENANCE="${COMPOSE_DEMO_REQUIRE_ENGINE_PROVENANCE:-0}"
ROOM="$(mktemp -d -t cvg-composed-demo.XXXXXX)"
ENGINES="$(mktemp -d -t cvg-composed-engines.XXXXXX)"
if [ -n "${COMPOSE_DEMO_EVIDENCE_DIR:-}" ]; then
  EVIDENCE="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$COMPOSE_DEMO_EVIDENCE_DIR")"
  if [ -e "$EVIDENCE" ] && [ -n "$(find "$EVIDENCE" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    die_path="$EVIDENCE"
    printf 'DEMO_COMPOSED=BLOCKED reason=evidence_target_not_empty path=%s\n' "$die_path" >&2
    exit 1
  fi
  mkdir -p "$EVIDENCE"
  EVIDENCE_IS_OUTPUT=1
else
  EVIDENCE="$(mktemp -d -t cvg-composed-evidence.XXXXXX)"
  EVIDENCE_IS_OUTPUT=0
fi
SPEC_ID="T-20260815-health-status"
SPEC="cvg/tasks/$SPEC_ID.md"

cleanup() {
  if [ "${PRESERVE_COMPOSE_DEMO:-0}" = "1" ]; then
    printf 'DEMO_WORKSPACE=%s\n' "$ROOM"
    printf 'DEMO_EVIDENCE=%s\n' "$EVIDENCE"
    rm -rf "$ENGINES"
  else
    rm -rf "$ROOM" "$ENGINES"
    [ "$EVIDENCE_IS_OUTPUT" -eq 1 ] || rm -rf "$EVIDENCE"
  fi
}
trap cleanup EXIT

die() {
  printf 'DEMO_COMPOSED=BLOCKED reason=%s\n' "$1" >&2
  exit 1
}

need_token() {
  output="$1"
  token="$2"
  printf '%s\n' "$output" | grep -q "^${token}$" || die "missing_${token}"
}

command -v git >/dev/null 2>&1 || die git_unavailable
[ -x "$TASKSPEC_BIN" ] || command -v "$TASKSPEC_BIN" >/dev/null 2>&1 || die taskspec_unavailable
[ -x "$SEAMWISE_BIN" ] || command -v "$SEAMWISE_BIN" >/dev/null 2>&1 || die seamwise_unavailable

verify_engine_source() {
  engine_name="$1"
  source_root="$2"
  expected_commit="$3"
  if [ -z "$source_root" ]; then
    [ "$REQUIRE_ENGINE_PROVENANCE" = "0" ] || die "${engine_name}_source_root_missing"
    printf 'unverified'
    return
  fi
  git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${engine_name}_source_root_invalid"
  actual_commit="$(git -C "$source_root" rev-parse HEAD 2>/dev/null)" \
    || die "${engine_name}_source_commit_unavailable"
  [ "$actual_commit" = "$expected_commit" ] || die "${engine_name}_source_commit_mismatch"
  [ -z "$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)" ] \
    || die "${engine_name}_source_tree_dirty"
  printf '%s' "$actual_commit"
}

TASKSPEC_SOURCE_COMMIT="$(verify_engine_source taskspec "$TASKSPEC_SOURCE_ROOT" "$EXPECTED_TASKSPEC_COMMIT")" || exit 1
SEAMWISE_SOURCE_COMMIT="$(verify_engine_source seamwise "$SEAMWISE_SOURCE_ROOT" "$EXPECTED_SEAMWISE_COMMIT")" || exit 1

git -C "$ROOM" init --quiet
git -C "$ROOM" config user.name "Converge deterministic demo"
git -C "$ROOM" config user.email demo@example.invalid

INSTALL_OUT="$(bash "$ROOT/install.sh" --target "$ROOM" --bin-dir "$ROOM/bin" 2>&1)"
need_token "$INSTALL_OUT" "INSTALL=OK"

run_cvg() {
  (
    cd "$ROOM" || exit 1
    env -u CVG_HOME -u CVG_PROJECT_ROOT \
      CVG_TASKSPEC_BIN="$TASKSPEC_BIN" \
      CVG_SEAMWISE_BIN="$SEAMWISE_BIN" \
      CVG_ENGINES_DIR="${ACTIVE_ENGINES_DIR:-$ENGINES}" \
      "$ROOM/bin/cvg" "$@"
  )
}

run_taskspec() {
  (
    cd "$ROOM" || exit 1
    TASKSPEC_WORKSPACE_ROOT="$ROOM" \
      TASKSPEC_BACKLOG_DIR="$ROOM/cvg/tasks" \
      TASKSPEC_ACCEPTANCE_DIR="$ROOM/cvg/.taskspec/acceptance" \
      NO_COLOR=1 "$TASKSPEC_BIN" "$@"
  )
}

INIT_OUT="$(run_cvg init 2>&1)"
need_token "$INIT_OUT" "CVG_INIT=OK"
SIGNING_OUT="$(run_cvg setup signing 2>&1)"
need_token "$SIGNING_OUT" "SETUP_SIGNING=OK"

case "$DEMO_AGENT" in
  deterministic) ACTIVE_ENGINES_DIR="$ENGINES" ;;
  codex)
    command -v codex >/dev/null 2>&1 || die codex_unavailable
    codex login status 2>&1 | grep -q '^Logged in' || die codex_not_authenticated
    ACTIVE_ENGINES_DIR="$ROOM/.agents/skills/task-loop/scripts/engines"
    ;;
  *) die unsupported_demo_agent ;;
esac
export ACTIVE_ENGINES_DIR

cp "$ROOT/tests/fixtures/composed-health-recipe.yaml" "$ROOM/recipe.yaml"
printf '# composed health fixture\n' > "$ROOM/README.md"
git -C "$ROOM" add -A
git -C "$ROOM" commit --quiet -m "pin deterministic composed source"
SOURCE_COMMIT="$(git -C "$ROOM" rev-parse HEAD)"

PREPARE_OUT="$(run_cvg compose prepare --source recipe.yaml 2>&1)" || die prepare_failed
need_token "$PREPARE_OUT" "COMPOSE=NEEDS_REVIEW"
[ ! -e "$ROOM/seamwise/task-plan.json" ] || die prepare_crossed_review_boundary
printf '%s\n' "$PREPARE_OUT" > "$EVIDENCE/01-prepare.txt"

set +e
SKIP_OUT="$(run_cvg --json compose preview 2>&1)"
SKIP_RC=$?
set -e
[ "$SKIP_RC" -eq 1 ] || die review_skip_was_not_rejected
printf '%s' "$SKIP_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["token"]=="COMPOSE=BLOCKED"' \
  || die review_skip_contract_mismatch
printf '%s\n' "$SKIP_OUT" > "$EVIDENCE/02-review-skip-rejected.json"

REVIEW_OUT="$(run_cvg compose review --reviewer release-owner \
  --reason "Single-task boundary, ownership, rollback, and path policy accepted." 2>&1)" \
  || die review_failed
need_token "$REVIEW_OUT" "COMPOSE=PREVIEW_READY"
[ ! -e "$ROOM/seamwise/task-plan.json" ] || die review_compiled_task_plan
printf '%s\n' "$REVIEW_OUT" > "$EVIDENCE/03-review.txt"

PREVIEW_OUT="$(run_cvg compose preview 2>&1)" || die preview_failed
need_token "$PREVIEW_OUT" "COMPOSE=PREVIEW_READY"
[ -f "$ROOM/seamwise/task-plan.json" ] || die task_plan_missing
[ -f "$ROOM/seamwise/task-plan-lineage.json" ] || die task_plan_lineage_missing
[ ! -e "$ROOM/$SPEC" ] || die preview_materialized_task
printf '%s\n' "$PREVIEW_OUT" > "$EVIDENCE/04-preview.txt"

MATERIALIZE_OUT="$(run_cvg compose materialize 2>&1)" || die materialize_failed
need_token "$MATERIALIZE_OUT" "COMPOSE=MATERIALIZED"
[ -f "$ROOM/$SPEC" ] || die task_spec_missing
grep -q '^signed_off: false$' "$ROOM/$SPEC" || die materialization_authorized_dispatch
printf '%s\n' "$MATERIALIZE_OUT" > "$EVIDENCE/05-materialize.txt"

python3 - "$ROOT" "$ROOM" "$SOURCE_COMMIT" <<'PY' || die composition_receipt_invalid
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
room = pathlib.Path(sys.argv[2])
source_commit = sys.argv[3]
receipt_path = room / "cvg/receipts/composition/composition-receipt.json"
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
assert receipt["contract"] == "ConvergeCompositionReceipt/v1"
assert receipt["dispatch_authorized"] is False
assert receipt["source"]["commit"] == source_commit
assert receipt["versions"] == {
    "converge": "0.2.1",
    "seamwise": "0.2.0",
    "task_spec": "3.8.0",
}
assert [item["task_id"] for item in receipt["tasks"]] == ["T-20260815-health-status"]
try:
    import jsonschema
except ImportError:
    jsonschema = None
if jsonschema is not None:
    schema = json.loads(
        (root / "contracts/converge-composition-receipt-v1.schema.json").read_text(encoding="utf-8")
    )
    jsonschema.validate(receipt, schema)
for key in ("review", "lineage"):
    binding = receipt["seamwise"][key]
    actual = hashlib.sha256((room / binding["path"]).read_bytes()).hexdigest()
    assert actual == binding["sha256"]
PY

git -C "$ROOM" add -A
git -C "$ROOM" commit --quiet -m "review and materialize deterministic task"

set +e
EARLY_ACCEPT="$(run_taskspec accept --stamp "$SPEC" 2>&1)"
EARLY_ACCEPT_RC=$?
set -e
[ "$EARLY_ACCEPT_RC" -ne 0 ] || die acceptance_succeeded_without_execution_evidence
printf '%s\n' "$EARLY_ACCEPT" > "$EVIDENCE/06-early-acceptance-rejected.txt"

GATE_OUT="$(run_taskspec gate --stamp --stamp-by deterministic-demo "$SPEC" 2>&1)" \
  || die task_authorization_failed
need_token "$GATE_OUT" "TIER=1"
printf '%s\n' "$GATE_OUT" > "$EVIDENCE/07-authorization.txt"
git -C "$ROOM" add -A
git -C "$ROOM" commit --quiet -m "authorize deterministic composed task"

STATUS_AFTER_GATE="$(run_cvg --json compose status 2>&1)" || die composed_status_rejected_authorized_task
printf '%s' "$STATUS_AFTER_GATE" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["token"]=="COMPOSE=MATERIALIZED"; assert d["data"]["next_action"].startswith("cvg bind")' \
  || die composed_status_did_not_advance_to_bind

BIND_OUT="$(run_cvg bind --task "$SPEC" 2>&1)" || die runtime_bind_failed
need_token "$BIND_OUT" "CHECK_RUNTIME_CONTRACT=PASS"
printf '%s\n' "$BIND_OUT" > "$EVIDENCE/08-runtime-bind.txt"
git -C "$ROOM" add -A
git -C "$ROOM" commit --quiet -m "bind deterministic execution contract"

set +e
OUT_OF_SCOPE="$(run_cvg gate --path auth/x.py 2>&1)"
OUT_OF_SCOPE_RC=$?
set -e
[ "$OUT_OF_SCOPE_RC" -ne 0 ] || die out_of_scope_path_was_allowed
printf '%s\n' "$OUT_OF_SCOPE" > "$EVIDENCE/09-out-of-scope-rejected.txt"

if [ "$DEMO_AGENT" = "deterministic" ]; then
cat > "$ENGINES/deterministic.sh" <<'ENGINE'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in --available) exit 0 ;; esac
mkdir -p src tests
cat > src/health.py <<'PY'
"""Deterministic health boundary."""


def health_status():
    """Return the process health without consulting external state."""
    return {"status": "ok"}
PY
cat > tests/test_health.py <<'PY'
import unittest

from src.health import health_status


class HealthStatusTest(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(health_status(), {"status": "ok"})

    def test_deterministic(self):
        self.assertEqual(health_status(), health_status())


if __name__ == "__main__":
    unittest.main()
PY
printf 'DETERMINISTIC_EXECUTOR=COMPLETE\n'
ENGINE
chmod +x "$ENGINES/deterministic.sh"
fi

set +e
LOOP_OUT="$(run_cvg loop --issue "$SPEC_ID" --agent "$DEMO_AGENT" --isolation inplace 2>&1)"
LOOP_RC=$?
set -e
[ "$LOOP_RC" -eq 0 ] || die loop_failed
printf '%s\n' "$LOOP_OUT" | grep -qE '^TASK_LOOP=(LOCAL_SETTLED|SETTLED)$' \
  || die settlement_token_missing
need_token "$LOOP_OUT" "ACCEPTED=1"
printf '%s\n' "$LOOP_OUT" > "$EVIDENCE/10-settlement.txt"

python3 - "$ROOM" "$SPEC_ID" <<'PY' || die final_evidence_invalid
import json
import pathlib
import sys

room = pathlib.Path(sys.argv[1])
task_id = sys.argv[2]
spec = room / "cvg/tasks" / f"{task_id}.md"
body = spec.read_text(encoding="utf-8")
assert "accepted: true" in body
receipt = json.loads((room / "cvg/receipts" / f"{task_id}.json").read_text(encoding="utf-8"))
assert receipt["result"] == "pass"
acceptance = list((room / "cvg/.taskspec/acceptance" / task_id).glob("*.json"))
assert acceptance
assert (room / "src/health.py").is_file()
assert (room / "tests/test_health.py").is_file()
PY

FINAL_STATUS="$(run_cvg --json compose status 2>&1)" || die final_composed_status_failed
printf '%s' "$FINAL_STATUS" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["token"]=="COMPOSE=MATERIALIZED"; assert d["data"]["next_action"]=="all composed tasks are independently accepted"' \
  || die final_composed_status_incorrect
printf '%s\n' "$FINAL_STATUS" > "$EVIDENCE/11-final-status.json"

cp "$ROOM/seamwise/task-plan.json" "$EVIDENCE/task-plan.json"
cp "$ROOM/seamwise/task-plan-lineage.json" "$EVIDENCE/task-plan-lineage.json"
cp "$ROOM/cvg/receipts/composition/composition-receipt.json" "$EVIDENCE/composition-receipt.json"
cp "$ROOM/cvg/receipts/$SPEC_ID.json" "$EVIDENCE/execution-receipt.json"
cp "$ROOM/cvg/execution/$SPEC_ID/task-handoff.json" "$EVIDENCE/task-handoff.json"
ACCEPTANCE_RECORD="$(find "$ROOM/cvg/.taskspec/acceptance/$SPEC_ID" -type f -name '*.json' -print | head -1)"
[ -n "$ACCEPTANCE_RECORD" ] || die acceptance_record_missing
cp "$ACCEPTANCE_RECORD" "$EVIDENCE/acceptance-record.json"
git -C "$ROOM" status --short > "$EVIDENCE/final-git-status.txt"

python3 - "$EVIDENCE" "$ROOM" "$TASKSPEC_BIN" "$SEAMWISE_BIN" "$DEMO_AGENT" \
  "$TASKSPEC_SOURCE_COMMIT" "$SEAMWISE_SOURCE_COMMIT" <<'PY' || die evidence_manifest_failed
import hashlib
import json
import pathlib
import subprocess
import sys

evidence = pathlib.Path(sys.argv[1])
room = pathlib.Path(sys.argv[2])
taskspec = sys.argv[3]
seamwise = sys.argv[4]
agent = sys.argv[5]
taskspec_commit = sys.argv[6]
seamwise_commit = sys.argv[7]

def output(command):
    return subprocess.run(command, text=True, capture_output=True, check=True).stdout.strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

composition = json.loads((evidence / "composition-receipt.json").read_text(encoding="utf-8"))
snapshot = {
    "contract": "ComposedDemoSnapshot/v1",
    "agent": agent,
    "source_commit": composition["source"]["commit"],
    "final_commit": output(["git", "-C", str(room), "rev-parse", "HEAD"]),
    "working_tree_clean": output(["git", "-C", str(room), "status", "--porcelain=v1"]) == "",
    "artifacts": {
        "src/health.py": digest(room / "src/health.py"),
        "tests/test_health.py": digest(room / "tests/test_health.py"),
    },
    "accepted": True,
}
(evidence / "final-snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

environment = {
    "contract": "ComposedDemoEnvironment/v1",
    "versions": {
        "converge": "0.2.1",
        "task_spec": output([taskspec, "version"]),
        "seamwise": output([seamwise, "--version"]),
        "executor": output(["codex", "--version"]) if agent == "codex" else "deterministic-fixture/v1",
    },
    "release_candidate_commits": {
        "task_spec": taskspec_commit,
        "seamwise": seamwise_commit,
    },
    "release_candidate_provenance_verified": all(
        value != "unverified" for value in (taskspec_commit, seamwise_commit)
    ),
    "commands": [
        "cvg compose prepare --source recipe.yaml",
        "cvg compose review --reviewer release-owner --reason <REDACTED_HUMAN_REASON>",
        "cvg compose preview",
        "cvg compose materialize",
        "taskspec gate --stamp --stamp-by deterministic-demo cvg/tasks/T-20260815-health-status.md",
        "cvg bind --task cvg/tasks/T-20260815-health-status.md",
        f"cvg loop --issue T-20260815-health-status --agent {agent} --isolation inplace",
    ],
    "credentials_recorded": False,
}
(evidence / "environment.json").write_text(json.dumps(environment, indent=2) + "\n", encoding="utf-8")

for path in evidence.glob("*.txt"):
    text = path.read_text(encoding="utf-8")
    text = text.replace(str(room), "<WORKSPACE>").replace(str(pathlib.Path.home()), "<HOME>")
    path.write_text(text, encoding="utf-8")
PY

printf 'DELIVERY_PLAN=READY\n'
printf 'TASK_PLAN=OK\n'
printf 'TASK_BATCH=OK\n'
printf 'TIER=1\n'
printf 'CHECK_RUNTIME_CONTRACT=PASS\n'
printf '%s\n' "$LOOP_OUT" | grep -E '^TASK_LOOP=(LOCAL_SETTLED|SETTLED)$' | tail -1
printf 'ACCEPTED=1\n'
if [ "$DEMO_AGENT" = "codex" ]; then
  printf 'LIVE_CODEX_DEMO=READY\n'
else
  printf 'DEMO_COMPOSED=READY\n'
fi
