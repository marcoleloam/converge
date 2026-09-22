#!/usr/bin/env bash
# test-loop-kernel.sh — Pass 8's loop, and specifically its BRAKES.
#
# The loop's value is not that it iterates; a `while true` iterates. The value is
# that it always lands in a named terminal state, that an error or an exhausted
# budget is never reported as success, and that it stops as soon as more
# iterations cannot help. Those are the properties tested here.
#
# Every row uses a STUB engine, so the suite is hermetic: no model is called, no
# token is spent, and the result does not depend on how a real engine happens to
# behave today.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
KERNEL="$SRC/skills/task-loop/scripts/loop-kernel.sh"
FIXTURE="$SRC/tests/fixtures/T-20260602-golden.md"
TASKSPEC_ENGINE="${CVG_TASKSPEC_BIN:-${TASKSPEC_BIN:-taskspec}}"
CVG="$SRC/bin/cvg"
PASS=0; FAIL=0
ok()  { printf '  ok   — %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL — %s\n' "$1"; FAIL=$((FAIL + 1)); }

KEY="$(mktemp -t cvg-loopkey.XXXXXX)"; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$KEY"
# Stub engines live HERE, never in the shipped adapter directory.
STUBS="$(mktemp -d -t cvg-loopstubs.XXXXXX)"

echo "=================================================================="
echo "Pass 8 · the loop kernel"
echo "=================================================================="

# --- PRECONDITION: this suite needs a host that can SIGN a spec ---------------
# new_ws() below stamps the fixture with safe-to-delegate and then binds it, both
# with output discarded. safe-to-delegate passes --shellcheck-evals unconditionally,
# so on a host without shellcheck the stamp BLOCKS, signed_off stays false, bind
# refuses the unsigned spec, no execution profile is written, and every row that
# needs a real loop lands TASK_LOOP=ERROR. That is 29 of 52 rows red for a reason
# that has nothing to do with the loop — and it survived a bisect across three
# commits, one of which CI had passed, because CI installs shellcheck explicitly.
#
# A suite that cannot run should say SO, once, at the top. The repo already makes
# this argument about secret-gated CI jobs: a silently-skipped gate is worse than
# no gate. A silently-swallowed prerequisite is the same defect wearing a green
# hat — every row fails, so nothing looks like a precondition.
for _need in git shellcheck python3; do
  command -v "$_need" >/dev/null 2>&1 && continue
  echo
  echo "  UNRUNNABLE — '$_need' is not on PATH, and this suite cannot work without it."
  case "$_need" in
    shellcheck)
      echo "    safe-to-delegate always passes --shellcheck-evals, so the fixture's spec"
      echo "    cannot be SIGNED; bind then refuses it and every loop row lands ERROR."
      echo "    fix: brew install shellcheck   (or apt-get install shellcheck)" ;;
    *)
      echo "    fix: install $_need and re-run." ;;
  esac
  echo "    Diagnose the whole toolchain at once with:  cvg doctor host"
  echo
  echo "LOOP_KERNEL_TESTS=UNRUNNABLE"
  exit 3
done

# A workspace whose task is RED, in a repo of its own.
new_ws() {
  W="$(mktemp -d -t cvg-loopws.XXXXXX)"
  git -C "$W" init --quiet
  git -C "$W" config user.email loop@test.local
  git -C "$W" config user.name "loop test"
  printf '/cvg/execution/*/task-handoff.json\n/cvg/loop/\n/cvg/receipts/*.json\n/cvg/STATE.md\n' \
    >> "$W/.git/info/exclude"
  mkdir -p "$W/cvg/tasks" "$W/engines"
  cp "$FIXTURE" "$W/cvg/tasks/T-20260602-golden.md"
  printf '# readme\n' > "$W/README.md"
  ( cd "$W" && TASKSPEC_SIGNING_KEY="$KEY" TASKSPEC_BACKLOG_DIR="$W/cvg/tasks" \
      TASKSPEC_WORKSPACE_ROOT="$W" "$TASKSPEC_ENGINE" gate --stamp --stamp-by loop cvg/tasks/T-20260602-golden.md >/dev/null 2>&1
    TASKSPEC_SIGNING_KEY="$KEY" CVG_HOME="$SRC" "$CVG" bind --task cvg/tasks/T-20260602-golden.md >/dev/null 2>&1 ) || true
  git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m base >/dev/null 2>&1
  # Make the eval RED: the golden fixture asserts NEVERMATCH is absent, so
  # putting it in the file it inspects is a deterministic red.
  printf 'NEVERMATCH\n' >> "$W/README.md"
  printf '%s\n' "$W"
}

# Remove a workspace AND any isolated worktree it still owns.
#
# Rows that land EXHAUSTED, STALLED or BLOCKED deliberately KEEP their worktree
# — the handoff note is useless without the work it describes. Deleting only the
# parent repo therefore orphans that checkout in $TMPDIR: two per suite run,
# forever, and the suite that asserts "a failed run leaves no orphaned worktree
# behind" was itself the thing leaking them. `cvg-wt-` is the kernel's own
# prefix, so it can never match the `cvg-loopws-` workspace being removed.
drop_ws() {
  _dw="$1"
  git -C "$_dw" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2}' | grep '/cvg-wt-' \
    | while IFS= read -r _wt; do
        git -C "$_dw" worktree remove --force "$_wt" >/dev/null 2>&1 || rm -rf "$_wt"
      done
  rm -rf "$_dw"
}

# A stub engine directory the kernel can be pointed at via --agent.
stub_engine() {  # stub_engine <_unused> <name> <body>
  { printf '#!/usr/bin/env bash\nset -uo pipefail\ncase "${1:-}" in --available) exit 0 ;; esac\n'
    printf '%s\n' "$3"; } > "$STUBS/$2.sh"
}
# NO `trap ... EXIT` here. Bash fires an inherited EXIT trap when a `( )`
# SUBSHELL exits, and run_kernel uses one — so a cleanup trap would delete the
# stubs and the signing key partway through the suite, and the later rows would
# fail for reasons that have nothing to do with the loop.

run_kernel() {  # run_kernel <ws> <args...>  -> output; sets RK_RC
  # Rows that are not ABOUT isolation run in-place, so they assert loop
  # behaviour rather than git-worktree behaviour. The default itself is pinned
  # by its own row below.
  _w="$1"; shift
  case " $* " in *" --isolation "*) : ;; *) set -- "$@" --isolation inplace ;; esac
  RK_OUT="$( (cd "$_w" && TASKSPEC_SIGNING_KEY="$KEY" CVG_HOME="$SRC" \
    CVG_ENGINES_DIR="$STUBS" CVG_VERIFIER="${RK_VERIFIER:-$STUBS/verify-uphold.sh}" \
    bash "$KERNEL" --issue T-20260602-golden "$@" 2>&1) )"
  RK_RC=$?
}

# Stub JUDGES. Tier-2 dispatches a real engine and takes minutes; a hermetic
# suite must be able to pin the kernel's REACTION to each verdict without that.
stub_verifier() {  # stub_verifier <name> <body>
  { printf '#!/usr/bin/env bash\nset -uo pipefail\n'; printf '%s\n' "$2"; } > "$STUBS/$1.sh"
}
stub_verifier verify-uphold 'echo "CHECK_VERIFY=UPHELD"; exit 0'
stub_verifier verify-refute 'echo "  - hardcoded lookup table satisfies the assertion"; echo "CHECK_VERIFY=REFUTED"; exit 1'
stub_verifier verify-unavail 'echo "CHECK_VERIFY=UNAVAILABLE"; exit 0'
# Neither a verdict nor a token — the shape of a judge that died mid-sentence.
stub_verifier verify-broken 'echo "judge exploded"; exit 1'

# An engine that always succeeds and never fixes anything — the shape of a loop
# that would otherwise burn its whole budget.
stub_engine "" tstnoop 'echo "stub: changed nothing"; echo "ENGINE_TOKENS=100"; exit 0'
# An engine that actually satisfies the eval on its first attempt.
stub_engine "" tstfix 'sed -i.bak "/NEVERMATCH/d" README.md 2>/dev/null || true; rm -f README.md.bak; echo "stub: fixed it"; exit 0'

# ------------------------------------------------ profile/runtime consistency
W="$(new_ws)"
python3 - "$W/cvg/execution/T-20260602-golden/execution-profile.yaml" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["enforcement"]["primary_runtime"] = "codex"
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
run_kernel "$W" --dry-run
if [ "$RK_RC" -eq 0 ] && grep -q 'with codex' <<<"$RK_OUT"; then
  ok "a vendor-bound profile selects its own execution engine"
else
  bad "the loop ignored primary_runtime: $RK_OUT"
fi
run_kernel "$W" --agent claude --dry-run
if [ "$RK_RC" -eq 2 ] && grep -q "bound to 'codex'" <<<"$RK_OUT"; then
  ok "an explicit engine/profile mismatch fails before execution"
else
  bad "the loop accepted a runtime different from the bound profile"
fi
drop_ws "$W"

# Bound omp is a first-class engine, not a generic fallback. Dry-run so this
# row never calls a model; CVG_ENGINES_DIR stubs are unused here.
W="$(new_ws)"
python3 - "$W/cvg/execution/T-20260602-golden/execution-profile.yaml" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["enforcement"]["primary_runtime"] = "omp"
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
run_kernel "$W" --dry-run
if [ "$RK_RC" -eq 0 ] && grep -q 'with omp' <<<"$RK_OUT"; then
  ok "a bound omp profile selects the omp engine"
else
  bad "the loop ignored primary_runtime omp: $RK_OUT"
fi
run_kernel "$W" --agent claude --dry-run
if [ "$RK_RC" -eq 2 ] && grep -q "bound to 'omp'" <<<"$RK_OUT"; then
  ok "an explicit engine/profile mismatch against omp fails before execution"
else
  bad "the loop accepted a runtime different from the bound omp profile: $RK_OUT"
fi
drop_ws "$W"

# ---------------------------------------------------------------- STALLED
W="$(new_ws)"
run_kernel "$W" --agent tstnoop
if grep -q '^TASK_LOOP=STALLED$' <<<"$RK_OUT" && [ "$RK_RC" -eq 1 ]; then
  ok "an ineffective engine lands STALLED (not SETTLED, not a hang)"
else
  bad "no stagnation landing: $(tail -2 <<<"$RK_OUT" | head -1)"
fi
# It must stop AT the circuit breaker, not run the full budget.
_att="$(grep -c '── attempt ' <<<"$RK_OUT" || true)"
if [ "${_att//[^0-9]/}" -le 4 ] 2>/dev/null; then
  ok "it stops at the circuit breaker (${_att} attempts, not the full 15)"
else
  bad "it burned $_att attempts before stopping"
fi
drop_ws "$W"

# ---------------------------------------------------------------- EXHAUSTED
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 2
if grep -q '^TASK_LOOP=EXHAUSTED$' <<<"$RK_OUT" && [ "$RK_RC" -eq 1 ]; then
  ok "the iteration ceiling lands EXHAUSTED — never SETTLED"
else
  bad "the iteration ceiling did not land EXHAUSTED"
fi
if [ -f "$W/cvg/loop/T-20260602-golden/HANDOFF.md" ]; then
  ok "budget exhaustion is a PLANNED landing — a handoff note is on disk"
else
  bad "no handoff note: exhaustion was a crash, not a landing"
fi
# A handoff that lost its numbers is a handoff nobody can act on. `printf '- x'`
# makes bash read the FORMAT as an option, which silently emptied these lines.
if grep -q '^- iterations:' "$W/cvg/loop/T-20260602-golden/HANDOFF.md" 2>/dev/null \
  && grep -q '^- elapsed:' "$W/cvg/loop/T-20260602-golden/HANDOFF.md" 2>/dev/null; then
  ok "the handoff actually carries the numbers it exists to report"
else
  bad "the handoff note is missing its iteration/elapsed lines"
fi
# The checkpoint must be durable, or a restart silently redoes the work.
if grep -q '^ITER=2$' "$W/cvg/loop/T-20260602-golden/state.env" 2>/dev/null; then
  ok "the loop's position is checkpointed on disk (resumable)"
else
  bad "the loop position was not persisted"
fi
drop_ws "$W"

# ---------------------------------------------------------------- flags tighten only
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 999
_att="$(grep -c '── attempt ' <<<"$RK_OUT" || true)"
if [ "${_att//[^0-9]/}" -le 4 ] 2>/dev/null; then
  ok "a flag cannot RAISE the spec's ceiling, only tighten it"
else
  bad "--max-iterations 999 overrode the spec budget ($_att attempts)"
fi
drop_ws "$W"

# ---------------------------------------------------------------- CANCELLED
W="$(new_ws)"
mkdir -p "$W/cvg/loop/T-20260602-golden"; touch "$W/cvg/loop/T-20260602-golden/STOP"
run_kernel "$W" --agent tstnoop
if grep -q '^TASK_LOOP=CANCELLED$' <<<"$RK_OUT" && [ "$RK_RC" -eq 3 ]; then
  ok "an external stop signal lands CANCELLED before spending anything"
else
  bad "the kill switch was ignored"
fi
drop_ws "$W"

# ---------------------------------------------------------------- NO_OP
W="$(new_ws)"
git -C "$W" checkout -- README.md 2>/dev/null || true   # already green
run_kernel "$W" --agent tstnoop
if grep -q '^TASK_LOOP=NO_OP$' <<<"$RK_OUT" && [ "$RK_RC" -eq 0 ]; then
  ok "an already-green task is a clean NO_OP, not a manufactured success"
else
  bad "an already-green task did not report NO_OP"
fi
drop_ws "$W"

# ---------------------------------------------------------------- green path
W="$(new_ws)"
run_kernel "$W" --agent tstfix
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT" && [ "$RK_RC" -eq 0 ]; then
  ok "an effective engine reaches a real green and settles"
else
  bad "the green path did not settle: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

# ------------------------------------------------------ tier 2 · the gate
# A green eval is necessary, not sufficient. Tier 1 cannot tell a real
# implementation from a lookup table that satisfies the same assertion, so a
# refutation from an engine that did not do the work must STOP settlement.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix --verify
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT" && [ "$RK_RC" -eq 1 ]; then
  ok "tier-2 REFUTED blocks settlement even though the eval went green"
else
  bad "a refuted diff still settled: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
# The refusal has to be legible, or the operator cannot act on it.
if grep -q 'lookup table' <<<"$RK_OUT"; then
  ok "the judge's findings reach the operator, not just the verdict"
else
  bad "tier-2 findings were swallowed"
fi
drop_ws "$W"

# A judge that dies mid-sentence returns no verdict. That is not a pass.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-broken.sh" run_kernel "$W" --agent tstfix --verify
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT"; then
  ok "tier-2 FAILS CLOSED — an unobtainable verdict never settles"
else
  bad "a broken judge was treated as approval"
fi
drop_ws "$W"

# UNAVAILABLE is the one verdict that proceeds: verify-work.py itself permits it
# only for low blast radius, and that judgement belongs to the verifier.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-unavail.sh" run_kernel "$W" --agent tstfix --verify
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT"; then
  ok "UNAVAILABLE proceeds — absence of a judge is not a refutation"
else
  bad "UNAVAILABLE was treated as a block"
fi
drop_ws "$W"

# A delivery may require independent proof even at low blast radius.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-unavail.sh" run_kernel "$W" --agent tstfix --require-independent
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT" && ! grep -q '^ACCEPTED=1' <<<"$RK_OUT"; then
  ok "required independent verification blocks unavailable judges before acceptance"
else
  bad "an unavailable judge was allowed to authorize delivery settlement"
fi
drop_ws "$W"

# Tier 2 is OPT-IN. A judge that would refute must not even be consulted unless
# asked for: it costs a full extra engine dispatch, and making it the default
# meant a judge timing out could block a task whose evals had all passed.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT" \
  && grep -q 'tier 2 ── not requested' <<<"$RK_OUT"; then
  ok "tier 2 is OPT-IN — a refuting judge is not consulted without --verify"
else
  bad "tier 2 ran (or was silent) without being asked: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

# Naming a judge is asking for the check. A --judge that needed --verify beside
# it would be a flag that silently does nothing.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix --judge codex
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT"; then
  ok "--judge implies --verify (a flag that did nothing would be worse)"
else
  bad "--judge did not enable tier 2"
fi
drop_ws "$W"

# The explicit opt-out still wins, so a profile that turns tier 2 on can be
# overridden from the command line.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix --verify --no-verify
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT"; then
  ok "--no-verify overrides an earlier --verify (last flag wins)"
else
  bad "--no-verify could not turn tier 2 back off"
fi
drop_ws "$W"

# ------------------------------------------- evidence lands in the REAL repo
# The settler writes the receipt relative to ITS workspace, which under isolation
# is a temp worktree. So a run that genuinely settled wrote `result: pass` into
# $TMPDIR while the repository kept a STALE receipt — the durable proof of
# success living in a directory `git worktree prune` deletes, next to a repo
# asserting the opposite. STATE.md went to the real workspace and the receipt did
# not: one run, two evidence artifacts, two different roots.
W="$(new_ws)"
# The worktree checks out COMMITTED state, so the red marker has to be committed
# or the isolated run starts green and lands NO_OP.
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
run_kernel "$W" --agent tstfix --isolation worktree
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT"; then
  _rcp="$W/cvg/receipts/T-20260602-golden.json"
  if [ -f "$_rcp" ] && grep -q '"result": *"pass"' "$_rcp"; then
    ok "a settled run's receipt lands in the real workspace, not the worktree"
  else
    bad "the receipt never left the worktree (repo has $( [ -f "$_rcp" ] && grep -o '"result": *"[a-z]*"' "$_rcp" || echo 'no receipt' ))"
  fi
else
  bad "the isolated run did not settle: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi

# ---- a SETTLED run cleans up after itself -----------------------------------
# Settlement's whole job is to COMMIT the work onto a branch, and sync_receipt has
# already carried the receipt home — so the worktree is a duplicate sitting in
# $TMPDIR, which the OS deletes out from under git, leaving a stale registration
# `git worktree list` reports forever. Two accumulated from a single task in one
# afternoon. Runs that end with UNCOMMITTED work still keep theirs; that is the
# distinction, not "success vs failure".
_left="$(git -C "$W" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep -c '/cvg-wt-' || true)"
if [ "${_left:-0}" -eq 0 ]; then
  ok "a settled run leaves NO worktree behind (its work is on a branch)"
else
  bad "a settled run left $_left worktree(s) registered — they accumulate in \$TMPDIR"
fi
if git -C "$W" branch --list 'loop/*' | grep -q .; then
  bad "the scratch loop/* branch outlived the settled run"
else
  ok "and the scratch loop/* branch is deleted with it"
fi
if git -C "$W" branch --list 'task/*' | grep -q .; then
  ok "the task/* branch SURVIVES — that is where the committed work lives"
else
  bad "the settled work's branch was deleted along with the worktree"
fi
case "$RK_OUT" in
  *"worktree removed"*) ok "and it says so, naming where the work went" ;;
  *) bad "a silent removal reads as 'where did my work go' after a \$TMPDIR run" ;;
esac
drop_ws "$W"

# ---- ...unless the operator asks to keep it ---------------------------------
W="$(new_ws)"
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
run_kernel "$W" --agent tstfix --isolation worktree --keep-worktree
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT"; then
  _kept="$(git -C "$W" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep -c '/cvg-wt-' || true)"
  if [ "${_kept:-0}" -ge 1 ]; then
    ok "--keep-worktree overrides the cleanup on a settled run"
  else
    bad "--keep-worktree did not keep the worktree"
  fi
else
  bad "--keep-worktree changed the landing state: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

# ------------------------------------------------------ the cost dial (lane)
# One setting for every task is what made a four-file build cost $7.91: bare
# `claude -p`, top model, flat 900s. `cvg lane` classified the work and the
# verdict reached nothing. These rows pin that it now reaches the engine.
W="$(new_ws)"
run_kernel "$W" --agent tstfix --lane FAST --estimate
if grep -q 'model haiku' <<<"$RK_OUT" && grep -q 'lane FAST' <<<"$RK_OUT"; then
  ok "the lane picks the model tier — FAST does not draw the top engine"
else
  bad "the lane did not reach the model: $(grep -i 'lane\|model' <<<"$RK_OUT" | head -2)"
fi
# attempt_seconds = lane base x effort multiplier, so a long-horizon leaf is not
# guillotined on a cheap lane and a typo fix is not handed 15 minutes.
if grep -qE 'per attempt *: up to (150|225|300|450)s' <<<"$RK_OUT"; then
  ok "the per-attempt cap scales with effort, not a flat 900s"
else
  bad "the attempt cap ignored the dial: $(grep 'per attempt' <<<"$RK_OUT")"
fi
drop_ws "$W"

# A lane may LOWER a ceiling and never RAISE one — the same invariant --max-*
# already obeys, because a routing hint must never widen an authorization.
#
# FULL's table value (15) equals the golden fixture's own budget_iterations, so
# comparing those two proves nothing either way. Pin it against a TIGHTENED
# ceiling instead: --max-iterations 2 with the most generous lane must stay 2.
W="$(new_ws)"
run_kernel "$W" --agent tstfix --lane FULL --max-iterations 2 --estimate
_fullit="$(grep -oE 'attempts *: up to [0-9]+' <<<"$RK_OUT" | grep -oE '[0-9]+$')"
if [ "${_fullit:-999}" -eq 2 ] 2>/dev/null; then
  ok "the most generous lane cannot widen a tightened ceiling (still 2)"
else
  bad "the lane widened a tightened budget to $_fullit"
fi
drop_ws "$W"

# FULL earns tier 2 by default, because high blast radius is where a green eval
# is least sufficient — but the operator still outranks the table.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix --lane FULL
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT"; then
  ok "FULL turns tier 2 on without being asked twice"
else
  bad "FULL did not enable tier 2"
fi
drop_ws "$W"

W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix --lane FULL --no-verify
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT"; then
  ok "an explicit --no-verify outranks the lane's default"
else
  bad "the operator could not decline the lane's verifier"
fi
drop_ws "$W"

# ------------------------------------------------- settlement base reference
# The guard must be asked about the work THIS RUN produced. Cutting the loop
# branch from a non-default branch used to make `main...HEAD` sweep in every
# commit on it — 135 paths judged against a scope of 4 — and settlement was
# refused on work that was entirely in scope.
W="$(new_ws)"
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
git -C "$W" checkout --quiet -b feature/somewhere-else 2>/dev/null
printf 'unrelated\n' > "$W/UNRELATED.md"
git -C "$W" add -A >/dev/null 2>&1
git -C "$W" commit --quiet -m "work that predates the loop" >/dev/null 2>&1
run_kernel "$W" --agent tstfix --isolation worktree
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT" && [ "$RK_RC" -eq 0 ]; then
  ok "a loop branch cut from a FEATURE branch still settles (base is the fork point)"
else
  bad "settlement refused on in-scope work: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
# Prove the mechanism, not just the outcome: pre-existing commits on the feature
# branch must never appear in the guard's diff.
if ! grep -q 'UNRELATED.md' <<<"$RK_OUT"; then
  ok "commits that predate the run are not attributed to it"
else
  bad "the guard was shown work the loop did not do"
fi
drop_ws "$W"

# ------------------------------------------------- resume · the wall clock
# The budget bounds what the loop DOES. Persisting a start timestamp made it
# bound wall time instead: pick a run up the next morning and `now - STARTED_AT`
# already exceeds any budget, so it lands EXHAUSTED without making one attempt —
# a spent budget reported on a run that spent nothing.
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 1
_st="$W/cvg/loop/T-20260602-golden/state.env"
# Backdate the run to 1970 — the state a long pause leaves behind.
sed -i.bak 's/^STARTED_AT=.*/STARTED_AT=1/; s/^ELAPSED_PRIOR=.*/ELAPSED_PRIOR=3/' "$_st" && rm -f "$_st.bak"
run_kernel "$W" --agent tstfix --resume --max-iterations 5
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT"; then
  ok "--resume continues the BUDGET, not the clock (a long pause is not a spend)"
else
  bad "resume after a pause was killed by wall-clock: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

# ---------------------------------------------------------------- gate-only
W="$(new_ws)"
run_kernel "$W" --no-agent
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT"; then
  ok "--no-agent is honest: RED with no attempt is BLOCKED, not STALLED"
else
  bad "--no-agent did not report BLOCKED"
fi
drop_ws "$W"

# ---------------------------------------------------------------- unknown engine
W="$(new_ws)"
run_kernel "$W" --agent doesnotexist
if grep -q '^TASK_LOOP=ERROR$' <<<"$RK_OUT" && [ "$RK_RC" -eq 4 ]; then
  ok "a missing engine is an ERROR, never a silent pass"
else
  bad "a missing engine did not fail closed"
fi
drop_ws "$W"

# ------------------------------- evals must run in the WORKSPACE, not git root
# A spec's relative paths are written against its own workspace. When the runner
# cd'd to the git root instead, every `test -f` failed in 0s without reaching the
# work — a RED indistinguishable from a real failure except by the suspiciously
# round duration. It cost a full engine run to find, because the fix had been
# applied to the inline fallback and NOT to the delegated path that actually runs.
# Build the nested workspace from scratch: copying a BOUND workspace would
# carry an execution profile whose paths point at the old root, which fails for
# a reason that has nothing to do with the working directory.
NEST="$(mktemp -d -t cvg-evalcwd.XXXXXX)"
git -C "$NEST" init --quiet
git -C "$NEST" config user.email cwd@test.local
git -C "$NEST" config user.name "cwd test"
mkdir -p "$NEST/projects/demo/cvg/tasks"
cp "$FIXTURE" "$NEST/projects/demo/cvg/tasks/T-20260602-golden.md"
printf '# readme\n' > "$NEST/projects/demo/README.md"
printf '# root readme\n' > "$NEST/README.md"
(
  cd "$NEST/projects/demo"
  TASKSPEC_SIGNING_KEY="$KEY" TASKSPEC_BACKLOG_DIR="$NEST/projects/demo/cvg/tasks" \
    TASKSPEC_WORKSPACE_ROOT="$NEST/projects/demo" "$TASKSPEC_ENGINE" gate --stamp --stamp-by cwd cvg/tasks/T-20260602-golden.md >/dev/null 2>&1
  TASKSPEC_SIGNING_KEY="$KEY" CVG_HOME="$SRC" "$CVG" bind --task cvg/tasks/T-20260602-golden.md >/dev/null 2>&1
) || true
git -C "$NEST" add -A >/dev/null 2>&1; git -C "$NEST" commit --quiet -m base >/dev/null 2>&1
CWD_OUT="$( (cd "$NEST/projects/demo" && env -u TASKSPEC_WORKSPACE_ROOT TASKSPEC_SIGNING_KEY="$KEY" \
  bash "$SRC/skills/task-loop/scripts/run-issue-eval.sh" --issue T-20260602-golden 2>&1) || true )"
if grep -q '^GREEN$' <<<"$CWD_OUT"; then
  ok "evals run in the WORKSPACE, so a nested project verifies its own files"
else
  bad "evals ran in the wrong directory: $(grep -E '^\[(pass|fail)\]' <<<"$CWD_OUT" | head -1)"
fi
rm -rf "$NEST"

# --------------------------------- the signing key must survive a worktree
# Inside a linked worktree `git rev-parse --git-dir` is <main>/.git/worktrees/<n>,
# which has no info/ of its own. The signing key was therefore invisible, the
# spec silently degraded Tier 1 -> Tier 2 ("no key"), and that read as trust-tier
# DRIFT against a profile bound at Tier 1 — so every worktree run died on a
# contract error that had nothing to do with the task. Now that worktree is the
# DEFAULT, this is the difference between the loop working and not.
W="$(new_ws)"
mkdir -p "$W/.git/info"
cp "$KEY" "$W/.git/info/taskspec-signing-key"
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m keyed >/dev/null 2>&1
WT="$(mktemp -d -t cvg-keywt.XXXXXX)"; rm -rf "$WT"
git -C "$W" worktree add --quiet -b probe/key "$WT" >/dev/null 2>&1
TIER_OUT="$( (cd "$WT" && env -u TASKSPEC_SIGNING_KEY \
  "$TASKSPEC_ENGINE" validate --no-state cvg/tasks/T-20260602-golden.md 2>&1) || true )"
if grep -q 'Tier 1' <<<"$TIER_OUT"; then
  ok "the signing key resolves inside a worktree (Tier 1 survives isolation)"
else
  bad "a worktree cannot see the signing key: $(head -1 <<<"$TIER_OUT")"
fi
git -C "$W" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
drop_ws "$W"

# ------------------------------------------------- isolation is the DEFAULT
# An unattended agent must not be able to touch the tree a human is reading,
# and that has to be true when nobody passes a flag.
W="$(new_ws)"
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
DEF_OUT="$( (cd "$W" && TASKSPEC_SIGNING_KEY="$KEY" CVG_HOME="$SRC" CVG_ENGINES_DIR="$STUBS" \
  bash "$KERNEL" --issue T-20260602-golden --agent tstnoop --max-iterations 1 2>&1) )"
if grep -q 'isolation: worktree' <<<"$DEF_OUT"; then
  ok "isolation defaults to worktree — safety is not opt-in"
else
  bad "the default is still in-place"
fi
drop_ws "$W"

# ----------------------------------------------------- worktree isolation
# In-place, a failed attempt leaves wreckage the NEXT attempt inherits. A
# worktree makes the cost of a bad run exactly zero and keeps an unattended
# agent out of the tree the human is reading.
W="$(new_ws)"
# A worktree is a checkout of COMMITTED state — uncommitted work in the main
# tree is invisible to it. Commit the red-making change or the isolated run
# starts green and reports a NO_OP that means nothing.
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
run_kernel "$W" --agent tstnoop --isolation worktree --max-iterations 1
if grep -q 'isolation: worktree' <<<"$RK_OUT"; then
  ok "the run happens in an isolated worktree, not the live tree"
else
  bad "--isolation worktree did not take effect"
fi
# EXHAUSTED keeps the worktree: a handoff note is useless without the work.
if grep -q 'worktree KEPT' <<<"$RK_OUT"; then
  ok "a landing with work to inspect KEEPS its worktree (resumable)"
else
  bad "the worktree was discarded even though there was work to keep"
fi
drop_ws "$W"

# A run the agent could not even start must leave NOTHING behind.
W="$(new_ws)"
_wt_before="$(git -C "$W" worktree list | wc -l | tr -d ' ')"
run_kernel "$W" --agent doesnotexist --isolation worktree
_wt_after="$(git -C "$W" worktree list | wc -l | tr -d ' ')"
if [ "$_wt_before" = "$_wt_after" ]; then
  ok "a failed run leaves no orphaned worktree behind"
else
  bad "an orphaned worktree survived a failed run"
fi
drop_ws "$W"

# ------------------------------------------- the fence a spec cannot widen
# The contract answers "may THIS task write here?"; the gate answers "may ANY
# task ever write here?". Before the gate, a spec that scoped fs.write to
# auth/ was not a violation — it was an instruction, and everything downstream
# worked perfectly to let an agent edit the auth code.
GW="$(new_ws)"
mkdir -p "$GW/.cvg" "$GW/auth"
printf 'version: 1\ndenylist:\n  - "auth/**"\n  - ".env"\nmax_files: 2\n' > "$GW/.cvg/gate.yaml"
# Settlement trusts policy from its base commit, never a worktree copy an agent
# could delete or weaken. Commit the fixture policy before producing the diff.
git -C "$GW" add .cvg/gate.yaml
git -C "$GW" commit --quiet -m "test gate baseline"
# A contract that explicitly authorizes the forbidden path.
python3 - "$GW/cvg/execution/T-20260602-golden/execution-profile.yaml" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d.get("authority", {}).get("grants", []):
    if g.get("capability") in ("fs.write", "vcs.commit"):
        g["scope"] = ["auth/**", "README.md"]
json.dump(d, open(p, "w"), indent=2)
PYEOF
printf 'secret\n' > "$GW/auth/login.py"
GATE_OUT="$( (cd "$GW" && python3 "$SRC/skills/task-to-runtime-contract/scripts/check-path-policy.py" \
  --profile cvg/execution/T-20260602-golden/execution-profile.yaml --repo "$GW" 2>&1) || true )"
if grep -q 'CHECK_PATH_POLICY=FAIL' <<<"$GATE_OUT" && grep -q 'no spec may widen' <<<"$GATE_OUT"; then
  ok "the repo gate refuses a path the CONTRACT authorized"
else
  bad "a spec widened the repo fence: $(tail -2 <<<"$GATE_OUT" | head -1)"
fi

# Blast radius is orthogonal to paths: all-legal, still too many.
for i in 1 2 3 4; do printf 'x\n' > "$GW/f$i.md"; done
python3 - "$GW/cvg/execution/T-20260602-golden/execution-profile.yaml" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d.get("authority", {}).get("grants", []):
    if g.get("capability") in ("fs.write", "vcs.commit"):
        g["scope"] = ["**"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PYEOF
rm -f "$GW/auth/login.py"
BR_OUT="$( (cd "$GW" && python3 "$SRC/skills/task-to-runtime-contract/scripts/check-path-policy.py" \
  --profile cvg/execution/T-20260602-golden/execution-profile.yaml --repo "$GW" 2>&1) || true )"
if grep -q 'exceeds max_changed_files' <<<"$BR_OUT"; then
  ok "blast radius is capped even when every path is in scope"
else
  bad "max_changed_files did not fire"
fi

# A gate that cannot be parsed must FAIL, never be skipped.
printf 'version: 1\nnonsense_key: yes\n' > "$GW/.cvg/gate.yaml"
git -C "$GW" add .cvg/gate.yaml
git -C "$GW" commit --quiet -m "malformed gate fixture"
BAD_OUT="$( (cd "$GW" && python3 "$SRC/skills/task-to-runtime-contract/scripts/check-path-policy.py" \
  --profile cvg/execution/T-20260602-golden/execution-profile.yaml --repo "$GW" 2>&1) || true )"
if grep -q '^Path policy error:' <<<"$BAD_OUT" \
  && grep -q "unknown gate key 'nonsense_key'" <<<"$BAD_OUT" \
  && grep -q '^CHECK_PATH_POLICY=FAIL$' <<<"$BAD_OUT"; then
  ok "an unparseable gate FAILS closed — not silently skipped"
else
  bad "a broken gate was treated as no gate: $(tail -2 <<<"$BAD_OUT" | head -1)"
fi

# Dotfiles must not be mangled. lstrip("./") turned ".env" into "env" and
# quietly exempted exactly the files most worth guarding.
if python3 -c "
import sys; sys.path.insert(0, '$SRC/skills/task-to-runtime-contract/scripts')
from _gate_policy import parse_gate
g = parse_gate('version: 1\ndenylist:\n  - \".env\"\n  - \".github/workflows/**\"\n')
assert g.forbids('.env'), '.env not matched'
assert g.forbids('.github/workflows/ci.yml'), 'workflow not matched'
" 2>/dev/null; then
  ok "dotfile paths are matched, not silently renamed"
else
  bad "dotfile paths are still being mangled"
fi
rm -rf "$GW"

# The supervised legacy escape hatch may skip the per-task contract, but it may
# never skip standing repository policy.
LW="$(new_ws)"
sed -i.bak '/NEVERMATCH/d' "$LW/README.md" 2>/dev/null || true
rm -f "$LW/README.md.bak"
mkdir -p "$LW/.cvg" "$LW/auth"
printf 'version: 2\nprotected_paths:\n  - "**/auth/**"\nmax_changed_files: 12\n' > "$LW/.cvg/gate.yaml"
git -C "$LW" add .cvg/gate.yaml README.md
git -C "$LW" commit --quiet -m "legacy gate baseline"
LW_BASE="$(git -C "$LW" rev-parse HEAD)"
printf 'forbidden\n' > "$LW/auth/legacy.txt"
LW_OUT="$( (cd "$LW" && TASKSPEC_SIGNING_KEY="$KEY" \
  bash "$SRC/skills/task-loop/scripts/open-issue-pr.sh" \
    --issue T-20260602-golden --tasks-dir cvg/tasks \
    --legacy-no-contract --base "$LW_BASE" --dry-run 2>&1) || true )"
if grep -q 'CHECK_PATH_POLICY=FAIL' <<<"$LW_OUT" \
  && grep -q 'green eval rejected by the settlement path policy' <<<"$LW_OUT"; then
  ok "legacy-no-contract still enforces the repository gate"
else
  bad "legacy mode bypassed standing repository policy"
fi
drop_ws "$LW"

# ------------------------------------------------ engines must not inherit stdin
# An engine handed an open-but-never-closing stdin can finish its work and then
# BLOCK waiting for an EOF that never arrives. The watchdog eventually kills it,
# the attempt is recorded as a timeout, and the transcript hides the fact that
# the model was done minutes earlier. This cost a 25-minute run to learn once.
# Each adapter honours CVG_<ENGINE>_CMD, so point it at a stub that READS stdin:
# with a closed stdin the stub returns at once, with an inherited one it hangs.
STDIN_PROBE="$STUBS/stdin-probe.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho probe-returned\n' > "$STDIN_PROBE"
chmod +x "$STDIN_PROBE"
printf 'prompt\n' > "$STUBS/probe-prompt.md"
for _eng in claude codex kimi; do
  _var="CVG_$(echo "$_eng" | tr '[:lower:]' '[:upper:]')_CMD"
  _out="$( ( echo "an open pipe that never closes" | \
      env "$_var=$STDIN_PROBE" ENGINE_TIMEOUT=10 \
      bash "$SRC/skills/task-loop/scripts/engines/$_eng.sh" \
        --prompt-file "$STUBS/probe-prompt.md" --workdir "$STUBS" 2>&1 ) )"
  if printf '%s' "$_out" | grep -q 'probe-returned' \
     && ! printf '%s' "$_out" | grep -q 'engine timed out'; then
    ok "$_eng passes the engine a CLOSED stdin (returns, does not hang)"
  else
    bad "$_eng leaves stdin open — the engine can block after finishing"
  fi
done

# ------------------------------------------------- checkpoint before the pause
# An engine call can run for many minutes. If the checkpoint is written only on
# the way OUT, a process killed mid-attempt leaves --resume nothing to resume
# from and the attempt is silently redone. The checkpoint must already exist
# while the loop is paused inside the engine.
W="$(new_ws)"
stub_engine "" tstslow 'sleep 30; echo "slow"; exit 0'
# in-place: this row is about the CHECKPOINT, not about isolation, and a
# worktree would put state.env somewhere this assertion is not looking.
( cd "$W" && TASKSPEC_SIGNING_KEY="$KEY" CVG_HOME="$SRC" CVG_ENGINES_DIR="$STUBS" \
  bash "$KERNEL" --issue T-20260602-golden --agent tstslow --isolation inplace >/dev/null 2>&1 ) &
_kpid=$!
sleep 8   # long enough to be inside the engine call, nowhere near its return
if grep -q '^ITER=1$' "$W/cvg/loop/T-20260602-golden/state.env" 2>/dev/null; then
  ok "the checkpoint exists WHILE the loop is paused inside an attempt"
else
  bad "no checkpoint mid-attempt — a kill here would silently redo the work"
fi
kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null
pkill -f 'sleep 30' 2>/dev/null || true
drop_ws "$W"

# ---------------------------------------------------------- tracker authority
# Posting to a board is an external write. The envelope grants tracker.write its
# own scope and policy.external_writes defaults to deny, so a loop that narrated
# anyway would be quietly exceeding its contract — the exact defect class the
# envelope exists to prevent.
W="$(new_ws)"
run_kernel "$W" --agent tstnoop
if grep -q 'tracker: not authorized' <<<"$RK_OUT"; then
  ok "a deny-by-default contract suppresses tracker writes, and says so"
else
  bad "the loop did not report its tracker authority"
fi
if ! grep -qE 'tracker: .* → (in progress|done)' <<<"$RK_OUT"; then
  ok "no board mutation happens without tracker.write authority"
else
  bad "the loop wrote to the board it was not authorized to touch"
fi
# This row must run against a REAL stalled loop, so prove the run it inspects
# actually happened. Both assertions above are satisfiable by a loop that never
# attempted anything — one greps for a suppression notice the ERROR landing also
# prints, the other is a negative. When the stub cleanup sat above this block,
# the engine adapter was already deleted: the loop landed ERROR with zero
# attempts and both rows passed for the wrong reason.
if grep -q '^TASK_LOOP=STALLED$' <<<"$RK_OUT" && [ "$(grep -c '── attempt ' <<<"$RK_OUT")" -gt 0 ]; then
  ok "…and it proved that on a loop that really ran (STALLED, attempts > 0)"
else
  ok_state="$(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
  bad "the tracker rows inspected a loop that never ran (${ok_state:-no terminal state})"
fi
# An unauthorized run must SAY it skipped, not stay silent about it.
if grep -q '^TRACKER=SKIPPED' <<<"$RK_OUT"; then
  ok "an unauthorized run reports TRACKER=SKIPPED rather than nothing"
else
  bad "no TRACKER= token on an unauthorized run: 'the board will follow' stays unfalsifiable"
fi
drop_ws "$W"

# ------------------------------------------------- tracker accounting (L5)
# Fail-soft is not the same as silent. The board write was broken for weeks and
# every run's log looked identical to a working one, because the bridge's output
# AND status were both discarded. These rows pin the accounting: the token must
# distinguish success from failure, and a FAILED board must still not change the
# verdict the evals produced.
TBRIDGE_OK="$STUBS/tracker-ok.sh"
TBRIDGE_BAD="$STUBS/tracker-bad.sh"
printf '#!/usr/bin/env bash\necho "stub tracker: called with $*"\nexit 0\n' > "$TBRIDGE_OK"
printf '#!/usr/bin/env bash\necho "stub tracker: simulated board outage" >&2\nexit 1\n' > "$TBRIDGE_BAD"
chmod +x "$TBRIDGE_OK" "$TBRIDGE_BAD"

W="$(new_ws)"
CVG_TRACKER_BRIDGE="$TBRIDGE_OK" run_kernel "$W" --agent tstnoop --allow-external-writes
RK_OK_RC="$RK_RC"
RK_OK_STATE="$(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
RK_OK_TRIES="$(grep -c '── attempt ' <<<"$RK_OUT")"
if grep -qE '^TRACKER=OK' <<<"$RK_OUT"; then
  ok "an authorized run whose bridge succeeds reports TRACKER=OK"
else
  bad "TRACKER=OK missing on a healthy authorized run: $(grep -E '^TRACKER=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

W="$(new_ws)"
CVG_TRACKER_BRIDGE="$TBRIDGE_BAD" run_kernel "$W" --agent tstnoop --allow-external-writes
RK_BAD_RC="$RK_RC"
RK_BAD_STATE="$(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
if grep -qE '^TRACKER=FAILED' <<<"$RK_OUT"; then
  ok "a bridge that fails is reported as TRACKER=FAILED, not swallowed"
else
  bad "a failing tracker bridge went unreported: $(grep -E '^TRACKER=' <<<"$RK_OUT" | tail -1)"
fi
# THE LOAD-BEARING ROW. The whole point of fail-soft is that the evals decide the
# verdict. If reporting the failure ever started influencing the exit code, the
# board would have gained a veto over the work — the defect this design forbids.
#
# Stated as a DIFFERENTIAL, not as a constant. Asserting one hardcoded state
# would pass just as happily if the tracker were dictating it; comparing the
# healthy-bridge run against the failing-bridge run is what actually pins "the
# board changed nothing". The baseline is checked too, for the reason the row
# above this block records: a loop that never ran lands identically either way,
# so the comparison alone is satisfiable by two equally broken runs.
if [ "$RK_OK_STATE" = "TASK_LOOP=STALLED" ] && [ "$RK_OK_RC" -eq 1 ] && [ "$RK_OK_TRIES" -gt 0 ]; then
  if [ "$RK_BAD_STATE" = "$RK_OK_STATE" ] && [ "$RK_BAD_RC" -eq "$RK_OK_RC" ]; then
    ok "…and the failing board landed EXACTLY where the healthy one did ($RK_OK_STATE, rc=$RK_OK_RC)"
  else
    bad "a tracker failure leaked into the verdict (healthy: $RK_OK_STATE/$RK_OK_RC, failing: $RK_BAD_STATE/$RK_BAD_RC)"
  fi
else
  bad "the baseline run never really looped (${RK_OK_STATE:-no terminal state}, rc=$RK_OK_RC, attempts=$RK_OK_TRIES)"
fi
drop_ws "$W"

# ------------------------------------------------- durable resume
# --resume used to cut a fresh worktree before reading the checkpoint, mint a
# new handoff --force, and restart ITER/elapsed/tokens. These rows pin the
# bridge: same worktree, same attempt handoff, monotonic spend, no concurrent
# dispatch, refuse an altered spec revision, and dry-run/estimate stay inert.

# Dry-run / estimate must not create a worktree, handoff, or attempt dir.
W="$(new_ws)"
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
_wt_before="$(git -C "$W" worktree list | wc -l | tr -d ' ')"
run_kernel "$W" --dry-run --isolation worktree
_wt_after="$(git -C "$W" worktree list | wc -l | tr -d ' ')"
if [ "$_wt_before" = "$_wt_after" ] \
   && [ ! -e "$W/cvg/loop/T-20260602-golden/state.env" ] \
   && [ ! -e "$W/cvg/execution/T-20260602-golden/task-handoff.json" ] \
   && [ ! -d "$W/cvg/loop/T-20260602-golden/attempts" ]; then
  ok "dry-run creates neither worktree nor handoff nor checkpoint"
else
  bad "dry-run left dispatch side-effects"
fi
run_kernel "$W" --estimate --isolation worktree
_wt_est="$(git -C "$W" worktree list | wc -l | tr -d ' ')"
if [ "$_wt_before" = "$_wt_est" ] \
   && [ ! -e "$W/cvg/loop/T-20260602-golden/state.env" ] \
   && [ ! -e "$W/cvg/execution/T-20260602-golden/task-handoff.json" ]; then
  ok "estimate creates neither worktree nor handoff nor checkpoint"
else
  bad "estimate left dispatch side-effects"
fi
drop_ws "$W"

# Resume reuses the worktree and continues ITER instead of restarting at 1.
W="$(new_ws)"
git -C "$W" add -A >/dev/null 2>&1; git -C "$W" commit --quiet -m red >/dev/null 2>&1
run_kernel "$W" --agent tstnoop --isolation worktree --max-iterations 1
_wt1="$(grep -E '^isolation: worktree ' <<<"$RK_OUT" | awk '{print $3}')"
_hid1=""
if [ -n "$_wt1" ] && [ -f "$_wt1/cvg/execution/T-20260602-golden/task-handoff.json" ]; then
  _hid1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt",{}).get("id",""))' "$_wt1/cvg/execution/T-20260602-golden/task-handoff.json")"
fi
_iter1="$(grep -E '^ITER=' "$W/cvg/loop/T-20260602-golden/state.env" 2>/dev/null | head -1)"
run_kernel "$W" --agent tstnoop --isolation worktree --resume --max-iterations 2
_wt2="$(grep -E '^isolation: worktree ' <<<"$RK_OUT" | awk '{print $3}')"
_hid2=""
if [ -n "$_wt2" ] && [ -f "$_wt2/cvg/execution/T-20260602-golden/task-handoff.json" ]; then
  _hid2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt",{}).get("id",""))' "$_wt2/cvg/execution/T-20260602-golden/task-handoff.json")"
fi
if [ -n "$_wt1" ] && [ "$_wt1" = "$_wt2" ] && grep -q '(resumed)' <<<"$RK_OUT"; then
  ok "resume reattaches the existing worktree"
else
  bad "resume cut a new worktree (first=$_wt1 second=$_wt2)"
fi
if grep -q '── attempt 2/' <<<"$RK_OUT" && ! grep -q '── attempt 1/' <<<"$RK_OUT"; then
  ok "resume continues ITER instead of restarting at attempt 1"
else
  bad "resume redispatched from attempt 1: $(grep -E '── attempt |^TASK_LOOP=' <<<"$RK_OUT" | tr '\n' ' ')"
fi
if [ -n "$_hid1" ] && [ "$_hid1" = "$_hid2" ]; then
  ok "resume reuses the attempt handoff without --force"
else
  bad "resume minted a new handoff attempt id ($_hid1 -> $_hid2)"
fi
if [ "$_iter1" = "ITER=1" ]; then
  ok "checkpoint after first run is in the original workspace"
else
  bad "durable checkpoint missing from original workspace ($_iter1)"
fi
drop_ws "$W"

# Green eval on --resume is pending settlement, never a fresh NO_OP.
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 1
sed -i.bak '/NEVERMATCH/d' "$W/README.md" 2>/dev/null || true
rm -f "$W/README.md.bak"
run_kernel "$W" --agent tstnoop --resume --max-iterations 5
if grep -qE '^TASK_LOOP=(SETTLED|LOCAL_SETTLED)$' <<<"$RK_OUT" \
   && ! grep -q '^TASK_LOOP=NO_OP$' <<<"$RK_OUT" \
   && grep -q 'not NO_OP' <<<"$RK_OUT"; then
  ok "resume of a now-green checkpoint settles instead of NO_OP"
else
  bad "resume took the fresh NO_OP shortcut: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

# Prior tier-2 REFUTED must repair, not no-op on the still-green eval.
W="$(new_ws)"
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstfix --verify
if grep -q '^TASK_LOOP=BLOCKED$' <<<"$RK_OUT"; then
  ok "refute fixture blocked settlement (setup for resume repair)"
else
  bad "refute fixture did not block: $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
RK_VERIFIER="$STUBS/verify-refute.sh" run_kernel "$W" --agent tstnoop --resume --verify --max-iterations 5
if grep -q 'tier-2 REFUTED' <<<"$RK_OUT" \
   && grep -q '── attempt ' <<<"$RK_OUT" \
   && ! grep -q '^TASK_LOOP=NO_OP$' <<<"$RK_OUT"; then
  ok "resume after REFUTED dispatches a repair attempt instead of NO_OP"
else
  bad "resume after REFUTED did not repair: $(grep -E '── attempt |^TASK_LOOP=' <<<"$RK_OUT" | tr '\n' ' ')"
fi
drop_ws "$W"

# Attempt identity is immutable even when task, spec, and base still match.
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 1
python3 - "$W/cvg/execution/T-20260602-golden/task-handoff.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["attempt"]["id"] = "replacement-attempt"
path.write_text(json.dumps(data))
PY
run_kernel "$W" --agent tstnoop --resume --max-iterations 5
if [ "$RK_RC" -eq 4 ] && grep -q 'handoff changed' <<<"$RK_OUT"; then
  ok "resume refuses a substituted attempt with the same task and spec"
else
  bad "resume accepted a substituted handoff"
fi
run_kernel "$W" --agent tstnoop --max-iterations 5
if [ "$RK_RC" -eq 4 ] && grep -q 'use --resume' <<<"$RK_OUT"; then
  ok "a fresh invocation cannot reset an existing checkpoint"
else
  bad "a fresh invocation restarted an existing attempt"
fi
drop_ws "$W"

W="$(new_ws)"
run_kernel "$W" --require-independent --no-verify
if [ "$RK_RC" -eq 2 ] && grep -q '^TASK_LOOP=USAGE_ERROR$' <<<"$RK_OUT"; then
  ok "required independent verification cannot be disabled by a later flag"
else
  bad "a later flag bypassed required independent verification"
fi
drop_ws "$W"

# Altered spec revision refuses resume (no silent re-bind).
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 1
printf '\n# revision bump\n' >> "$W/cvg/tasks/T-20260602-golden.md"
run_kernel "$W" --agent tstnoop --resume --max-iterations 5
if [ "$RK_RC" -eq 4 ] && grep -q 'spec revision changed' <<<"$RK_OUT"; then
  ok "resume refuses an altered spec revision"
else
  bad "resume accepted a changed revision: rc=$RK_RC $(grep -E '^TASK_LOOP=' <<<"$RK_OUT" | tail -1)"
fi
drop_ws "$W"

# Concurrent dispatch: a live loop holds the lock.
W="$(new_ws)"
stub_engine "" tsthold 'sleep 12; echo "held"; exit 0'
_hold_pid="$(python3 - "$W" "$KEY" "$SRC" "$STUBS" "$KERNEL" <<'PY'
import os, subprocess, sys
workspace, key, source, stubs, kernel = sys.argv[1:]
env = dict(os.environ, TASKSPEC_SIGNING_KEY=key, CVG_HOME=source,
           CVG_ENGINES_DIR=stubs, CVG_VERIFIER=stubs + "/verify-uphold.sh")
process = subprocess.Popen(
    ["bash", kernel, "--issue", "T-20260602-golden", "--agent", "tsthold",
     "--isolation", "inplace", "--max-iterations", "1"],
    cwd=workspace, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    start_new_session=True,
)
print(process.pid)
PY
)"
_lock_wait=0
while [ "$_lock_wait" -lt 40 ]; do
  [ -f "$W/cvg/loop/T-20260602-golden/lock" ] && break
  sleep 0.2
  _lock_wait=$((_lock_wait + 1))
done
run_kernel "$W" --agent tstnoop --resume --isolation inplace
_conc_rc="$RK_RC"
_conc_out="$RK_OUT"
python3 - "$_hold_pid" <<'PY'
import os, signal, sys
pid = int(sys.argv[1])
try:
    assert os.getpgid(pid) == pid
    os.killpg(pid, signal.SIGTERM)
except ProcessLookupError:
    pass
PY
if [ "$_conc_rc" -eq 4 ] && grep -q 'already running' <<<"$_conc_out"; then
  ok "lock refuses concurrent dispatch of the same task"
else
  bad "concurrent resume was allowed: rc=$_conc_rc $(grep -E '^TASK_LOOP=' <<<"$_conc_out" | tail -1)"
fi
drop_ws "$W"

# Elapsed time on resume is never smaller than the checkpointed spend.
W="$(new_ws)"
run_kernel "$W" --agent tstnoop --max-iterations 1
_st="$W/cvg/loop/T-20260602-golden/state.env"
python3 - "$_st" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = []
for line in p.read_text().splitlines():
    if line.startswith("ELAPSED_PRIOR="):
        lines.append("ELAPSED_PRIOR=40")
    else:
        lines.append(line)
p.write_text("\n".join(lines) + "\n")
PY
run_kernel "$W" --agent tstfix --resume --max-iterations 5
_el="$(grep -oE 'elapsed [0-9]+s' <<<"$RK_OUT" | tail -1 | awk '{print $2}' | tr -d 's')"
if [ "${_el:-0}" -ge 40 ] 2>/dev/null; then
  ok "resume elapsed is not smaller than the checkpointed spend"
else
  bad "resume shrank elapsed to ${_el:-missing}"
fi
drop_ws "$W"

# Cleanup belongs AFTER the last row that needs the stubs and the signing key.
# (Still no `trap ... EXIT`: bash fires an inherited EXIT trap when a `( )`
# subshell exits, and run_kernel uses one.)
rm -rf "$STUBS"; rm -f "$KEY"

echo "------------------------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS — %d loop-kernel checks green.\n' "$PASS"; exit 0
fi
printf 'FAIL — %d of %d loop-kernel checks red.\n' "$FAIL" "$((PASS + FAIL))"; exit 1
