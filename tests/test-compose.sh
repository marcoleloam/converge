#!/usr/bin/env bash
# Deterministic cross-repository contract test for cvg compose. Bash 3.2 safe.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CVG="$ROOT/bin/cvg"
SEAMWISE_BIN="${CVG_SEAMWISE_BIN:-$(command -v seamwise 2>/dev/null || true)}"
TASKSPEC_BIN="${CVG_TASKSPEC_BIN:-$(command -v taskspec 2>/dev/null || true)}"
SCHEMA_PYTHON="${COMPOSE_JSONSCHEMA_PYTHON:-python3}"
T=0
F=0
ok() { T=$((T + 1)); printf 'ok    %s\n' "$1"; }
bad() { T=$((T + 1)); F=$((F + 1)); printf 'FAIL  %-35s %s\n' "$1" "$2"; }

if [ ! -x "$SEAMWISE_BIN" ] || [ ! -x "$TASKSPEC_BIN" ]; then
  echo "COMPOSE_TEST=ENGINE_UNAVAILABLE"
  exit 3
fi
if ! "$SCHEMA_PYTHON" -c "import jsonschema" >/dev/null 2>&1; then
  echo "COMPOSE_TEST=JSONSCHEMA_UNAVAILABLE set COMPOSE_JSONSCHEMA_PYTHON to a python with jsonschema" >&2
  exit 3
fi

ROOM="$(mktemp -d -t cvg-compose.XXXXXX)"
trap 'rm -rf "$ROOM"' EXIT
git -C "$ROOM" init --quiet
git -C "$ROOM" config user.name composed-test
git -C "$ROOM" config user.email composed-test@example.invalid
cp "$ROOT/tests/fixtures/composed-health-recipe.yaml" "$ROOM/recipe.yaml"
printf '# composed health fixture\n' > "$ROOM/README.md"
git -C "$ROOM" add recipe.yaml README.md
git -C "$ROOM" commit --quiet -m "pin composed source"

run() {
  (
    cd "$ROOM" || exit 1
    CVG_HOME="$ROOT" CVG_PROJECT_ROOT="$ROOM" \
      CVG_SEAMWISE_BIN="$SEAMWISE_BIN" CVG_TASKSPEC_BIN="$TASKSPEC_BIN" \
      "$CVG" "$@"
  )
}
field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}
state_hash() {
  find "$ROOM" -path "$ROOM/.git" -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s\0' "${file#"$ROOM"/}"
    shasum -a 256 "$file"
  done | shasum -a 256 | awk '{print $1}'
}

OUT="$(TASKSPEC_BIN="$ROOM/missing-taskspec" run --json compose status 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["contract"]')" = "ConvergeCLIResult/v1" ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=BLOCKED" ] \
  && [ "$(printf '%s' "$OUT" | field 'd["changed"]')" = "False" ]; then
  ok "fresh status needs only Seamwise and names prepare"
else
  bad "fresh compose status" "rc=$RC $OUT"
fi

BEFORE="$(state_hash)"
OUT="$(TASKSPEC_BIN="$ROOM/missing-taskspec" run decompose --source recipe.yaml --json 2>/dev/null)"; RC=$?
AFTER="$(state_hash)"
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=NEEDS_REVIEW" ] \
  && [ "$(printf '%s' "$OUT" | field 'd["changed"]')" = "True" ] \
  && [ "$BEFORE" != "$AFTER" ] \
  && [ ! -e "$ROOM/seamwise/task-plan.json" ]; then
  ok "decompose delegates to Seamwise without requiring Task-Spec"
else
  bad "prepare review boundary" "rc=$RC $OUT"
fi

OUT="$(run --json compose preview 2>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=BLOCKED" ] \
  && [ ! -e "$ROOM/cvg/tasks/T-20260815-health-status.md" ]; then
  ok "preview cannot skip human review"
else
  bad "missing-review rejection" "rc=$RC $OUT"
fi

OUT="$(TASKSPEC_BIN="$ROOM/missing-taskspec" run --json compose review --reviewer release-owner --reason "single task topology accepted" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=PREVIEW_READY" ] \
  && [ -f "$ROOM/seamwise/reviews/delivery-plan-review.json" ] \
  && [ ! -e "$ROOM/seamwise/task-plan.json" ]; then
  ok "review records acceptance and performs no compilation"
else
  bad "review-only authority" "rc=$RC $OUT"
fi

OUT="$(TASKSPEC_BIN="$ROOM/missing-taskspec" run compose preview --json 2>/dev/null)"; RC=$?
if [ "$RC" -eq 3 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=ENGINE_UNAVAILABLE" ] \
  && [ ! -e "$ROOM/cvg/tasks/T-20260815-health-status.md" ]; then
  ok "preview fails closed when Task-Spec is unavailable"
else
  bad "preview Task-Spec boundary" "rc=$RC $OUT"
fi

OUT="$(run compose preview --json 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=PREVIEW_READY" ] \
  && [ -f "$ROOM/seamwise/task-plan.json" ] \
  && [ -f "$ROOM/seamwise/task-plan-lineage.json" ] \
  && [ ! -e "$ROOM/cvg/tasks/T-20260815-health-status.md" ]; then
  ok "preview validates the reviewed TaskPlan without Task-Spec Markdown"
else
  bad "preview projection" "rc=$RC $OUT"
fi

cp "$ROOM/seamwise/task-plan.json" "$ROOM/task-plan.keep"
python3 - "$ROOM/seamwise/task-plan.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["metadata"]["name"] = "tampered"
path.write_text(json.dumps(value, sort_keys=True) + "\n")
PY
OUT="$(run --json compose materialize 2>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=BLOCKED" ] \
  && [ ! -e "$ROOM/cvg/tasks/T-20260815-health-status.md" ]; then
  ok "TaskPlan tamper is rejected before materialization"
else
  bad "TaskPlan tamper rejection" "rc=$RC $OUT"
fi
mv "$ROOM/task-plan.keep" "$ROOM/seamwise/task-plan.json"

OUT="$(run --json compose materialize 2>/dev/null)"; RC=$?
RECEIPT="$ROOM/cvg/receipts/composition/composition-receipt.json"
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=MATERIALIZED" ] \
  && [ -f "$RECEIPT" ] \
  && "$SCHEMA_PYTHON" - "$RECEIPT" "$ROOT/contracts/converge-composition-receipt-v1.schema.json" <<'PY'
import json, jsonschema, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
schema = json.loads(pathlib.Path(sys.argv[2]).read_text())
jsonschema.Draft202012Validator.check_schema(schema)
jsonschema.validate(value, schema)
assert value["contract"] == "ConvergeCompositionReceipt/v1"
assert value["dispatch_authorized"] is False
assert value["versions"] == {
    "converge": "0.2.1",
    "seamwise": "0.2.0",
    "task_spec": "3.8.0",
}
assert [item["task_id"] for item in value["tasks"]] == ["T-20260815-health-status"]
assert len(value["source"]["commit"]) == 40
PY
then
  ok "materialize persists a schema-valid non-authorizing receipt"
else
  bad "composition materialization" "rc=$RC $OUT"
fi

SPEC="$ROOM/cvg/tasks/T-20260815-health-status.md"
if grep -q '^signed_off: false$' "$SPEC" \
  && grep -q '"dispatch_authorized":false' "$ROOM/cvg/receipts/composition/taskspec-materialization-receipt.json"; then
  ok "materialization grants no dispatch authority"
else
  bad "dispatch authority" "task or receipt is already authorized"
fi

RECEIPT_SHA="$(shasum -a 256 "$RECEIPT" | awk '{print $1}')"
OUT="$(run --json compose materialize 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["changed"]')" = "False" ] \
  && [ "$RECEIPT_SHA" = "$(shasum -a 256 "$RECEIPT" | awk '{print $1}')" ]; then
  ok "exact materialize rerun is byte-idempotent"
else
  bad "materialize idempotence" "rc=$RC $OUT"
fi

cp "$SPEC" "$ROOM/spec.keep"
printf '\n# tamper\n' >> "$SPEC"
OUT="$(run --json compose status 2>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=BLOCKED" ]; then
  ok "status rejects a stale task-set receipt"
else
  bad "stale receipt rejection" "rc=$RC $OUT"
fi
mv "$ROOM/spec.keep" "$SPEC"

cp "$RECEIPT" "$ROOM/receipt.keep"
python3 - "$RECEIPT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["source"]["commit"] = "0" * 40
path.write_text(json.dumps(value, sort_keys=True) + "\n")
PY
OUT="$(run --json compose status 2>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=BLOCKED" ]; then
  ok "status rejects an unresolvable immutable source commit"
else
  bad "immutable source rejection" "rc=$RC $OUT"
fi
mv "$ROOM/receipt.keep" "$RECEIPT"

rm -f "$RECEIPT"
OUT="$(run --json compose materialize 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=MATERIALIZED" ] \
  && [ -f "$RECEIPT" ]; then
  ok "interrupted receipt finalization recovers idempotently"
else
  bad "interrupted materialization recovery" "rc=$RC $OUT"
fi

STUB="$ROOM/incompatible-seamwise"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"contract":"SeamwiseCLIResult/v1","engine_version":"9.0.0","exit_code":0,"data":{"contract":"SeamwiseCapabilities/v1","engine_major":9,"engine_version":"9.0.0","contracts":{},"materializes_tasks":false,"dispatch_authority":false}}'
STUB
chmod +x "$STUB"
OUT="$(SEAMWISE_BIN="$STUB" run --json compose status 2>/dev/null)"; RC=$?
if [ "$RC" -eq 3 ] \
  && [ "$(printf '%s' "$OUT" | field 'd["token"]')" = "COMPOSE=ENGINE_UNAVAILABLE" ]; then
  ok "incompatible engine fails capability negotiation"
else
  bad "incompatible engine rejection" "rc=$RC $OUT"
fi

echo "RESULTS: $T checks, $F failures"
if [ "$F" -eq 0 ]; then
  echo "COMPOSE_TEST=PASS"
  exit 0
fi
echo "COMPOSE_TEST=FAIL"
exit 1
