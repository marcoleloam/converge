#!/bin/bash
# check-brd.sh — Converge Pass 0 gate checker (the exit contract).
#
# Three modes:
#   canonical (default)  The handoff gate. Structure AND authorization: the
#                        owner's sign-off must say 'canonical' on the verdict
#                        line itself (a verdict carrying 'pending'/'draft'
#                        never authorizes) with a VALID calendar-real ISO
#                        date on a Date/Signed line, scope In/Out must carry
#                        real entries (a bullet saying "none"/"n/a" is not an
#                        entry), every open question a nonblank owner in the
#                        record shape, every numbered Problem line
#                        provenance-tagged on its line, (guessed) numbers
#                        linked to an open question.
#                        ONLY this mode may print the Pass 1 handoff verdict.
#   --draft              Validation while writing. Same structural checks;
#                        ownership/provenance/sign-off items downgrade to
#                        warnings. NEVER authorizes handoff, no matter how
#                        complete the brief.
#   --no-go <file>       Validates a no-go record (the pass's other honest
#                        exit): a no-go marker, a calendar-real ISO date,
#                        the do-nothing reasoning (why), what would reopen
#                        it, and a named owner for the call.
#
# All checks run on the file with fenced code blocks stripped — an example
# inside ``` fences can neither satisfy nor trip a check (v0.3.1).
#
# Section headings match EXACTLY (v0.4.0): '## Problematic' does not satisfy
# '## Problem' — the heading must be the template's name followed by
# whitespace (e.g. '## Goals & KPIs') or end of line, case-insensitive.
#
# ISO dates are calendar-real (v0.4.0): the regex screens shape and month/day
# ranges, python3 datetime proves the date exists (2026-02-31 is not a date).
# Without python3 the gate falls back to the regex and WARNs — never silent.
#
# Semantic judgment (owner voice, altitude leaks) stays WARN in every mode —
# the human judges voice; this script mechanizes only the provable. Hygiene
# items (do-nothing evidence, a >60-word executive summary, an unnamed
# decider) are likewise WARN-only in every mode (v0.4.0).
#
# Agent contract: the LAST line is always a stable machine token —
#   CHECK_BRD=PASS | FAIL | DRAFT_OK | DRAFT_INCOMPLETE | NOGO_OK
#             | NOGO_INVALID | USAGE_ERROR
# so a harness greps one line and never parses prose. Usage errors exit 2
# AND still end in CHECK_BRD=USAGE_ERROR (v0.3.1 — agents are users too).
#
# PDF policy: this verifier reads text (.md). A .pdf brief is a consensus
# object — convert it (or emit --out-format md) and gate the .md.
#
# bash 3.2 safe (macOS system bash).

set -euo pipefail

# The PACKAGE version, not this script's own. Converge ships as ONE unit:
# the root VERSION file is the source of truth and tests/test-version-unity.sh
# fails the build if any declaration here drifts from it. Bump VERSION, then
# run that gate with --sync.
CHECK_BRD_VERSION="0.2.1"

# A valid ISO date SHAPE: month 01-12, day 01-31 (2026-13-45 is not a date).
# First screen only — iso_dates_real() proves the day exists in its month.
ISO_RE='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'

usage_error() {
  printf 'ERROR: %s\n' "$1" >&2
  printf 'usage: check-brd.sh [--draft] docs/brd/<slug>.md\n' >&2
  printf '       check-brd.sh --no-go docs/no-go/<slug>.md\n' >&2
  printf '       check-brd.sh --version\n' >&2
  echo "CHECK_BRD=USAGE_ERROR"
  exit 2
}

MODE="canonical"
FILE=""
DRAFT_SET=0
NOGO_SET=0

for ARG in "$@"; do
  case "$ARG" in
    --version) echo "check-brd v$CHECK_BRD_VERSION"; exit 0 ;;
    --draft)   MODE="draft"; DRAFT_SET=1 ;;
    --no-go)   MODE="nogo";  NOGO_SET=1 ;;
    -h|--help)
      echo "usage: check-brd.sh [--draft] docs/brd/<slug>.md" >&2
      echo "       check-brd.sh --no-go docs/no-go/<slug>.md" >&2
      echo "       check-brd.sh --version" >&2
      echo "CHECK_BRD=USAGE_ERROR"
      exit 2
      ;;
    -*)
      usage_error "unknown flag '$ARG' — expected --draft, --no-go, --version, or a file path"
      ;;
    *)
      if [ -n "$FILE" ]; then
        usage_error "more than one file argument ('$FILE', '$ARG') — gate one brief per run"
      fi
      FILE="$ARG"
      ;;
  esac
done

if [ "$DRAFT_SET" -eq 1 ] && [ "$NOGO_SET" -eq 1 ]; then
  usage_error "--draft and --no-go conflict — a record is a BRD draft or a no-go, never both"
fi

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  usage_error "file missing: '$FILE'"
fi

case "$FILE" in
  *.pdf)
    echo "ERROR: this verifier reads text (.md) — a .pdf is a consensus object." >&2
    echo "Convert it (or re-emit with --out-format md), then gate the .md." >&2
    echo "CHECK_BRD=USAGE_ERROR"
    exit 2
    ;;
esac

# BODY: the file with fenced code blocks stripped. Every check below reads
# BODY, never the raw file — an example inside ``` fences proves nothing.
BODY="$(awk '/^[[:space:]]*```/ { fence = !fence; next } !fence { print }' "$FILE")"

FAIL=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=1; }
warn() { printf 'WARN  %s\n' "$1"; }

# own() — an ownership/authorization check: hard in canonical, advisory in draft.
own() {
  if [ "$MODE" = "canonical" ]; then
    fail "$1"
  else
    warn "$1 (draft: advisory)"
  fi
}

# iso_dates_real — reads stdin, exits 0 iff at least one ISO-shaped date on
# it is a REAL calendar date (v0.4.0). The regex screens shape and month/day
# ranges; python3's datetime settles February 31sts and leap years. Without
# python3 the gate falls back to the regex result and WARNs — never silent.
iso_dates_real() {
  CANDS="$(grep -oE "$ISO_RE" | sort -u || true)"
  if [ -z "$CANDS" ]; then
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$CANDS" | python3 -c '
import sys
from datetime import date
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        date.fromisoformat(line)
        sys.exit(0)
    except ValueError:
        pass
sys.exit(1)
'
    return $?
  fi
  warn "python3 not found — ISO date checked by regex only (calendar-real check skipped)"
  return 0
}

# --- extract a section body: lines after "## <name>" until the next "## " ---
# The heading match is EXACT (v0.4.0): the template's section name followed
# by whitespace or end of line — '## Problematic' opens no section.
section() {
  printf '%s\n' "$BODY" | awk -v want="$1" '
    BEGIN { re = "^## +" tolower(want) "([[:space:]]|$)" }
    /^##[^#]/ {
      inside = (tolower($0) ~ re) ? 1 : 0
      next
    }
    inside { print }
  '
}

# ===========================================================================
# --no-go mode — validate the pass's other honest exit, then leave.
# ===========================================================================
if [ "$MODE" = "nogo" ]; then
  if printf '%s\n' "$BODY" | grep -qiE 'no-go'; then
    pass "no-go: record identifies itself as a no-go"
  else
    fail "no-go: no 'no-go' marker found — say what this record is"
  fi
  if printf '%s\n' "$BODY" | iso_dates_real; then
    pass "no-go: dated (valid ISO YYYY-MM-DD)"
  else
    fail "no-go: no valid ISO date — a parked idea needs its parking date"
  fi
  if printf '%s\n' "$BODY" | grep -qiE '(^|[[:space:]#*-])why([^a-z]|$)'; then
    pass "no-go: states why it didn't clear (the do-nothing reasoning)"
  else
    fail "no-go: no 'why' — record the do-nothing answer: why the pain didn't justify a build"
  fi
  if printf '%s\n' "$BODY" | grep -qiE 'reopen'; then
    pass "no-go: states what would reopen it"
  else
    fail "no-go: nothing would reopen it? — a no-go is parked, not deleted; name the reopen condition"
  fi
  if printf '%s\n' "$BODY" | grep -qiE '(^|[[:space:]#*-])owner[*]*:[*]*[[:space:]]*[^[:space:]]'; then
    pass "no-go: named owner — someone owns the call to park it"
  else
    fail "no-go: no named owner — record who made the no-go call (owner: <name>)"
  fi
  echo
  if [ "$FAIL" -eq 0 ]; then
    echo "NO-GO RECORD: valid — the idea is parked honestly."
    echo "CHECK_BRD=NOGO_OK"
    exit 0
  else
    echo "NO-GO RECORD: invalid — fix the items above."
    echo "CHECK_BRD=NOGO_INVALID"
    exit 1
  fi
fi

# ===========================================================================
# BRD modes (canonical | draft)
# ===========================================================================

# 1 — required sections (structural: hard in every mode). Headings match
#     EXACTLY (v0.4.0): the name, then whitespace or end of line — so
#     '## Problematic' cannot stand in for '## Problem', while the
#     template's own '## Goals & KPIs' still satisfies 'Goals'.
for SEC in "Executive summary" "Problem" "Goals" "Scope" "Definition of success" "Stakeholders" "Risks" "Constraints" "Open questions" "Source" "Sign-off"; do
  if printf '%s\n' "$BODY" | grep -qiE "^## +${SEC}([[:space:]]|$)"; then
    pass "section present: $SEC"
  else
    fail "section missing: $SEC"
  fi
done

# 2 — quantified pain: at least one digit in the Problem section (structural)
if section "Problem" | grep -qE '[0-9]'; then
  pass "Problem is quantified (carries at least one number)"
else
  fail "Problem carries no number — cost, count, or frequency required ('a lot' is not a cost)"
fi

# 3 — at least one KPI line under Goals (structural)
if section "Goals" | grep -qE '([0-9]|->|→)'; then
  pass "Goals name at least one KPI-shaped line"
else
  fail "Goals section has no KPI — need at least one owner-metric, ideally current → target"
fi

# 4 — scope has both sides, and each side has real entries
SCOPE_BODY="$(section "Scope")"

scope_entries() {
  # count REAL entry lines inside the In or Out zone, including same-line
  # content after the marker ("**In:** everything" counts as 1). A bullet
  # whose text is empty or a content-free token — "nothing", "none", "n/a"
  # (trailing periods tolerated) — after stripping list markers and bold is
  # NOT an entry (v0.4.0): an empty In is not a scope decision.
  printf '%s\n' "$SCOPE_BODY" | awk -v which="$1" '
    function real_entry(s,   t, l) {
      t = s
      gsub(/\*\*/, "", t)
      sub(/^[[:space:]]*[-*+][[:space:]]+/, "", t)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      if (t == "") return 0
      l = tolower(t)
      sub(/[.]+$/, "", l)
      if (l == "nothing" || l == "none" || l == "n/a") return 0
      return 1
    }
    BEGIN { zone = 0; n = 0 }
    {
      low = tolower($0)
      if (low ~ /(\*\*|^)(in|out|undecided):?(\*\*|[[:space:]]|$)/) {
        zone = (low ~ ("(\\*\\*|^)" which ":?")) ? 1 : 0
        if (zone) {
          line = $0
          sub(/.*\*\*[A-Za-z]+:?\*\*/, "", line)
          sub(/^[A-Za-z]+:/, "", line)
          if (real_entry(line)) n++
        }
        next
      }
      if (zone && real_entry($0)) n++
    }
    END { print n }'
}

if printf '%s\n' "$SCOPE_BODY" | grep -qiE '\*\*In:?\*\*|^In:'; then
  IN_N="$(scope_entries in)"
  if [ "$IN_N" -ge 1 ]; then
    pass "Scope: In present with $IN_N entr(y/ies)"
  else
    fail "Scope: In has no entries — an empty In is not a scope decision"
  fi
else
  fail "Scope: no explicit In entry"
fi
if printf '%s\n' "$SCOPE_BODY" | grep -qiE '\*\*Out:?\*\*|^Out:'; then
  OUT_N="$(scope_entries out)"
  if [ "$OUT_N" -ge 1 ]; then
    pass "Scope: Out present with $OUT_N entr(y/ies)"
  else
    fail "Scope: Out has no entries — ask 'what are we explicitly NOT doing?'"
  fi
else
  fail "Scope: no explicit Out entry — ask 'what are we explicitly NOT doing?'"
fi

# 5 — every open question owned, in the record shape; unrecognized
#     question-shaped content FAILS CLOSED (the gate cannot verify what it
#     cannot parse — v0.3.1)
OQ_BODY="$(section "Open questions")"
Q_COUNT=$(printf '%s\n' "$OQ_BODY" | grep -cE '^- *question:' || true)
O_TOTAL=$(printf '%s\n' "$OQ_BODY" | grep -cE '^[[:space:]]*owner:' || true)
O_FILLED=$(printf '%s\n' "$OQ_BODY" | grep -cE '^[[:space:]]*owner:[[:space:]]*[^[:space:]]' || true)
if [ "$Q_COUNT" -eq 0 ]; then
  if printf '%s\n' "$OQ_BODY" | grep -qiE '(\?|question)'; then
    own "Open questions: content present but not in the record shape ('- question:' / 'owner:') — the gate cannot verify ownership of what it cannot parse"
  else
    pass "Open questions: none recorded (explicitly empty is allowed)"
  fi
else
  if [ "$O_TOTAL" -gt "$O_FILLED" ]; then
    own "Open questions: blank owner value(s) — every owner must be a name, not an empty field"
  fi
  if [ "$O_FILLED" -ge "$Q_COUNT" ]; then
    pass "Open questions: all $Q_COUNT record(s) carry a nonblank owner"
  else
    own "Open questions: $Q_COUNT record(s) but only $O_FILLED nonblank owner line(s) — every question needs a named owner"
  fi
fi

# 6 — number provenance (mechanically provable → hard in canonical)
PG_BODY="$(section "Problem"; section "Goals")"
if printf '%s\n' "$PG_BODY" | grep -qE '[0-9]'; then
  if printf '%s\n' "$PG_BODY" | grep -qE '\((measured|estimated|guessed)\)'; then
    pass "numbers carry provenance tags ((measured)/(estimated)/(guessed))"
  else
    own "numbers in Problem/Goals carry no provenance tag — tag each (measured), (estimated), or (guessed)"
  fi
fi

# 6b — per-line provenance in Problem (v0.4.0): one tag anywhere no longer
#      launders untagged numbers on neighboring lines — every Problem line
#      carrying a digit must carry a tag ON THAT LINE. (Goals stays on the
#      combined floor above: the golden's KPI targets are legitimately
#      untagged — a goal states ambition; the Problem states fact.)
PROBLEM_UNTAGGED="$(section "Problem" | grep -E '[0-9]' | grep -cvE '\((measured|estimated|guessed)\)' || true)"
if [ "$PROBLEM_UNTAGGED" -gt 0 ]; then
  own "Problem: $PROBLEM_UNTAGGED line(s) carry a number with no provenance tag on the line — tag each number (measured), (estimated), or (guessed)"
fi

if printf '%s\n' "$BODY" | grep -qE '\(guessed\)'; then
  if [ "$Q_COUNT" -ge 1 ]; then
    pass "(guessed) number(s) are linked: open question(s) exist to verify them"
  else
    own "(guessed) number(s) with no open question to verify them — a guess without a verification owner is a fabrication waiting to load-bear"
  fi
fi

# 7 — sign-off: the authorization boundary between draft and canonical.
#     Anchored to the VERDICT LINE (v0.3.1): 'canonical' anywhere else in the
#     section — a guidance sentence, an example — authorizes nothing.
SO_BODY="$(section "Sign-off")"
VERDICT_LINE="$(printf '%s\n' "$SO_BODY" | grep -iE 'verdict' | head -1 || true)"
VERDICT_CANONICAL=0
if printf '%s\n' "$VERDICT_LINE" | grep -qiE '\bcanonical\b'; then
  if ! printf '%s\n' "$VERDICT_LINE" | grep -qiE '\b(pending|draft)\b'; then
    VERDICT_CANONICAL=1
  fi
fi
DATE_LINES="$(printf '%s\n' "$SO_BODY" | grep -iE '(date|signed)' || true)"
if [ "$MODE" = "canonical" ]; then
  if [ "$VERDICT_CANONICAL" -eq 1 ]; then
    pass "Sign-off: owner has marked the brief canonical"
  else
    fail "Sign-off: owner verdict 'canonical' missing — a draft cannot pass the canonical gate (validate work-in-progress with --draft)"
  fi
  if printf '%s\n' "$DATE_LINES" | iso_dates_real; then
    pass "Sign-off: dated (calendar-real ISO YYYY-MM-DD)"
  else
    fail "Sign-off: no valid ISO date (real calendar date, YYYY-MM-DD) on a Date/Signed line — an undated sign-off cannot anchor the descent"
  fi
else
  if [ "$VERDICT_CANONICAL" -eq 1 ]; then
    warn "Sign-off already reads canonical — run the default (canonical) mode for the handoff verdict"
  else
    warn "Sign-off pending — the brief is a draft until the owner writes 'canonical' (Pass 1 must not consume it)"
  fi
fi

# 8 — altitude warnings (advisory in EVERY mode; the human judges voice)
if printf '%s\n' "$BODY" | grep -qiE '\b(the system shall|must implement|architecture|schema|database|endpoint|framework)\b'; then
  warn "possible solution-shape leak (requirement/tech language found) — keep the BRD in the owner's voice"
fi

# 9 — hygiene warnings (advisory in EVERY mode — they never fail the gate):
#     the do-nothing test leaves evidence, the summary fits in one breath,
#     and a decider is named when stakeholders could disagree (v0.4.0).
if ! printf '%s\n' "$BODY" | grep -qiE 'do-nothing|build nothing|do nothing'; then
  warn "no do-nothing-test evidence in the body — record what building nothing costs (the answer that justifies this BRD over a no-go)"
fi
ES_WORDS="$(section "Executive summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /[[:alnum:]]/) n++ } END { print n + 0 }')"
if [ "$ES_WORDS" -gt 60 ]; then
  warn "Executive summary runs $ES_WORDS words (> 60) — one breath; if it can't fit, revisit the scope-check"
fi
if ! section "Stakeholders" | grep -qiE 'decider'; then
  warn "no decider named in Stakeholders — when more than one stakeholder is named, name the tie-breaker"
fi

# ===========================================================================
# Verdict — only the canonical gate may authorize the handoff to Pass 1.
# ===========================================================================
echo
if [ "$MODE" = "canonical" ]; then
  if [ "$FAIL" -eq 0 ]; then
    echo "GATE: PASS — canonical brief; hand off to Pass 1 (brd-docs-to-tech-req)."
    echo "CHECK_BRD=PASS"
    exit 0
  else
    echo "GATE: FAIL — fix the items above; this brief is NOT authorized for Pass 1."
    echo "CHECK_BRD=FAIL"
    exit 1
  fi
else
  if [ "$FAIL" -eq 0 ]; then
    echo "DRAFT: structure OK — validation only; a draft is never authorized for Pass 1 (owner sign-off + the canonical gate do that)."
    echo "CHECK_BRD=DRAFT_OK"
    exit 0
  else
    echo "DRAFT: incomplete — fix the structural items above, then keep drafting."
    echo "CHECK_BRD=DRAFT_INCOMPLETE"
    exit 1
  fi
fi
