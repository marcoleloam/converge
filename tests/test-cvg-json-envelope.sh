#!/bin/bash
# test-cvg-json-envelope.sh — the agent-native output layer (cvg 0.2.1):
# the uniform --json response envelope {ok,data,error,meta,…} on every command, and
# --dry-run on mutations. Proves, discriminating:
#   · the envelope carries every SOTA key + a versioned meta
#   · pass / fail / usage-error map to ok + exit_code + error correctly
#   · the underlying exit code is PRESERVED through the envelope
#   · --json is position-independent and leaves the DEFAULT path byte-parity-exact
#   · --dry-run on a mutation changes nothing (changed=false / dry_run=true)
#   · snapshot remains enveloped at data.snapshot and holds THE BARRIER
#   · agent-context, help, and version use the same universal envelope
# bash 3.2-safe. Python is stdlib-only. Uses product-neutral skill fixtures.
# shellcheck disable=SC2015  # file-wide, intentional: `A && B || bad` — ok()/bad() ARE the branches (ok always returns 0)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CVG="$ROOT/bin/cvg"
PG="$ROOT"
GOOD_BRD="skills/idea-to-brd/tests/fixtures/brd-canonical.md"
BAD="$ROOT/skills/reqs-to-swimlane-plans/tests/fixtures/no-thread"
T=0; F=0
ok()  { T=$((T + 1)); printf 'ok    %s\n' "$1"; }
bad() { T=$((T + 1)); F=$((F + 1)); printf 'FAIL  %-34s %s\n' "$1" "$2"; }

# Run cvg from the repository root with CVG_HOME resolved; stdout only.
jrun() { ( cd "$PG" && CVG_HOME="$ROOT" "$CVG" "$@" ) 2>/dev/null; }
# extract a python expression over the parsed envelope `d`
jget() { python3 -c "import json,sys
d=json.load(sys.stdin)
v=($1)
print('' if v is None else v)"; }

echo "== cvg --json envelope + --dry-run (agent-native SOTA) =="

# --- envelope shape ---
O="$(jrun --json capture "$GOOD_BRD")"
if printf '%s' "$O" | python3 -c "import json,sys
d=json.load(sys.stdin)
need=['ok','command','converge_pass','token','verdict','exit_code','changed','dry_run','data','error','warnings','meta']
assert all(k in d for k in need), [k for k in need if k not in d]
assert set(['ok','data','error','meta']).issubset(d)
assert d['contract']=='ConvergeCLIResult/v1' and d['schema_version']==1
assert d['meta']['schema_version']=='1.0' and d['meta']['tool']=='cvg' and d['meta']['cvg_version']
" 2>/dev/null; then ok "envelope shape + meta{schema_version,version}"; else bad "envelope shape" "missing keys/meta"; fi

# --- pass ---
O="$(jrun --json capture "$GOOD_BRD")"
[ "$(printf '%s' "$O" | jget "d['ok']")" = "True" ] \
  && [ "$(printf '%s' "$O" | jget "d['token']")" = "CHECK_BRD=PASS" ] \
  && [ "$(printf '%s' "$O" | jget "d['verdict']")" = "PASS" ] \
  && [ "$(printf '%s' "$O" | jget "d['exit_code']")" = "0" ] \
  && [ "$(printf '%s' "$O" | jget "d['changed']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['error']")" = "" ] \
  && ok "pass: ok/token/verdict/exit0/changed=false/error=null" || bad "pass envelope" "field mismatch"

# --- retired local decomposition fails with an explicit migration error ---
O="$(jrun --json decompose --dir "$BAD")"
[ "$(printf '%s' "$O" | jget "d['ok']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['exit_code']")" = "2" ] \
  && [ "$(printf '%s' "$O" | jget "d['token']")" = "COMPOSE=BLOCKED" ] \
  && [ "$(printf '%s' "$O" | jget "d['error']['code']")" = "USAGE_ERROR" ] \
  && ok "retired decompose --dir returns a migration usage error" || bad "decompose migration" "field mismatch"

# --- usage error ---
O="$(jrun --json capture --bogus)"
[ "$(printf '%s' "$O" | jget "d['ok']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['exit_code']")" = "2" ] \
  && [ "$(printf '%s' "$O" | jget "d['error']['code']")" = "USAGE_ERROR" ] \
  && ok "usage: ok=false/exit2/error.code=USAGE_ERROR" || bad "usage envelope" "field mismatch"

# --- exit code PRESERVED through the envelope (agents branch on it) ---
( cd "$PG" && CVG_HOME="$ROOT" "$CVG" --json capture --bogus ) >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "exit code preserved (--json → 2)" || bad "exit-code preserved" "got $RC want 2"

# --- position independence: --json before OR after the command ---
A="$(jrun --json capture "$GOOD_BRD" | jget "d['token']")"
B="$(jrun capture "$GOOD_BRD" --json | jget "d['token']")"
[ "$A" = "$B" ] && [ "$A" = "CHECK_BRD=PASS" ] && ok "--json position-independent" || bad "--json position" "before=$A after=$B"

# --- default path is byte-parity-exact (adding --json never changed default output) ---
DA="$( ( cd "$PG" && CVG_HOME="$ROOT" "$CVG" capture "$GOOD_BRD" ) 2>&1 )"
DB="$( ( cd "$PG" && bash "$ROOT/skills/idea-to-brd/scripts/check-brd.sh" "$GOOD_BRD" ) 2>&1 )"
[ "$DA" = "$DB" ] && ok "default byte-parity held (gate untouched)" || bad "default byte-parity" "diverged"
# default emits NO json (first char is not '{')
FC="$( ( cd "$PG" && CVG_HOME="$ROOT" "$CVG" capture "$GOOD_BRD" ) 2>/dev/null | head -c1 )"
[ "$FC" != "{" ] && ok "default output is plain (not JSON)" || bad "default plain" "emitted JSON by default"

# --- --dry-run on a mutation changes nothing ---
O="$(jrun --json --dry-run transition T-nope "done")"
[ "$(printf '%s' "$O" | jget "d['dry_run']")" = "True" ] \
  && [ "$(printf '%s' "$O" | jget "d['changed']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['command']")" = "transition" ] \
  && ok "--dry-run(json) mutation: dry_run=true/changed=false" || bad "dry-run json" "field mismatch"
DR="$( ( cd "$PG" && CVG_HOME="$ROOT" "$CVG" --dry-run transition T-nope "done" ) 2>/dev/null )"
printf '%s' "$DR" | grep -q '^DRY_RUN=OK$' && ok "--dry-run(text) mutation → DRY_RUN=OK" || bad "dry-run text" "no DRY_RUN token"

# --- read-only command with --dry-run is a no-op (still runs, changed=false) ---
O="$(jrun --json --dry-run capture "$GOOD_BRD")"
[ "$(printf '%s' "$O" | jget "d['changed']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['token']")" = "CHECK_BRD=PASS" ] \
  && ok "--dry-run read-only: runs, changed=false" || bad "dry-run read-only" "field mismatch"

# --- subcommand mutability is classified by the exact form, not its parent ---
SPEC="tests/fixtures/T-20260602-golden.md"
STATE_BEFORE="$(git -C "$PG" status --porcelain=v1 --untracked-files=all | shasum -a 256 | awk '{print $1}')"
O="$(jrun --json tasks validate --no-state "$SPEC")"
STATE_AFTER="$(git -C "$PG" status --porcelain=v1 --untracked-files=all | shasum -a 256 | awk '{print $1}')"
[ "$(printf '%s' "$O" | jget "d['changed']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['dry_run']")" = "False" ] \
  && [ "$STATE_BEFORE" = "$STATE_AFTER" ] \
  && ok "tasks validate --no-state is genuinely read-only" \
  || bad "validate --no-state mutability" "envelope or state hash disagreed"

O="$(jrun --json --dry-run tasks gate --stamp-by release-audit "$SPEC")"
[ "$(printf '%s' "$O" | jget "d['dry_run']")" = "True" ] \
  && [ "$(printf '%s' "$O" | jget "d['changed']")" = "False" ] \
  && [ "$(printf '%s' "$O" | jget "d['command']")" = "tasks gate" ] \
  && ok "tasks gate mutates only when an explicit stamp flag is present" \
  || bad "tasks gate stamp mutability" "dry-run did not intercept the stamped form"

# --- WorkspaceSnapshot 3.0: one canonical read-only cockpit contract ---
# Build an equivalent of the analytics proving-ground state from the existing
# product-neutral fixtures: Passes 0-3 are green, Pass 4 has an unresolved
# owner decision, and downstream task evidence already exists. The conductor
# and snapshot must still hold at Pass 4 and never authorize Pass 5.
SNAP_WS="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/cvg-snapshot.$$")"
trap 'rm -rf "$SNAP_WS" 2>/dev/null || true' EXIT
mkdir -p \
  "$SNAP_WS/.cvg" \
  "$SNAP_WS/cvg/docs/brd" \
  "$SNAP_WS/cvg/docs/tech-spec" \
  "$SNAP_WS/cvg/docs/adrs" \
  "$SNAP_WS/cvg/swimlanes" \
  "$SNAP_WS/cvg/tasks/done" \
  "$SNAP_WS/cvg/tasks/parked" \
  "$SNAP_WS/cvg/execution" \
  "$SNAP_WS/cvg/loop" \
  "$SNAP_WS/cvg/receipts"
cp "$ROOT/templates/workspace/INDEX.md" "$SNAP_WS/cvg/INDEX.md"
cp "$ROOT/skills/task-to-runtime-contract/templates/gate.yaml" "$SNAP_WS/.cvg/gate.yaml"
cp "$ROOT/skills/idea-to-brd/tests/fixtures/golden-signed-brd.md" \
  "$SNAP_WS/cvg/docs/brd/snapshot.md"
cp "$ROOT/skills/brd-docs-to-tech-req/tests/fixtures/golden-signed-tech-spec.md" \
  "$SNAP_WS/cvg/docs/tech-spec/snapshot.md"
cp -R "$ROOT/skills/reqs-to-swimlane-plans/tests/fixtures/good/." \
  "$SNAP_WS/cvg/swimlanes/"
cp "$ROOT/tests/fixtures/T-20260602-golden.md" \
  "$SNAP_WS/cvg/tasks/T-20260602-golden.md"
sed -i.bak 's/^signed_off: false$/signed_off: true/' \
  "$SNAP_WS/cvg/tasks/T-20260602-golden.md"
rm -f "$SNAP_WS/cvg/tasks/T-20260602-golden.md.bak"

cat > "$SNAP_WS/cvg/docs/CONTEXT.md" <<'EOF'
# CONTEXT — pinned vocabulary

- **capture**: moving source rows into the analytical lane unchanged.
- **gold**: the modelled layer a consumer is allowed to read.
EOF
cat > "$SNAP_WS/cvg/docs/adrs/0000-context.md" <<'EOF'
---
adr: "0000"
status: accepted
date: 2026-07-29
ground: brownfield
converge_pass: 2
spec_ref: "R-1"
supersedes: ""
superseded_by: ""
deciders: "owner"
---

# 0000 — Context: the ground we stand on

## Terrain

Brownfield: an operational database already serves the application.

## Given surface

Orders and payments are durable operational records.

## Build surface

The analytical lane: capture, transform, and serve.

## Spec

The signed technical specification under cvg/docs/tech-spec/.
EOF
cat > "$SNAP_WS/cvg/docs/adrs/0001-payments-link.md" <<'EOF'
---
adr: "0001"
status: accepted
date: 2026-07-29
ground: brownfield
converge_pass: 2
spec_ref: "R-1"
supersedes: ""
superseded_by: ""
deciders: "owner"
---

# 0001 — payments link to orders on order_id

## Context

A planner would otherwise guess how payments attach to products.

## Decision

`payments.order_id` is the only column linking payments to orders. No
`payments.product_id` exists in this schema.

## Rejected reading

That payments carried a product reference directly. The column is absent.

## Evidence

```sh
printf '%s\n' 'payment_id order_id amount status'
```

observed: payment_id, order_id, amount, status, and created_at.

## Consequences

Product attribution travels through orders.
Re-verify when: the payments table gains or loses a column.
EOF

# The derived index deliberately lies. Snapshot work/stats must come from the
# canonical Task-Spec frontmatter, never from this rebuildable projection.
cat > "$SNAP_WS/cvg/tasks/_state.yaml" <<'EOF'
schema_version: 1
last_rebuilt: 1970-01-01T00:00:00Z
tasks:
stats:
  total: 99
  ready: 0
  in_progress: 0
  blocked: 0
  done: 99
  parked: 0
EOF
: > "$SNAP_WS/cvg/tasks/_metrics.jsonl"
python3 "$ROOT/skills/sketch-plans-adversarial-review/tests/gen-log.py" \
  "$SNAP_WS/cvg/swimlanes" unresolved >/dev/null

srun() {
  (
    cd "$SNAP_WS" &&
      CVG_HOME="$ROOT" CVG_PROJECT_ROOT="$SNAP_WS" "$CVG" "$@"
  ) 2>/dev/null
}

SO="$(srun --json snapshot)"
if printf '%s' "$SO" | python3 -c "import json,sys
d=json.load(sys.stdin)
s=d['data']['snapshot']
assert d['ok'] is True and d['command']=='snapshot'
assert d['changed'] is False and d['dry_run'] is False
assert set(d['data']) == {'snapshot'}
assert s['schemaVersion']=='3.0' and s['source']=='workspace'
assert __import__('re').fullmatch(r'ws3_[0-9a-f]{32}',s['snapshotId'])
assert s['decomposition']['availability']=='available'
assert [x['id'] for x in s['decomposition']['swimlanes']]==['swimlane-checkout']
assert s['method']['activePassId']=='pass-4'
assert all(s['method']['passes'][i]['gate']['ok'] is True for i in range(4))
assert s['method']['passes'][4]['gate']['ok'] is False
failed=[x for x in s['signals'] if x['kind']=='gate' and x.get('entity',{}).get('id')=='pass-4']
assert len(failed)==1 and failed[0]['severity']=='error'
assert s['review']['unresolvedCount'] > 0
assert s['authorization']['state']=='blocked'
assert s['authorization']['nextPassId']=='pass-4'
assert s['authorization']['command']=='cvg review --check'
assert s['authorization']['mutation']=='non_mutating'
assert s['authorization']['dryRunSupported'] is True
assert s['authorization']['enabled'] is True
assert s['work']['stats']['total']==1 and s['work']['stats']['ready']==1
assert s['work']['frontier']['taskIds']==['T-20260602-golden']
assert all('position' not in p for p in s['method']['passes'])
assert all('content' not in a for a in s['artifacts'])
assert all(not a['path'].startswith('/') for a in s['artifacts'])
" 2>/dev/null; then
  ok "snapshot v3 envelope + Pass-4 fail-closed authorization"
else
  bad "snapshot v3 contract" "typed envelope, frontier, or barrier assertion failed"
fi

# Global flag position remains universal for the new command.
SA="$(printf '%s' "$SO" | jget "d['data']['snapshot']['snapshotId']")"
SB="$(srun snapshot --json | jget "d['data']['snapshot']['snapshotId']")"
[ -n "$SA" ] && [ "$SA" = "$SB" ] \
  && ok "snapshot --json position-independent" \
  || bad "snapshot --json position" "before=$SA after=$SB"

# Observation time changes, semantic digest does not. Changing canonical bytes
# then changes the digest even when the parsed task fields remain the same.
sleep 1
SO2="$(srun --json snapshot)"
SID2="$(printf '%s' "$SO2" | jget "d['data']['snapshot']['snapshotId']")"
OBS1="$(printf '%s' "$SO" | jget "d['data']['snapshot']['observedAt']")"
OBS2="$(printf '%s' "$SO2" | jget "d['data']['snapshot']['observedAt']")"
[ "$OBS1" != "$OBS2" ] && [ "$SA" = "$SID2" ] \
  && ok "snapshotId excludes observedAt recursively" \
  || bad "snapshot stable digest" "observedAt or digest did not behave deterministically"
printf '\n' >> "$SNAP_WS/cvg/tasks/T-20260602-golden.md"
SID3="$(srun --json snapshot | jget "d['data']['snapshot']['snapshotId']")"
[ "$SID3" != "$SID2" ] \
  && ok "snapshotId changes with canonical evidence bytes" \
  || bad "snapshot evidence digest" "canonical mutation did not change snapshotId"

# Lane is an explicit local choice. NORMAL asks the conductor for only
# 1→2→5→7→8; the unresolved FULL-only Pass-4 record remains observable but
# cannot become a hidden blocker, and omitted passes are visibly skipped.
printf 'lane=NORMAL\n' > "$SNAP_WS/.cvg/config"
NORMAL="$(srun --json snapshot)"
if printf '%s' "$NORMAL" | python3 -c "import json,sys
s=json.load(sys.stdin)['data']['snapshot']
statuses={p['order']:p['status'] for p in s['method']['passes']}
gates={p['order']:p['gate']['ok'] for p in s['method']['passes']}
gate_signals={x.get('entity',{}).get('id') for x in s['signals'] if x['kind']=='gate'}
assert s['project']['lane']=='NORMAL'
assert s['method']['activePassId']=='pass-7'
assert statuses=={0:'skipped',1:'complete',2:'complete',3:'skipped',4:'skipped',5:'complete',6:'optional',7:'active',8:'waiting'}
assert gates[1] is True and gates[2] is True
assert all(gates[i] is None for i in (0,3,4,5,6,7,8))
assert gate_signals=={'pass-1','pass-2'}
assert s['authorization']['state']=='allowed'
assert s['authorization']['nextPassId']=='pass-7'
assert s['authorization']['command']=='cvg bind --check --profile <profile>'
assert not any(i['code'] in {'PASS_GATE_BLOCKED','REVIEW_UNRESOLVED'} for i in s['issues'])
" 2>/dev/null; then
  ok "snapshot honors canonical NORMAL lane without omitted-pass blockers"
else
  bad "snapshot NORMAL lane" "lane order, skipped passes, or authorization drifted"
fi

# A configured lane is a strict enum, never silently coerced from prose.
printf 'lane=normal\n' > "$SNAP_WS/.cvg/config"
INVALID_LANE="$(srun --json snapshot)"; INVALID_LANE_RC=$?
if [ "$INVALID_LANE_RC" -eq 2 ] \
  && printf '%s' "$INVALID_LANE" | python3 -c "import json,sys
d=json.load(sys.stdin)
assert d['ok'] is False and d['exit_code']==2
assert d['error']['code']=='USAGE_ERROR'
assert 'invalid lane' in d['error']['message']
" 2>/dev/null; then
  ok "snapshot fails closed on an invalid configured lane"
else
  bad "snapshot invalid lane" "invalid lane was accepted or not enveloped"
fi

# The checked-in schema and emitted top-level contract must agree without
# requiring a third-party JSON Schema runtime in the zero-dependency CLI.
printf '%s' "$SO" | python3 -c "import json,sys
d=json.load(sys.stdin)
s=d['data']['snapshot']
schema=json.load(open('$ROOT/contracts/ui/v3/workspace-snapshot.schema.json'))
assert set(schema['required']) == set(s)
assert schema['properties']['schemaVersion']['const'] == s['schemaVersion']
assert schema['properties']['source']['enum'] == ['workspace','fixture']
" 2>/dev/null \
  && ok "snapshot v3 checked-in schema matches emitted surface" \
  || bad "snapshot schema" "schema is invalid or top-level keys drifted"

# Discoverability and read-only classification are part of the CLI contract.
printf '%s\n' "$(jrun help)" | grep -q '^  snapshot ' \
  && ok "snapshot is discoverable in help" \
  || bad "snapshot help" "command is missing"
jrun agent-context | python3 -c "import json,sys
d=json.load(sys.stdin)
rows=[c for c in d['commands'] if c['name']=='snapshot']
assert len(rows)==1 and rows[0]['mutating'] is False
" 2>/dev/null \
  && ok "agent-context declares snapshot non-mutating" \
  || bad "snapshot agent-context" "missing or mutating"

# --- agent-context participates in the universal --json envelope ---
jrun --json agent-context | python3 -c "import json,sys
d=json.load(sys.stdin)
assert d['contract']=='ConvergeCLIResult/v1' and d['ok'] is True
manifest=d['data']['agent_context']
assert manifest.get('tool')=='cvg' and len(manifest['commands'])==60" 2>/dev/null \
  && ok "agent-context uses the universal envelope" || bad "agent-context under --json" "missing envelope or matrix"

# Help and version are no longer exceptions to the machine contract.
jrun help --json | python3 -c "import json,sys
d=json.load(sys.stdin)
assert d['contract']=='ConvergeCLIResult/v1' and d['command']=='help' and d['ok'] is True
assert 'compose materialize' in d['data']['output']" 2>/dev/null \
  && ok "help uses ConvergeCLIResult/v1" || bad "help under --json" "not universally enveloped"
jrun --json version | python3 -c "import json,sys
d=json.load(sys.stdin)
assert d['contract']=='ConvergeCLIResult/v1' and d['command']=='version' and d['ok'] is True
assert '0.2.1' in d['data']['output']" 2>/dev/null \
  && ok "version uses ConvergeCLIResult/v1" || bad "version under --json" "not universally enveloped"

echo
if [ "$F" -eq 0 ]; then echo "PASS — all $T rows green."; exit 0
else echo "FAIL — $F of $T rows red." >&2; exit 1; fi
