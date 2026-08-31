#!/usr/bin/env bash
# check-tech-spec.sh — Converge Pass 1 gate verifier.
#
# The bundled checklist verifier that SKILL.md Step 4 invokes. Given a
# tech-spec path it asserts the six required sections are present, that the
# spec restates the problem, that requirements read as falsifiable, that
# success metrics are expressed current -> target, that the source data is
# named, and that open assumptions carry owners. It also WARNS on any
# technology/stack leak — terms loaded from references/leak-terms.txt in
# per-domain buckets (data, web/frontend, infra/devops, ml/agents), matched
# word-boundaried so 'spark' does not fire on 'sparkline' — because Pass 1
# must stay above the stack: the engine is decided in Pass 3.
#
# Usage:
#   bash check-tech-spec.sh cvg/docs/tech-spec/analytical-engine.md # canonical
#   bash check-tech-spec.sh --draft cvg/docs/tech-spec/<slug>.md  # validation only
#   bash check-tech-spec.sh --version
#
# Exit contract (v0.5.0): draft validation and Pass 2 handoff authorization
# are DIFFERENT verdicts. Canonical (default) adds the sign-off check —
# fence-stripped Sign-off section, 'canonical' on the verdict line itself
# (pending/draft there never authorizes), and a calendar-valid ISO date ON
# the verdict line or the line immediately following it (python3 datetime
# when available; regex-only + warning otherwise) — and is the ONLY mode
# whose verdict hands to Pass 2. --draft runs the structural checks and
# NEVER authorizes.
#
# Blocker-gap hardening:
#   * Check 7 fails CLOSED on blocker gaps: a blocker whose resolution is
#     missing, blank, or any open/none/null/tbd/pending/awaiting sentinel
#     (quoted or not) is unresolved. Only an affirmatively substantive
#     resolution lets a blocker through.
#   * Leak terms live in references/leak-terms.txt (fail-soft if missing),
#     matched with word boundaries; warnings name the domain bucket.
#   * Warn-only: requirement bullets without a stable R-n/W-n id, and any
#     R-n/W-n whose own line(s) carry no number, unit, or comparator.
#
# Agent contract: the LAST line is always a stable machine token —
#   CHECK_TECH_SPEC=PASS | FAIL | DRAFT_OK | DRAFT_INCOMPLETE | USAGE_ERROR
# including every exit-2 usage path.
#
# Exit codes:
#   0   PASS / DRAFT_OK (warnings do not fail the gate)
#   1   FAIL / DRAFT_INCOMPLETE
#   2   usage error (still ends in CHECK_TECH_SPEC=USAGE_ERROR)
#
# Portability: macOS system bash 3.2 safe. No mapfile, no `declare -A`, no
# process substitution into arrays. grep/sed/awk only, like the task-spec
# skill scripts.

set -euo pipefail

# The PACKAGE version, not this script's own. Converge ships as ONE unit:
# the root VERSION file is the source of truth and tests/test-version-unity.sh
# fails the build if any declaration here drifts from it. Bump VERSION, then
# run that gate with --sync.
CHECK_TECH_SPEC_VERSION="0.2.1"

# A valid ISO date: month 01-12, day 01-31 (2026-13-45 is not a date).
ISO_RE='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'

# ---------------------------------------------------------------------------
# Error / warning helpers (arrays + explicit counters so `set -u` stays happy
# on bash 3.2, where ${#arr[@]} on a never-assigned array can trip up).
# ---------------------------------------------------------------------------
ERRORS=()
WARNINGS=()
PASSES=()
NERR=0
NWARN=0
NPASS=0

err()  { ERRORS+=("$1");   NERR=$((NERR + 1)); }
warn() { WARNINGS+=("$1"); NWARN=$((NWARN + 1)); }
ok()   { PASSES+=("$1");   NPASS=$((NPASS + 1)); }

die() {
  echo "ERROR: $*" >&2
  echo "CHECK_TECH_SPEC=USAGE_ERROR"
  exit 2
}

usage_error() {
  echo "ERROR: $*" >&2
  echo "usage: bash check-tech-spec.sh [--draft] <tech-spec.md>" >&2
  echo "       bash check-tech-spec.sh --version" >&2
  echo "CHECK_TECH_SPEC=USAGE_ERROR"
  exit 2
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
MODE="canonical"
SPEC=""

for ARG in "$@"; do
  case "$ARG" in
    --version)
      echo "check-tech-spec v$CHECK_TECH_SPEC_VERSION"
      exit 0
      ;;
    --draft) MODE="draft" ;;
    -h|--help)
      echo "usage: bash check-tech-spec.sh [--draft] <tech-spec.md>" >&2
      echo "       bash check-tech-spec.sh --version" >&2
      echo "CHECK_TECH_SPEC=USAGE_ERROR"
      exit 2
      ;;
    -*)
      usage_error "unknown flag '$ARG' — expected --draft, --version, or a file path"
      ;;
    *)
      if [[ -n "$SPEC" ]]; then
        usage_error "more than one file argument ('$SPEC', '$ARG') — gate one spec per run"
      fi
      SPEC="$ARG"
      ;;
  esac
done

[[ -n "$SPEC" ]] || usage_error "no tech-spec path given"
[[ -f "$SPEC" ]] || die "tech-spec not found: $SPEC"

case "$SPEC" in
  *.md) : ;;
  *.pdf)
    die "this verifier reads text (.md); a .pdf is a consensus object — emit --out-format md once the spec is locked, then re-run the gate on it"
    ;;
  *)
    warn "unexpected extension on '$SPEC' — expected a .md tech-spec"
    ;;
esac

# Lower-cased copy of the body for case-insensitive presence checks. Keep the
# original around for line-accurate leak reporting.
BODY_LC="$(tr '[:upper:]' '[:lower:]' < "$SPEC")"

# Fence-stripped copy of the spec: an example inside ``` proves nothing, so
# structural extraction (requirement bullets, the Sign-off block) runs on this.
SO_STRIPPED="$(awk '/^[[:space:]]*```/ { fence = !fence; next } !fence { print }' "$SPEC")"

# has_any <pattern...> — return 0 if ANY extended-regex matches the body.
# Runs case-insensitively against the lower-cased body. Patterns are passed
# with `-e` so a pattern that starts with '<' or '>' (a comparator) is never
# mistaken for a grep option by BSD/macOS grep.
has_any() {
  local pat
  for pat in "$@"; do
    if printf '%s\n' "$BODY_LC" | grep -Eq -e "$pat"; then
      return 0
    fi
  done
  return 1
}

# count_matches <pattern> — count body lines matching an extended regex.
# Prints an integer. `-e` guards comparator patterns as above.
count_matches() {
  printf '%s\n' "$BODY_LC" | grep -Ec -e "$1" || true
}

# ---------------------------------------------------------------------------
# Check 1 — Problem restated (one paragraph, from the client's seat)
# ---------------------------------------------------------------------------
if has_any '^#+.*problem[[:space:]-]*(restat|statement)' 'problem restated' 'problem statement'; then
  ok "Problem restated section present"
else
  err "Missing a 'Problem restated' (or 'Problem statement') section — the one-paragraph restatement is half the gate"
fi

# ---------------------------------------------------------------------------
# Check 2 — Scope: in AND out, explicit
# ---------------------------------------------------------------------------
HAS_SCOPE=0
has_any '^#+.*scope' '\bscope\b' && HAS_SCOPE=1
# (v0.4.0: dead HAS_IN assignment removed — it was never consulted by the
# verdict below; the in-side judgment is the human gate's job.)
HAS_OUT=0
has_any 'out[[:space:]-]*of[[:space:]-]*scope' 'out[[:space:]-]*scope' 'explicitly out' 'not[[:space:]]+in[[:space:]]+scope' && HAS_OUT=1

if [[ $HAS_SCOPE -eq 1 && $HAS_OUT -eq 1 ]]; then
  ok "Scope section present with an explicit out-of-scope boundary"
elif [[ $HAS_SCOPE -eq 1 && $HAS_OUT -eq 0 ]]; then
  err "Scope section present but no explicit OUT-of-scope boundary — say what the engine does NOT do"
else
  err "Missing a Scope section (in / out) at the problem level"
fi

# ---------------------------------------------------------------------------
# Check 3 — Requirements, and whether they read as verifiable/falsifiable
# ---------------------------------------------------------------------------
if has_any '^#+.*requirement' '\brequirements\b'; then
  ok "Requirements section present"
else
  err "Missing a Requirements section"
fi

# Falsifiability heuristic: a spec whose requirements can be eval'd carries
# measurable language — numbers, thresholds, comparators, time/percent units.
# Vague-only specs carry wish words with no numbers to pin them.
NNUM=$(count_matches '[0-9]+([.][0-9]+)?[[:space:]]*(%|percent|s\b|sec|second|minute|min\b|hour|hr\b|ms\b|day|row|record|byte|kb|mb|gb)')
NCOMPARE=$(count_matches '(<=|>=|<|>|within|at least|at most|no more than|no less than|fewer than|greater than|less than|up to)')
NWISH=$(count_matches '\b(fast|quick|reliable|robust|accurate|scalable|performant|user[- ]?friendly|seamless|efficient|snappy|responsive)\b')

if [[ "$NNUM" -eq 0 && "$NCOMPARE" -eq 0 ]]; then
  err "Requirements are not falsifiable — no measurable thresholds found (no numbers with units, no comparators). Rewrite each as current -> target; see references/falsifiable-requirements.md"
else
  ok "Requirements carry measurable thresholds ($NNUM quantified line(s), $NCOMPARE comparator(s))"
fi

if [[ "$NWISH" -gt 0 && "$NNUM" -eq 0 ]]; then
  warn "Wish words present with no numbers to anchor them (e.g. fast/reliable/accurate) — make each measurable or move it to open assumptions"
fi

# ---------------------------------------------------------------------------
# Check 3b — Stable requirement ids (warn-only, P-9 item 5)
# Every requirement bullet carries R-n (requirement) or W-n (wish/wont) so
# evals, ADRs, and gap records can cite it. Fenced examples don't count —
# extraction runs on the fence-stripped body.
# Check 3c — Per-requirement falsifiability (warn-only, audit finding)
# The global heuristic above passes on ONE measurable line anywhere; here
# each R-n/W-n must carry a number, unit, or comparator on its own line(s)
# (bullet + its continuation lines). Both checks are advisory: the human
# gate owns the verdict, the script owns the reminder.
# ---------------------------------------------------------------------------
REQ_SCAN="$(printf '%s\n' "$SO_STRIPPED" | awk '
  /^##[^#]/ { inside = (tolower($0) ~ /requirement/) ? 1 : 0; next }
  inside { print }
' | awk '
  function flush() {
    if (!open) return
    open = 0
    id = ""
    if (match(buf, /[RrWw]-[0-9]+/)) id = toupper(substr(buf, RSTART, RLENGTH))
    # Strip id tokens (incl. cross-references) before the measurability
    # test — the digits inside an id are not a threshold.
    tl = tolower(buf)
    gsub(/[rw]-[0-9]+/, "", tl)
    has_meas = (tl ~ /[0-9]/ || tl ~ /(<=|>=|within|at least|at most|no more than|no less than|fewer than|greater than|less than|up to)/)
    if (id == "") noid++
    else if (!has_meas) print "UNMEAS " id
  }
  /^[[:space:]]*[-*][[:space:]]/ { flush(); open = 1; buf = $0; next }
  /^[[:space:]]*$/              { flush(); next }
  { if (open) buf = buf " " $0 }
  END { flush(); print "NOID " noid + 0 }
')"

NREQ_NOID=0
UNMEAS_IDS=""
while IFS=' ' read -r tag rest; do
  case "$tag" in
    NOID)   NREQ_NOID="${rest:-0}" ;;
    UNMEAS) UNMEAS_IDS="$UNMEAS_IDS ${rest:-}" ;;
  esac
done <<EOF
$REQ_SCAN
EOF

if [[ "$NREQ_NOID" -gt 0 ]]; then
  warn "$NREQ_NOID requirement bullet(s) lack a stable R-n/W-n id — give every requirement an R-n and every wish/wont a W-n so evals, ADRs, and gap records can cite them"
fi
for rid in $UNMEAS_IDS; do
  warn "requirement $rid has no number, unit, or comparator on its own line(s) — make it measurable or move it to open assumptions (see references/falsifiable-requirements.md)"
done

# ---------------------------------------------------------------------------
# Check 4 — Success metrics expressed as current -> target
# ---------------------------------------------------------------------------
HAS_METRICS=0
has_any '^#+.*success[[:space:]]*metric' 'success metrics' '\bkpi' '\bmetric' && HAS_METRICS=1
HAS_C2T=0
# Accept ASCII '->' and the unicode arrow '→'; also accept a 'current ... target'
# pairing on the same line.
has_any '->' '→' 'current[[:space:]].*target' 'baseline[[:space:]].*target' 'from[[:space:]].*to[[:space:]]' && HAS_C2T=1

if [[ $HAS_METRICS -eq 1 && $HAS_C2T -eq 1 ]]; then
  ok "Success metrics present and expressed current -> target"
elif [[ $HAS_METRICS -eq 1 && $HAS_C2T -eq 0 ]]; then
  err "Success metrics present but not expressed as current -> target — every metric needs a baseline and a target traced to a BRD KPI"
else
  err "Missing a Success metrics section (each metric current -> target, traced to a BRD KPI)"
fi

# ---------------------------------------------------------------------------
# Check 5 — Data named (the source records the engine consumes)
# Domain-neutral by design: any discipline's spec passes with a Data section
# naming ITS entities (orders, tickets, configs, components, prompts, ...).
# Judging whether the right entities are named is the human gate's job.
# ---------------------------------------------------------------------------
if has_any '^#+.*data' '\bdata named\b' '\bsource\b.*\b(record|entit|event|system)' 'inputs? the (engine|system) (consumes|acts on|reads)'; then
  ok "Source data named (a Data section / source entities at the problem level)"
else
  err "The data the engine acts on is not named — add a Data section naming the source records/entities at the problem level (whatever this domain's inputs are)"
fi

# ---------------------------------------------------------------------------
# Check 6 — Open assumptions, each with a named owner
# ---------------------------------------------------------------------------
HAS_ASSUMP=0
has_any '^#+.*assumption' 'open assumptions' '\bassumption' && HAS_ASSUMP=1
HAS_OWNER=0
has_any '\bowner\b' 'owned by' 'owner:' '@[a-z]' && HAS_OWNER=1

if [[ $HAS_ASSUMP -eq 1 && $HAS_OWNER -eq 1 ]]; then
  ok "Open assumptions recorded, each with a named owner"
elif [[ $HAS_ASSUMP -eq 1 && $HAS_OWNER -eq 0 ]]; then
  err "Open assumptions listed but no owner named — every assumption needs a named owner (a client stakeholder)"
else
  err "Missing an Open assumptions section (each with a named owner)"
fi

# ---------------------------------------------------------------------------
# Check 7 — No unresolved BLOCKER gaps (the gap register has teeth)
# Convention (SKILL.md Step 2): a gap record carries `severity:` and
# `resolution:`. v0.5.0 FAILS CLOSED (P-9 item 2): within a record whose
# severity is blocker (quoted or not), a resolution that is missing, blank,
# or any open/none/null/tbd/pending/awaiting sentinel — quoted or not — is
# UNRESOLVED and fails the gate. Only an affirmatively substantive
# resolution lets a blocker through: what the script cannot read as
# resolved, it treats as open. awk keeps severity/resolution paired per
# record (records start at "- id:").
# ---------------------------------------------------------------------------
NBLOCKER_OPEN=$(awk '
  function flush() {
    if (inblk && (!hasres || bad)) n++
    inblk = 0; hasres = 0; bad = 0
  }
  { line = tolower($0) }
  line ~ /-[[:space:]]*id:/ { flush() }
  line ~ /severity:[[:space:]]*["'"'"']?blocker/ { inblk = 1 }
  inblk && line ~ /resolution:/ {
    hasres = 1
    val = line
    sub(/^[^:]*resolution:[[:space:]]*/, "", val)
    sub(/[[:space:]]+#.*$/, "", val)
    gsub(/["'"'"'()]/, "", val)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    if (val == "" || val ~ /^(open|none|null|n\/a|tbd|tba|pending|awaiting.*|to be (decided|determined|confirmed)|\.\.\.)$/) bad = 1
  }
  END { flush(); print n + 0 }
' "$SPEC")

if [[ "$NBLOCKER_OPEN" -gt 0 ]]; then
  err "$NBLOCKER_OPEN unresolved BLOCKER gap(s) — resolve each (chase the named owner, fill 'resolution:') before the spec can descend to Pass 2"
else
  ok "No unresolved blocker gaps (register clean or all blockers resolved)"
fi

# ---------------------------------------------------------------------------
# Check 8 — Priorities differentiated (warn-only)
# A spec where everything is 'must' has not made a scoping decision yet.
# ---------------------------------------------------------------------------
NMUST=$(count_matches '\bmust\b')
NTIER=$(count_matches '\b(should|could|wont)\b')
if [[ "$NMUST" -gt 0 && "$NTIER" -eq 0 ]]; then
  warn "every requirement reads as 'must' with no should/could/wont — differentiate priorities (must = the outcome fails without it)"
else
  ok "Requirement priorities differentiated ($NMUST must / $NTIER should-could-wont line(s))"
fi

# ---------------------------------------------------------------------------
# Check 9 — Sign-off: the authorization boundary (Gate H1 made mechanical).
# Extraction is fence-stripped (an example inside ``` proves nothing) and
# anchored to the VERDICT LINE itself — 'canonical' in guidance prose never
# authorizes, and a verdict carrying pending/draft never authorizes. Hard in
# canonical mode; advisory in --draft. Mirrors check-brd.sh v0.3.1.
# v0.5.0: the ISO date must BIND to the verdict — on the verdict line or the
# line immediately following it, not anywhere near the Sign-off section.
# ---------------------------------------------------------------------------
SO_BODY="$(printf '%s\n' "$SO_STRIPPED" | awk '
  /^##[^#]/ {
    inside = (tolower($0) ~ /sign-off/) ? 1 : 0
    next
  }
  inside { print }
')"
HAS_SO_SECTION=0
printf '%s\n' "$SO_STRIPPED" | grep -qiE '^## +.*sign-off' && HAS_SO_SECTION=1
VERDICT_BLOCK="$(printf '%s\n' "$SO_BODY" | grep -iE -A 1 'verdict' | head -2 || true)"
VERDICT_LINE="$(printf '%s\n' "$VERDICT_BLOCK" | head -1)"
VERDICT_CANONICAL=0
if printf '%s\n' "$VERDICT_LINE" | grep -qiE '\bcanonical\b'; then
  if ! printf '%s\n' "$VERDICT_LINE" | grep -qiE '\b(pending|draft)\b'; then
    VERDICT_CANONICAL=1
  fi
fi
# The date must bind to the verdict: a calendar-valid ISO date on the verdict
# line itself or the line immediately following it. A date anywhere else in
# the document anchors nothing. Calendar validity comes from python3
# datetime when available (2026-02-30 is not a date); without python3 the
# regex shape alone decides, and the degraded check is called out.
HAS_SO_DATE=0
DATE_MATCH="$(printf '%s\n' "$VERDICT_BLOCK" | grep -oE "$ISO_RE" | head -1 || true)"
if [[ -n "$DATE_MATCH" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import datetime, sys
try:
    datetime.date.fromisoformat(sys.argv[1])
except ValueError:
    sys.exit(1)' "$DATE_MATCH" >/dev/null 2>&1; then
      HAS_SO_DATE=1
    fi
  else
    HAS_SO_DATE=1
    warn "python3 not found — ISO date matched by regex shape only (calendar validity unchecked)"
  fi
fi

if [[ "$MODE" == "canonical" ]]; then
  if [[ $HAS_SO_SECTION -eq 0 ]]; then
    err "Sign-off: section missing — a spec without the owner's verdict block is a draft (validate work-in-progress with --draft)"
  else
    if [[ $VERDICT_CANONICAL -eq 1 ]]; then
      ok "Sign-off: owner has marked the spec canonical (Gate H1)"
    else
      err "Sign-off: owner verdict 'canonical' missing — a draft cannot pass the canonical gate (validate work-in-progress with --draft)"
    fi
    if [[ $HAS_SO_DATE -eq 1 ]]; then
      ok "Sign-off: dated (calendar-valid ISO YYYY-MM-DD bound to the verdict)"
    else
      err "Sign-off: no valid ISO date (YYYY-MM-DD) on the verdict line or the line immediately following it — an undated verdict cannot anchor the descent"
    fi
  fi
else
  if [[ $VERDICT_CANONICAL -eq 1 ]]; then
    warn "Sign-off already reads canonical — run the default (canonical) mode for the Pass 2 handoff verdict"
  else
    warn "Sign-off pending — the spec is a draft until the owner signs it canonical (Pass 2 must not consume it)"
  fi
fi

# ---------------------------------------------------------------------------
# Leak scan — WARN on premature technology / stack (Pass 1 stays above it).
# v0.5.0 (P-9 item 1): terms live in references/leak-terms.txt, one
# `term<TAB>domain` per line across four buckets (data, web/frontend,
# infra/devops, ml/agents), matched case-insensitively with WORD BOUNDARIES
# (grep -wE) — 'spark' no longer fires on 'sparkline' or 'Dana Sparks',
# while React/Kubernetes/Terraform/LangChain are now covered. Fail-soft: a
# missing terms file skips the scan with a warning, never a crash. The
# first hit line per term is reported against the ORIGINAL body so the
# author can find it; the warning names the domain bucket.
# ---------------------------------------------------------------------------
LEAK_TERMS_FILE="$(cd "$(dirname "$0")" && pwd)/../references/leak-terms.txt"

LEAKS_FOUND=0
if [[ -f "$LEAK_TERMS_FILE" ]]; then
  while IFS=$'\t' read -r term domain || [[ -n "$term" ]]; do
    case "$term" in ''|\#*) continue ;; esac
    # Case-insensitive word-boundary match; -n for line-accurate reporting.
    hit="$(grep -nEi -w -e "$term" "$SPEC" 2>/dev/null | head -1 || true)"
    if [[ -n "$hit" ]]; then
      warn "possible stack leak [${domain:-unbucketed}] ('$term') — Pass 1 stays above the stack; defer to Pass 3: $hit"
      LEAKS_FOUND=$((LEAKS_FOUND + 1))
    fi
  done < "$LEAK_TERMS_FILE"
  if [[ $LEAKS_FOUND -eq 0 ]]; then
    ok "No premature technology named (stays above the stack)"
  fi
else
  warn "leak-term list not found ($LEAK_TERMS_FILE) — stack-leak scan skipped; verify by hand that no technology is named (Pass 3 owns the stack)"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo "check-tech-spec.sh — $SPEC"
echo "════════════════════════════════════════════════════════════"
if [[ $NPASS -gt 0 ]]; then
  echo "Passed:"
  i=0
  while [[ $i -lt $NPASS ]]; do echo "  [x] ${PASSES[$i]}"; i=$((i + 1)); done
fi
if [[ $NWARN -gt 0 ]]; then
  echo "Warnings ($NWARN):"
  i=0
  while [[ $i -lt $NWARN ]]; do echo "  [!] ${WARNINGS[$i]}"; i=$((i + 1)); done
fi
if [[ $NERR -gt 0 ]]; then
  echo "Failed ($NERR):"
  i=0
  while [[ $i -lt $NERR ]]; do echo "  [ ] ${ERRORS[$i]}"; i=$((i + 1)); done
  echo "────────────────────────────────────────────────────────────"
  if [[ "$MODE" == "canonical" ]]; then
    echo "FAIL: $NERR required check(s) failed — do not descend to Pass 2"
    echo "CHECK_TECH_SPEC=FAIL"
  else
    echo "DRAFT: incomplete — fix the structural items above, then keep drafting."
    echo "CHECK_TECH_SPEC=DRAFT_INCOMPLETE"
  fi
  exit 1
fi
echo "────────────────────────────────────────────────────────────"
if [[ "$MODE" == "canonical" ]]; then
  if [[ $NWARN -gt 0 ]]; then
    echo "PASS: gate met with $NWARN warning(s) — canonical spec; review the warnings, then hand to Pass 2 (tech-req-to-adrs)"
  else
    echo "PASS: gate met — canonical tech-spec; hand to Pass 2 (tech-req-to-adrs)"
  fi
  echo "CHECK_TECH_SPEC=PASS"
else
  echo "DRAFT: structure OK — validation only; a draft NEVER descends to Pass 2 (owner sign-off + the canonical gate do that)."
  echo "CHECK_TECH_SPEC=DRAFT_OK"
fi
exit 0
