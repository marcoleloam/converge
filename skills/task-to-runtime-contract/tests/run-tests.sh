#!/usr/bin/env bash
# End-to-end regression for Pass 6 · Bind. Uses disposable repositories only.

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_HOME="$(cd "$SKILL_DIR/../.." && pwd)"
CVG="$TOOL_HOME/bin/cvg"
TASKSPEC_ENGINE="${CVG_TASKSPEC_BIN:-${TASKSPEC_BIN:-taskspec}}"
EVAL_RUNNER="$TOOL_HOME/skills/task-loop/scripts/run-issue-eval.sh"
FIXTURE="$TOOL_HOME/tests/fixtures/T-20260602-golden.md"
LOOP="$TOOL_HOME/skills/task-loop/scripts/run-issue-eval.sh"
OPEN_PR="$TOOL_HOME/skills/task-loop/scripts/open-issue-pr.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

if python3 "$SKILL_DIR/tests/test-gate-policy.py"; then
  ok "strict repository-gate parser and Git trust boundary"
else
  bad "repository-gate parser or Git trust boundary"
fi

TMP_REPO="$(mktemp -d -t cvg-runtime-contract.XXXXXX)"
KEY_FILE="$(mktemp -t cvg-runtime-key.XXXXXX)"
# shellcheck disable=SC2329  # invoked by trap
cleanup() { rm -rf "$TMP_REPO"; rm -f "$KEY_FILE"; }
trap cleanup EXIT

# Pin the fixture's branch NAME, because six checks below pass `--base main`.
#
# `git init` names the first branch from the HOST's init.defaultBranch: `main` on
# a machine configured that way, `master` on a stock runner. So those checks were
# asserting against a ref that existed only on the author's laptop — on GitHub's
# ubuntu image `main` does not resolve, the diff errors, settlement is refused,
# and two WP4 checks fail for a reason that has nothing to do with WP4. The suite
# was measuring the developer's git config.
#
# `symbolic-ref` (not `init -b`, which needs git >= 2.28) works on every version
# and before the first commit, which is the portability floor this repo claims.
pin_branch() { git -C "$1" symbolic-ref HEAD refs/heads/main; }

git -C "$TMP_REPO" init --quiet
pin_branch "$TMP_REPO"
git -C "$TMP_REPO" config user.email runtime-contract@test.local
git -C "$TMP_REPO" config user.name "runtime contract test"
mkdir -p "$TMP_REPO/tasks" "$TMP_REPO/cvg/knowledge/failures" "$TMP_REPO/cvg/knowledge/references"
cp "$FIXTURE" "$TMP_REPO/tasks/T-20260602-golden.md"
printf '# readme\n' > "$TMP_REPO/README.md"
printf 'Known project-specific locking failure.\n' > "$TMP_REPO/cvg/knowledge/failures/locking.md"
printf 'Version-pinned external reference.\n' > "$TMP_REPO/cvg/knowledge/references/vendor-v1.md"
printf 'runtime-contract-test-key-material-32bytes\n' > "$KEY_FILE"

(
  cd "$TMP_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by runtime-test tasks/T-20260602-golden.md >/dev/null
)

PROFILE="$TMP_REPO/cvg/execution/T-20260602-golden/execution-profile.yaml"

DRY_PROFILE="$TMP_REPO/cvg/execution/dry-run/execution-profile.yaml"
DRY_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" --json --dry-run bind \
    --task tasks/T-20260602-golden.md \
    --out cvg/execution/dry-run/execution-profile.yaml
)"
if [ ! -e "$DRY_PROFILE" ] && python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["dry_run"] is True and d["changed"] is False' <<<"$DRY_OUT"; then
  ok "cvg bind --dry-run changes nothing"
else
  bad "bind dry-run wrote an artifact or misreported state"
fi

set +e
BIND_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md \
    --knowledge cvg/knowledge/failures/locking.md \
    --doc https://example.test/vendor/v1=cvg/knowledge/references/vendor-v1.md 2>&1
)"
BIND_RC=$?
set -e
if [ "$BIND_RC" -eq 0 ] && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$BIND_OUT"; then
  ok "cvg bind emits a ready contract"
else
  bad "cvg bind failed: $BIND_OUT"
fi

if [ -f "$PROFILE" ] \
  && python3 - "$PROFILE" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["schema"] == "cvg.execution-profile.v1"
assert p["task"]["authorization"]["trust_tier"] == 1
assert p["topology"]["mode"] == "single"
assert p["canonical_sources"]["write_scope"].startswith("task_spec.")
assert p["enforcement"]["receipt_writer"].endswith("write-execution-receipt.py")
assert p["enforcement"]["primary_runtime"] == "generic"
assert p["enforcement"]["runtime_selection"] == {
    "source": "fallback.generic",
    "inferred_runtime": "generic",
    "inferred_source": "fallback.generic",
}
assert p["context"]["approved_project_knowledge"][0]["sha256"]
assert p["context"]["external_docs"][0]["cache_path"].endswith("vendor-v1.md")
PY
then
  ok "profile is thin, Tier 1, pinned, and portable"
else
  bad "profile shape or semantics"
fi

DERIVED_TASK="$TMP_REPO/tasks/T-20260602-runtime-derived.md"
DERIVED_PROFILE="$TMP_REPO/cvg/execution/T-20260602-runtime-derived/execution-profile.yaml"
sed \
  -e 's|T-20260602-golden|T-20260602-runtime-derived|g' \
  -e 's|^execution_backend: any$|execution_backend: codex|' \
  "$FIXTURE" > "$DERIVED_TASK"
(
  cd "$TMP_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by runtime-test \
    tasks/T-20260602-runtime-derived.md >/dev/null
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-runtime-derived.md >/dev/null
)
if python3 - "$DERIVED_PROFILE" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["enforcement"]
assert e["primary_runtime"] == "codex"
assert e["runtime_selection"]["source"] == "task_spec.execution_backend"
assert e["runtime_selection"]["inferred_runtime"] == "codex"
PY
then
  ok "Task-Spec execution_backend selects the primary runtime"
else
  bad "Task-Spec runtime selection was not bound into the profile"
fi

OMP_TASK="$TMP_REPO/tasks/T-20260602-runtime-omp.md"
OMP_PROFILE="$TMP_REPO/cvg/execution/T-20260602-runtime-omp/execution-profile.yaml"
OMP_ADAPTER="$TMP_REPO/cvg/execution/T-20260602-runtime-omp/adapters/omp.json"
sed \
  -e 's|T-20260602-golden|T-20260602-runtime-omp|g' \
  -e 's|^execution_backend: any$|execution_backend: omp|' \
  "$FIXTURE" > "$OMP_TASK"
(
  cd "$TMP_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by runtime-test \
    tasks/T-20260602-runtime-omp.md >/dev/null
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-runtime-omp.md >/dev/null
)
if python3 - "$OMP_PROFILE" "$OMP_ADAPTER" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["enforcement"]
assert e["primary_runtime"] == "omp"
assert e["runtime_selection"]["source"] == "task_spec.execution_backend"
assert e["runtime_selection"]["inferred_runtime"] == "omp"
assert e["assurance"] == "detect", e["assurance"]
assert e["assurance"] != "prevent"
omp = next(a for a in e["adapters"] if a["runtime"] == "omp")
kinds = {k: v["enforcement_kind"] for k, v in omp["resolution"]["controls"].items()}
assert kinds["fs.write"] == "detect"
assert "prevent" not in kinds.values(), kinds
adapter = json.load(open(sys.argv[2]))
assert adapter["schema"] == "cvg.runtime-adapter.v1"
assert adapter["adapter"] == "omp"
assert adapter["native_control"]["supports_prewrite_prevention"] is False
PY
then
  ok "execution_backend omp infers detect-only primary_runtime omp"
else
  bad "omp was not bound as a detect-only primary runtime"
fi

cp "$DERIVED_PROFILE" "$DERIVED_PROFILE.bak"
python3 - "$DERIVED_PROFILE" <<'PY'
import json, sys
path = sys.argv[1]
profile = json.load(open(path))
profile["enforcement"]["primary_runtime"] = "generic"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(profile, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
set +e
RUNTIME_DRIFT_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" python3 \
    "$SKILL_DIR/scripts/check-runtime-contract.py" \
    --repo "$TMP_REPO" --tool-home "$TOOL_HOME" \
    --profile "$DERIVED_PROFILE" 2>&1
)"
RUNTIME_DRIFT_RC=$?
set -e
mv "$DERIVED_PROFILE.bak" "$DERIVED_PROFILE"
if [ "$RUNTIME_DRIFT_RC" -ne 0 ] \
  && grep -q 'primary runtime drift' <<<"$RUNTIME_DRIFT_OUT"; then
  ok "runtime drift from the sealed Task-Spec fails readiness"
else
  bad "runtime drift escaped readiness: $RUNTIME_DRIFT_OUT"
fi

PROFILE_HASH_1="$(shasum -a 256 "$PROFILE" | awk '{print $1}')"
(
  cd "$TMP_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md \
    --knowledge cvg/knowledge/failures/locking.md \
    --doc https://example.test/vendor/v1=cvg/knowledge/references/vendor-v1.md >/dev/null
)
PROFILE_HASH_2="$(shasum -a 256 "$PROFILE" | awk '{print $1}')"
if [ "$PROFILE_HASH_1" = "$PROFILE_HASH_2" ]; then
  ok "binding is deterministic"
else
  bad "binding changed without input changes"
fi

set +e
CHECK_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind --check \
    --task tasks/T-20260602-golden.md 2>&1
)"
CHECK_RC=$?
set -e
if [ "$CHECK_RC" -eq 0 ] && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$CHECK_OUT"; then
  ok "cvg bind --check re-verifies freshness"
else
  bad "bind --check failed: $CHECK_OUT"
fi

JSON_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" --json bind --check \
    --task tasks/T-20260602-golden.md
)"
if python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["ok"] is True
assert d["converge_pass"] == 7
assert d["token"] == "CHECK_RUNTIME_CONTRACT=PASS"
assert d["changed"] is False' <<<"$JSON_OUT"; then
  ok "agent-native JSON envelope exposes Pass 7 verdict"
else
  bad "bind JSON envelope is incomplete"
fi

if (
  cd "$TMP_REPO"
  python3 "$SKILL_DIR/scripts/check-path-policy.py" \
    --profile "$PROFILE" --candidate README.md --candidate "$TMP_REPO/README.md" >/dev/null
); then
  ok "candidate guard allows relative and absolute in-repo paths"
else
  bad "candidate guard rejected allowed path"
fi

set +e
PATH_OUT="$(
  cd "$TMP_REPO" &&
  python3 "$SKILL_DIR/scripts/check-path-policy.py" \
    --profile "$PROFILE" --candidate src/forbidden.py 2>&1
)"
PATH_RC=$?
set -e
if [ "$PATH_RC" -eq 1 ] && grep -q '^CHECK_PATH_POLICY=FAIL$' <<<"$PATH_OUT"; then
  ok "candidate guard rejects forbidden path"
else
  bad "candidate guard did not fail closed"
fi

if (
  cd "$TMP_REPO"
  printf '{"tool_input":{"file_path":"README.md"}}\n' |
    CVG_EXECUTION_PROFILE="$PROFILE" \
    python3 "$SKILL_DIR/scripts/guard-tool-input.py" >/dev/null
); then
  ok "vendor hook bridge enforces tool-input paths"
else
  bad "tool-input hook bridge rejected allowed write"
fi

HOOK_DENY="$(
  cd "$TMP_REPO"
  printf '{"tool_name":"Write","tool_input":{"file_path":"src/forbidden.py"}}\n' |
    CVG_EXECUTION_PROFILE="$PROFILE" \
    python3 "$SKILL_DIR/scripts/guard-tool-input.py"
)"
if python3 -c 'import json,sys
d=json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"] == "PreToolUse"
assert d["permissionDecision"] == "deny"
assert "src/forbidden.py" in d["permissionDecisionReason"]' <<<"$HOOK_DENY"; then
  ok "Claude PreToolUse bridge emits a real structured deny decision"
else
  bad "tool-input bridge did not block with Claude's hook protocol"
fi

set +e
TOPOLOGY_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" python3 "$SKILL_DIR/scripts/bind-runtime-contract.py" \
    --repo "$TMP_REPO" --tool-home "$TOOL_HOME" \
    --task tasks/T-20260602-golden.md \
    --topology implementer-verifier \
    --out cvg/execution/rejected/execution-profile.yaml 2>&1
)"
TOPOLOGY_RC=$?
set -e
if [ "$TOPOLOGY_RC" -eq 1 ] \
  && grep -q 'substantive static justification' <<<"$TOPOLOGY_OUT"; then
  ok "non-single topology needs substantive evidence"
else
  bad "topology presence check was too weak"
fi

set +e
PARALLEL_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" python3 "$SKILL_DIR/scripts/bind-runtime-contract.py" \
    --repo "$TMP_REPO" --tool-home "$TOOL_HOME" \
    --task tasks/T-20260602-golden.md \
    --topology parallel \
    --justification "Two independent writers were selected from static repository seams." \
    --worker one:scoped-write:README.md \
    --worker two:scoped-write:README.md \
    --out cvg/execution/rejected-parallel/execution-profile.yaml 2>&1
)"
PARALLEL_RC=$?
set -e
if [ "$PARALLEL_RC" -eq 1 ] && grep -q 'ownership overlaps' <<<"$PARALLEL_OUT"; then
  ok "parallel ownership must be disjoint"
else
  bad "parallel overlap escaped the gate"
fi

PARALLEL_TASK="$TMP_REPO/tasks/T-20260602-parallel.md"
sed \
  -e 's|T-20260602-golden|T-20260602-parallel|g' \
  -e 's|  - README.md|  - src/**\
  - tests/**|' \
  -e 's|^- src/$|- docs/|' \
  "$FIXTURE" > "$PARALLEL_TASK"
mkdir -p "$TMP_REPO/src" "$TMP_REPO/tests"
printf 'source\n' > "$TMP_REPO/src/unit.py"
printf 'test\n' > "$TMP_REPO/tests/test_unit.py"
(
  cd "$TMP_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by runtime-test tasks/T-20260602-parallel.md >/dev/null
)
set +e
PARALLEL_OK_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-parallel.md \
    --topology parallel \
    --justification "Source and test legs have statically disjoint write ownership." \
    --worker source:scoped-write:src/** \
    --worker tests:scoped-write:tests/** 2>&1
)"
PARALLEL_OK_RC=$?
set -e
if [ "$PARALLEL_OK_RC" -eq 0 ] \
  && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$PARALLEL_OK_OUT"; then
  ok "disjoint parallel topology binds and gates successfully"
else
  bad "valid parallel topology was rejected: $PARALLEL_OK_OUT"
fi

git -C "$TMP_REPO" add -A
git -C "$TMP_REPO" commit --quiet -m "runtime contract baseline"
git -C "$TMP_REPO" branch -M main
printf 'authorized task change\n' >> "$TMP_REPO/README.md"
if (
  cd "$TMP_REPO"
  python3 "$SKILL_DIR/scripts/check-path-policy.py" \
    --profile "$PROFILE" --base main >/dev/null
); then
  ok "postflight diff guard accepts an in-scope working-tree change"
else
  bad "postflight diff guard rejected an authorized change"
fi

printf 'out of scope\n' > "$TMP_REPO/outside.txt"
set +e
DIFF_OUT="$(
  cd "$TMP_REPO" &&
  python3 "$SKILL_DIR/scripts/check-path-policy.py" \
    --profile "$PROFILE" --base main 2>&1
)"
DIFF_RC=$?
set -e
if [ "$DIFF_RC" -eq 1 ] \
  && grep -q 'outside.txt' <<<"$DIFF_OUT" \
  && grep -q '^CHECK_PATH_POLICY=FAIL$' <<<"$DIFF_OUT"; then
  ok "postflight diff guard rejects an out-of-scope change"
else
  bad "postflight diff guard did not fail closed: $DIFF_OUT"
fi
git -C "$TMP_REPO" checkout -- README.md
unlink "$TMP_REPO/outside.txt"

# The loop's landing ledger is FRAMEWORK output, like cvg/loop/ and the receipt.
# The kernel appends a row to cvg/STATE.md on every landing, so from the SECOND
# run onward it is always dirty at settlement time — and the run was refused for
# a line the loop itself wrote about the previous run. A first run in a fresh
# workspace passes, which is why this needed a history to show up at all.
# NOTE: cvg/ already holds the execution profile this suite is testing against.
# Create only the ledger file, and remove only that file.
mkdir -p "$TMP_REPO/cvg"
printf '| when | task | state |\n' > "$TMP_REPO/cvg/STATE.md"
set +e
LEDGER_OUT="$(
  cd "$TMP_REPO" &&
  python3 "$SKILL_DIR/scripts/check-path-policy.py" \
    --profile "$PROFILE" --base main 2>&1
)"
LEDGER_RC=$?
set -e
if [ "$LEDGER_RC" -eq 0 ] && grep -q '^CHECK_PATH_POLICY=PASS$' <<<"$LEDGER_OUT"; then
  ok "the loop's own landing ledger never counts as the task's diff"
else
  bad "cvg/STATE.md was convicted as out-of-scope: $LEDGER_OUT"
fi
rm -f "$TMP_REPO/cvg/STATE.md"

set +e
STALE_OUT="$(
  printf '\nTamper.\n' >> "$TMP_REPO/tasks/T-20260602-golden.md"
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind --check \
    --task tasks/T-20260602-golden.md 2>&1
)"
STALE_RC=$?
set -e
if [ "$STALE_RC" -eq 1 ] \
  && grep -Eq 'stale profile|modified after stamping|not execution-ready' <<<"$STALE_OUT"; then
  ok "Task-Spec drift fails readiness"
else
  bad "stale profile was not rejected: $STALE_OUT"
fi

git -C "$TMP_REPO" checkout -- tasks/T-20260602-golden.md 2>/dev/null || true
# The task was not committed, so restore it from a freshly re-stamped fixture.
cp "$FIXTURE" "$TMP_REPO/tasks/T-20260602-golden.md"
(
  cd "$TMP_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by runtime-test tasks/T-20260602-golden.md >/dev/null
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md \
    --knowledge cvg/knowledge/failures/locking.md \
    --doc https://example.test/vendor/v1=cvg/knowledge/references/vendor-v1.md >/dev/null
)

set +e
LOOP_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" bash "$LOOP" \
    --issue T-20260602-golden --tasks-dir tasks 2>&1
)"
LOOP_RC=$?
set -e
if [ "$LOOP_RC" -eq 0 ] \
  && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$LOOP_OUT" \
  && grep -q '^GREEN' <<<"$LOOP_OUT"; then
  ok "Pass 8 requires and consumes the Pass 6 contract"
else
  bad "task-loop contract integration failed: $LOOP_OUT"
fi

git -C "$TMP_REPO" add -A
git -C "$TMP_REPO" commit --quiet -m "rebind runtime contract"
printf 'authorized implementation\n' >> "$TMP_REPO/README.md"
set +e
SETTLE_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" bash "$OPEN_PR" \
    --issue T-20260602-golden \
    --tasks-dir tasks \
    --base main \
    --dry-run 2>&1
)"
SETTLE_RC=$?
set -e
if [ "$SETTLE_RC" -eq 0 ] \
  && grep -q "^GREEN — issue" <<<"$SETTLE_OUT" \
  && grep -q '^CHECK_PATH_POLICY=PASS$' <<<"$SETTLE_OUT"; then
  ok "Pass 8 settlement requires both green eval and green path policy"
else
  bad "Pass 8 settlement integration failed: $SETTLE_OUT"
fi
git -C "$TMP_REPO" checkout -- README.md

mkdir -p "$TMP_REPO/cvg/receipts"
printf 'GREEN — eval passed\n' > "$TMP_REPO/cvg/receipts/eval-output.txt"
if (
  cd "$TMP_REPO"
  python3 "$SKILL_DIR/scripts/write-execution-receipt.py" \
    --profile "$PROFILE" \
    --result pass \
    --eval-output cvg/receipts/eval-output.txt \
    --path-policy pass \
    --agent test-runtime \
    --branch task/golden >/dev/null
) && python3 - "$TMP_REPO/cvg/receipts/T-20260602-golden.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["schema"] == "cvg.execution-receipt.v1"
assert r["result"] == "pass"
assert r["evaluation"]["path_policy"] == "pass"
assert r["task_spec"]["sha256"]
assert r["execution_profile"]["sha256"]
PY
then
  ok "Pass 8 receipt binds spec, profile, eval, and path-policy evidence"
else
  bad "execution receipt writer failed"
fi

if (
  cd "$TMP_REPO"
  python3 "$SKILL_DIR/scripts/propose-knowledge-candidate.py" \
    --profile "$PROFILE" \
    --receipt cvg/receipts/T-20260602-golden.json \
    --kind failure \
    --summary "README path checks require repository-relative candidates" \
    --evidence "The signed execution receipt proved the scoped guard and eval both passed." \
    >/dev/null
) && grep -q '^status: proposed$' \
  "$TMP_REPO/cvg/knowledge/candidates/T-20260602-golden.md"; then
  ok "execution receipt creates only a proposed knowledge candidate"
else
  bad "knowledge-accretion seam failed"
fi

# ---------------------------------------------------------------------------
# The capability envelope + resolver manifest (the closure / fail-closed core).
# ---------------------------------------------------------------------------
# Authority is epoch-bound: the grant names the exact signed revision, scopes
# fs.write to the Task-Spec's own paths, and declares mandatory closure.
if python3 - "$PROFILE" "$TMP_REPO/tasks/T-20260602-golden.md" <<'PY'
import hashlib, json, sys
profile = json.load(open(sys.argv[1]))
spec = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
auth = profile["authority"]
assert auth["epoch"] == f"T-20260602-golden@{spec[:12]}", auth["epoch"]
assert auth["closure"]["revocation_is_mandatory"] is True
assert auth["closure"]["lingering_authority"] == "denied"
assert set(auth["closure"]["revoke_on"]) >= {"settle", "block", "budget_exhausted", "epoch_change"}
write = next(g for g in auth["grants"] if g["capability"] == "fs.write")
assert write["granted"] is True and write["scope"], write
net = next(g for g in auth["grants"] if g["capability"] == "net.egress")
assert net["granted"] is False and net["phase"] == "none", net
PY
then
  ok "authority is epoch-bound and closes (no lingering authority)"
else
  bad "capability envelope is missing or unclosed"
fi

# The resolver manifest must be HONEST about prevent vs detect per runtime.
if python3 - "$PROFILE" <<'PY'
import json, sys
enforcement = json.load(open(sys.argv[1]))["enforcement"]
by = {a["runtime"]: a["resolution"] for a in enforcement["adapters"]}
assert by["codex"]["controls"]["fs.write"]["enforcement_kind"] == "detect"
assert by["claude"]["controls"]["fs.write"]["enforcement_kind"] == "detect"
assert by["generic"]["controls"]["fs.write"]["enforcement_kind"] == "detect"
omp_kinds = {k: v["enforcement_kind"] for k, v in by["omp"]["controls"].items()}
kimi_kinds = {k: v["enforcement_kind"] for k, v in by["kimi"]["controls"].items()}
assert omp_kinds == kimi_kinds, (omp_kinds, kimi_kinds)
assert "prevent" not in omp_kinds.values(), omp_kinds
assert enforcement["required_controls"] == ["fs.write"]
assert enforcement["assurance"] == "detect"  # primary runtime is generic
PY
then
  ok "resolver manifest reports prevent vs detect per runtime"
else
  bad "resolver manifest is missing or dishonest"
fi

CLAUDE_ADAPTER="$TMP_REPO/cvg/execution/T-20260602-golden/adapters/claude.json"
if python3 - "$CLAUDE_ADAPTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["native_control"]["supports_prewrite_prevention"] is False
group = d["claude_settings_fragment"]["hooks"]["PreToolUse"][0]
assert group["matcher"] == "Edit|Write|NotebookEdit"
assert "guard-tool-input.py" in group["hooks"][0]["command"]
PY
then
  ok "Claude adapter emits an installable hook fragment without claiming it is installed"
else
  bad "Claude adapter overclaims or omits its PreToolUse integration fragment"
fi

# FAIL CLOSED: a required control the runtime cannot enforce must stop the gate.
# NB: capture-then-assert — under `set -o pipefail` a failing producer would sink
# the whole pipeline even when grep matched, hiding the very behaviour under test.
set +e
FC_OUT="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md --out .fc/p.yaml \
    --runtime generic --require net.egress 2>&1
)"
FC_RC=$?
set -e
if [ "$FC_RC" -ne 0 ] && grep -q 'cannot enforce required control' <<<"$FC_OUT"; then
  ok "unenforced required control fails the gate closed"
else
  bad "gate did not fail closed on an unenforced required control: $FC_OUT"
fi

# …and a runtime that CAN enforce it passes, proving the check discriminates.
set +e
FC_OK="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md --out .fc/ok.yaml \
    --runtime codex --require net.egress 2>&1
)"
FC_OK_RC=$?
set -e
if [ "$FC_OK_RC" -eq 0 ] && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$FC_OK"; then
  ok "a runtime that enforces the control passes (check discriminates)"
else
  bad "codex should enforce net.egress but the gate refused: $FC_OK"
fi

# OMP is detect/unenforced like kimi: it cannot satisfy a prevent requirement.
set +e
OMP_FC="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md --out .fc/omp.yaml \
    --runtime omp --require net.egress 2>&1
)"
OMP_FC_RC=$?
set -e
if [ "$OMP_FC_RC" -ne 0 ] && grep -q 'cannot enforce required control' <<<"$OMP_FC"; then
  ok "omp cannot prevent net.egress (same unenforced limit as kimi)"
else
  bad "omp claimed prevent-level net.egress or skipped the fail-closed gate: $OMP_FC"
fi

# An explicit waiver is the only other way through, and it is recorded.
set +e
FC_W="$(
  cd "$TMP_REPO" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind \
    --task tasks/T-20260602-golden.md --out .fc/w.yaml \
    --runtime generic --require net.egress --accept-unenforced net.egress 2>&1
)"
FC_W_RC=$?
set -e
if [ "$FC_W_RC" -eq 0 ] \
  && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$FC_W" \
  && python3 - "$TMP_REPO/.fc/w.yaml" <<'PY2'
import json, sys
e = json.load(open(sys.argv[1]))["enforcement"]
assert e["unenforced_waivers"] == ["net.egress"], e
assert e["assurance"] == "unenforced", e
PY2
then
  ok "an unenforced control passes only with an audited waiver"
else
  bad "waiver path did not record the accepted risk: $FC_W"
fi

# The host attestation must return a machine verdict, never a guess.
if python3 "$SKILL_DIR/scripts/attest-runtime.py" --runtime generic --json \
  | grep -v '^DOCTOR_RUNTIME_CONTRACT=' \
  | python3 -c "
import json,sys
a=json.load(sys.stdin)
assert a['verdict'] in {'OK','DEGRADED','FAIL'}, a
assert 'primitive' in a['isolation'] and 'available' in a['isolation']"; then
  ok "runtime attestation probes the host and emits a machine verdict"
else
  bad "runtime attestation failed"
fi

# Missing omp is a machine FAIL, never an assumed install. Hide the binary
# without calling a real model: keep Python and git, but no engine in PATH.
OMP_HIDE="$(mktemp -d -t cvg-omp-hide.XXXXXX)"
ln -s "$(command -v python3)" "$OMP_HIDE/python3"
ln -s "$(command -v git)" "$OMP_HIDE/git"
set +e
OMP_ATTEST_OUT="$(
  PATH="$OMP_HIDE" python3 "$SKILL_DIR/scripts/attest-runtime.py" --runtime omp --json 2>&1
)"
OMP_ATTEST_RC=$?
set -e
rm -rf "$OMP_HIDE"
if [ "$OMP_ATTEST_RC" -ne 0 ] \
  && grep -q '^DOCTOR_RUNTIME_CONTRACT=FAIL$' <<<"$OMP_ATTEST_OUT" \
  && python3 -c '
import json, sys
raw = "\n".join(
    line for line in sys.stdin.read().splitlines()
    if not line.startswith("DOCTOR_RUNTIME_CONTRACT=")
)
a = json.loads(raw)
assert a["runtime"] == "omp", a
assert a["verdict"] == "FAIL", a
assert a["binary"]["required"] is True
assert a["binary"]["present"] is False, a
assert a["claims_prevent"] == [], a
' <<<"$OMP_ATTEST_OUT"
then
  ok "runtime probe FAILs when omp is missing and never claims prevent"
else
  bad "missing-omp attestation did not FAIL closed: $OMP_ATTEST_OUT"
fi

# Every vendor process gets a closed stdin. A headless judge inheriting the
# caller's pipe can wait forever for input even though its command line is
# nominally non-interactive.
JUDGE_BIN="$TMP_REPO/judge-bin"
mkdir -p "$JUDGE_BIN"
cat > "$JUDGE_BIN/codex" <<'SH'
#!/usr/bin/env bash
if IFS= read -r unexpected; then
  printf 'INHERITED_STDIN:%s\n' "$unexpected"
  exit 7
fi
printf '%s\n' '{"verdict":"UPHELD","confidence":"high","findings":[],"reasoning":"stdin closed"}'
SH
chmod +x "$JUDGE_BIN/codex"
if printf 'MUST_NOT_REACH_JUDGE\n' \
  | PATH="$JUDGE_BIN:$PATH" VERIFY_WORK="$SKILL_DIR/scripts/verify-work.py" \
    python3 -c '
import importlib.util, os
spec = importlib.util.spec_from_file_location("verify_work", os.environ["VERIFY_WORK"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ok, raw = module.run_judge("codex", "prompt", 2)
verdict = module.extract_verdict(raw)
assert ok and verdict and verdict["verdict"] == "UPHELD", raw
'; then
  ok "tier-2 judge receives closed stdin"
else
  bad "tier-2 judge inherited caller stdin"
fi

# Killing only the vendor CLI's parent is not a timeout: a spawned helper can
# retain the capture pipes and make communicate() hang until that helper exits.
# The verifier owns a process group and must reap all of it promptly.
cat > "$JUDGE_BIN/codex" <<'SH'
#!/usr/bin/env bash
( trap '' TERM; sleep 20 ) &
trap '' TERM
sleep 20
SH
chmod +x "$JUDGE_BIN/codex"
if PATH="$JUDGE_BIN:$PATH" VERIFY_WORK="$SKILL_DIR/scripts/verify-work.py" \
  python3 -c '
import importlib.util, os, time
spec = importlib.util.spec_from_file_location("verify_work", os.environ["VERIFY_WORK"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
started = time.monotonic()
ok, reason = module.run_judge("codex", "prompt", 1)
elapsed = time.monotonic() - started
assert not ok and "timed out after 1s" in reason, reason
assert elapsed < 5, elapsed
'; then
  ok "tier-2 timeout kills the vendor process group promptly"
else
  bad "tier-2 timeout leaked a child process or exceeded its bound"
fi
rm -rf "$JUDGE_BIN"

# ---------------------------------------------------------------------------
# 7B — the task brief, WP2 — read-only check, lanes, and tier-2 verification
# ---------------------------------------------------------------------------
# 7A is what the RUNTIME enforces; 7B is what the MODEL reads. It must exist,
# belong to this epoch, and carry identifiers rather than a copy of the codebase.
BRIEF="$TMP_REPO/cvg/execution/T-20260602-golden/AGENTS.task.md"
if [ -f "$BRIEF" ] \
  && grep -q '^# Task brief — T-20260602-golden$' "$BRIEF" \
  && grep -q 'T-20260602-golden@' "$BRIEF" \
  && grep -q 'only instruction source' "$BRIEF" \
  && grep -q 'README.md' "$BRIEF"; then
  ok "7B task brief is written, epoch-stamped, and scope-explicit"
else
  bad "task brief missing or malformed"
fi

# A brief that drifts from the epoch must fail the gate (staleness is not cosmetic).
cp "$BRIEF" "$BRIEF.bak"
perl -pi -e 's/T-20260602-golden\@[0-9a-f]+/T-20260602-golden\@deadbeefdead/' "$BRIEF"
set +e
STALE_OUT="$(cd "$TMP_REPO" && TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" \
  "$CVG" bind --check --task tasks/T-20260602-golden.md 2>&1)"
STALE_RC=$?
set -e
mv "$BRIEF.bak" "$BRIEF"
if [ "$STALE_RC" -ne 0 ] && grep -q 'task brief is stale' <<<"$STALE_OUT"; then
  ok "a stale task brief fails the gate"
else
  bad "stale brief slipped through: $STALE_OUT"
fi

# WP2 — `bind --check` must be genuinely read-only.
BEFORE="$(cd "$TMP_REPO" && find . -type f -not -path './.git/*' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256)"
(cd "$TMP_REPO" && TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" \
  "$CVG" bind --check --task tasks/T-20260602-golden.md >/dev/null 2>&1) || true
AFTER="$(cd "$TMP_REPO" && find . -type f -not -path './.git/*' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "bind --check performs zero repository writes (WP2)"
else
  bad "bind --check mutated the repository"
fi

# The lane classifier ROUTES but never WAIVES.
LANE="$TOOL_HOME/bin/cvg-classify-lane.py"
if python3 "$LANE" "fix a typo in the readme" | grep -q '^LANE=FAST$' \
  && python3 "$LANE" "add oauth token refresh to billing" | grep -q '^LANE=NORMAL$' \
  && python3 "$LANE" "build a new service from scratch" | grep -q '^LANE=FULL$'; then
  ok "lane classifier routes trivial/sensitive/greenfield correctly"
else
  bad "lane classifier mis-routed"
fi

# The hard floor cannot be argued down, however the intent is phrased.
if python3 "$LANE" "tiny one-line typo fix in the auth token handler" \
  | grep -q 'cannot be lowered'; then
  ok "hard floor survives a FAST-sounding description"
else
  bad "hard floor was talked down by prose"
fi

# Tier-2 verification fails closed when it cannot obtain a verdict.
set +e
VERIFY_OUT="$(cd "$TMP_REPO" && python3 "$SKILL_DIR/scripts/verify-work.py" \
  --repo "$TMP_REPO" --task tasks/T-20260602-golden.md --judge nonexistent-engine 2>&1)"
VERIFY_RC=$?
set -e
if grep -qE '^CHECK_VERIFY=(ERROR|UNAVAILABLE)$' <<<"$VERIFY_OUT"; then
  ok "tier-2 verification never returns a pass it did not earn"
else
  bad "verification produced an unearned verdict: $VERIFY_OUT"
fi

# The judge must be shown UNTRACKED work.
#
# `git diff` never mentions untracked files, and tier 2 runs BEFORE settlement —
# deliberately, since the point is to refuse to settle unverified work — so at
# that moment a creates_paths task's ENTIRE deliverable is untracked. On the
# first real green run the judge was handed an empty diff, reported ERROR, and
# (correctly, since it fails closed) blocked a task whose three evals had all
# passed. The verifier was written for the post-hoc `cvg verify` case where the
# commit already existed; wiring it in front of settlement exposed that.
export VW_PATH="$SKILL_DIR/scripts/verify-work.py"
NEWFILE_DIR="$TMP_REPO/untracked-probe"
mkdir -p "$NEWFILE_DIR"
printf 'def real_work():\n    return "not a stub"\n' > "$NEWFILE_DIR/brand_new.py"
DIFF_SEEN="$(cd "$TMP_REPO" && python3 - <<'PY' 2>&1
import importlib.util, os, pathlib
spec = importlib.util.spec_from_file_location("vw", os.environ["VW_PATH"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.work_diff(pathlib.Path("."), None))
PY
)"
if grep -q 'brand_new.py' <<<"$DIFF_SEEN" && grep -q 'not a stub' <<<"$DIFF_SEEN"; then
  ok "the judge is shown untracked files, not an empty diff"
else
  bad "a brand-new file was invisible to tier 2 (the empty-diff bug)"
fi
# Framework bookkeeping is not the task's work and must not be judged as it —
# the same exemption the path policy makes, for the same reason.
mkdir -p "$TMP_REPO/cvg/loop/T-20260602-golden"
printf 'attempt noise\n' > "$TMP_REPO/cvg/loop/T-20260602-golden/HANDOFF.md"
printf '| a | b |\n' > "$TMP_REPO/cvg/STATE.md"
DIFF_SEEN2="$(cd "$TMP_REPO" && python3 - <<'PY' 2>&1
import importlib.util, os, pathlib
spec = importlib.util.spec_from_file_location("vw", os.environ["VW_PATH"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.work_diff(pathlib.Path("."), None))
PY
)"
if ! grep -q 'HANDOFF.md' <<<"$DIFF_SEEN2" && ! grep -q 'STATE.md' <<<"$DIFF_SEEN2"; then
  ok "the loop's own bookkeeping is not put in front of the judge"
else
  bad "framework output leaked into the diff under judgement"
fi
rm -rf "$NEWFILE_DIR" "$TMP_REPO/cvg/loop" "$TMP_REPO/cvg/STATE.md"

# The router scaffold must never clobber a human-authored file.
printf '# my own router\n' > "$TMP_REPO/AGENTS.md"
(cd "$TMP_REPO" && python3 "$SKILL_DIR/scripts/scaffold-router.py" --repo "$TMP_REPO" >/dev/null 2>&1) || true
if [ "$(cat "$TMP_REPO/AGENTS.md")" = "# my own router" ] \
  && [ -f "$TMP_REPO/AGENTS.md.proposed" ]; then
  ok "setup harness proposes beside a human router, never over it"
else
  bad "router scaffold clobbered a user file"
fi

# ---------------------------------------------------------------------------
# WP4 — settlement is scoped, ordered, and policy-consistent
# ---------------------------------------------------------------------------
# Its own disposable repo: earlier rows deliberately leave branches, blocked
# receipts and a dirty tree behind, and settlement assertions must not inherit
# that state or they test the leftovers instead of the behaviour.
# ---------------------------------------------------------------------------
# The loop must work in a workspace NESTED inside a larger repo
# ---------------------------------------------------------------------------
# Every earlier row builds a repo whose root IS the workspace, which is the one
# layout where git-root anchoring cannot be told apart from workspace anchoring.
# Real projects put the workspace in a subdirectory, and there the loop was
# resolving the tasks dir, the contract and the eval's cwd against the wrong
# directory — it could not find its own task.
NEST_REPO="$(mktemp -d -t cvg-nestloop.XXXXXX)"
git -C "$NEST_REPO" init --quiet
pin_branch "$NEST_REPO"
git -C "$NEST_REPO" config user.email nest@test.local
git -C "$NEST_REPO" config user.name "nest test"
WS="$NEST_REPO/projects/demo"
mkdir -p "$WS/cvg/tasks"
cp "$FIXTURE" "$WS/cvg/tasks/T-20260602-golden.md"
printf '# readme\n' > "$WS/README.md"
printf '# root\n' > "$NEST_REPO/README.md"
(
  cd "$WS"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" TASKSPEC_WORKSPACE_ROOT="$WS" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by nest cvg/tasks/T-20260602-golden.md >/dev/null 2>&1
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind --task cvg/tasks/T-20260602-golden.md >/dev/null 2>&1
) || true
git -C "$NEST_REPO" add -A >/dev/null 2>&1
git -C "$NEST_REPO" commit --quiet -m baseline >/dev/null 2>&1

set +e
NEST_OUT="$(cd "$WS" && TASKSPEC_SIGNING_KEY="$KEY_FILE" bash "$EVAL_RUNNER" \
  --issue T-20260602-golden 2>&1)"
set -e
if ! grep -qE 'could not resolve|does not exist yet|contract is missing' <<<"$NEST_OUT"; then
  ok "the loop resolves its task, contract and eval cwd in a nested workspace"
else
  bad "the loop cannot find its own task in a nested workspace: $(head -3 <<<"$NEST_OUT" | tail -1)"
fi

# The contract must be found beside the specs, not at the git root.
if [ -f "$WS/cvg/execution/T-20260602-golden/execution-profile.yaml" ] \
  && [ ! -e "$NEST_REPO/cvg/execution" ]; then
  ok "bind writes the contract into the workspace, not the repo root"
else
  bad "the contract landed outside the workspace"
fi
mkdir -p "$WS/cvg/tasks/done"
mv "$WS/cvg/tasks/T-20260602-golden.md" "$WS/cvg/tasks/done/"
set +e
LANDED_OUT="$(
  cd "$WS" &&
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind --check \
    --profile cvg/execution/T-20260602-golden/execution-profile.yaml 2>&1
)"
LANDED_RC=$?
set -e
if [ "$LANDED_RC" -eq 0 ] && grep -q '^CHECK_RUNTIME_CONTRACT=PASS$' <<<"$LANDED_OUT"; then
  ok "a profile remains verifiable after its task lands in tasks/done"
else
  bad "canonical task completion made its profile look stale: $LANDED_OUT"
fi
rm -rf "$NEST_REPO"

WP4_REPO="$(mktemp -d -t cvg-wp4.XXXXXX)"
git -C "$WP4_REPO" init --quiet
pin_branch "$WP4_REPO"
git -C "$WP4_REPO" config user.email wp4@test.local
git -C "$WP4_REPO" config user.name "wp4 test"
mkdir -p "$WP4_REPO/tasks"
cp "$FIXTURE" "$WP4_REPO/tasks/T-20260602-golden.md"
printf '# readme\n' > "$WP4_REPO/README.md"
(
  cd "$WP4_REPO"
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" gate --stamp --stamp-by wp4 tasks/T-20260602-golden.md >/dev/null 2>&1
  TASKSPEC_SIGNING_KEY="$KEY_FILE" CVG_HOME="$TOOL_HOME" "$CVG" bind --task tasks/T-20260602-golden.md >/dev/null 2>&1
  git add -A && git commit --quiet -m "baseline"
  printf '/cvg/receipts/*.json\n/cvg/execution/*/task-handoff.json\n' >> .git/info/exclude
  mkdir -p cvg/execution/T-20260602-golden
  TASKSPEC_SIGNING_KEY="$KEY_FILE" \
    "$TASKSPEC_ENGINE" handoff tasks/T-20260602-golden.md --backend any \
      --out cvg/execution/T-20260602-golden/task-handoff.json >/dev/null
) || true
WP4_HANDOFF="$WP4_REPO/cvg/execution/T-20260602-golden/task-handoff.json"

# The authorized change alone must settle — locally, because external writes are
# denied by the profile. The artifact and the behaviour have to agree.
printf 'authorized change\n' >> "$WP4_REPO/README.md"
set +e
LOCAL_OUT="$(cd "$WP4_REPO" && TASKSPEC_SIGNING_KEY="$KEY_FILE" bash "$OPEN_PR" \
  --issue T-20260602-golden --tasks-dir tasks --base main --handoff "$WP4_HANDOFF" 2>&1)"
LOCAL_RC=$?
set -e
if [ "$LOCAL_RC" -eq 0 ] \
  && grep -q '^TASK_LOOP=LOCAL_SETTLED$' <<<"$LOCAL_OUT" \
  && ! grep -q 'git push' <<<"$LOCAL_OUT"; then
  ok "external_writes=deny settles locally — no push, no PR (WP4)"
else
  bad "settlement ignored the external-writes policy: $LOCAL_OUT"
fi

# The success receipt exists only because settlement actually happened.
if python3 -c "
import json
r = json.load(open('$WP4_REPO/cvg/receipts/T-20260602-golden.json'))
assert r['result'] == 'pass', r['result']
" 2>/dev/null; then
  ok "the success receipt is written after settlement, not before (WP4)"
else
  bad "receipt ordering is wrong"
fi

# An UNTRACKED out-of-scope file must never be staged. `git add -A` swept it in,
# and the postflight guard reads the DIFF, which never lists untracked files.
git -C "$WP4_REPO" checkout --quiet main 2>/dev/null || true
mkdir -p "$WP4_REPO/src"
printf 'smuggled\n' > "$WP4_REPO/src/not-authorized.py"
printf 'more authorized\n' >> "$WP4_REPO/README.md"
set +e
(cd "$WP4_REPO" && TASKSPEC_SIGNING_KEY="$KEY_FILE" bash "$OPEN_PR" \
  --issue T-20260602-golden --tasks-dir tasks --base main --handoff "$WP4_HANDOFF" >/dev/null 2>&1)
set -e
SMUGGLED="$(git -C "$WP4_REPO" log --all --name-only --format= 2>/dev/null | grep -c 'not-authorized' || true)"
if [ "${SMUGGLED//[^0-9]/}" = "0" ]; then
  ok "an untracked out-of-scope file never reaches a commit (WP4)"
else
  bad "an out-of-scope file was committed"
fi
rm -rf "$WP4_REPO"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS — %s runtime-contract checks green.\n' "$PASS"
  exit 0
fi
printf 'FAIL — %s of %s runtime-contract checks red.\n' "$FAIL" "$((PASS + FAIL))" >&2
exit 1
