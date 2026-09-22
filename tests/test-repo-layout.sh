#!/usr/bin/env bash
# test-repo-layout.sh — the tree shape is a contract, not a convention.
#
# WHY THIS EXISTS
# On 2026-08-17 the repository was reorganized: 27 top-level entries became 19,
# four directories were folded (presentation/ -> docs/decks/, review/ ->
# docs/reviews/, brand-kit-v1/ -> assets/, brand/ -> assets/), and ~32 MB of
# retired binaries left the tree. README.md documents the result in a table.
#
# A table is documentation. Documentation does not fail a build. Nothing stopped
# the next change from reintroducing a top-level scratch directory, or from
# quietly contradicting the table it was supposed to match. Every other structural
# claim in this repo is gated — the docs inventory, the package allowlist, the
# CLI matrix, tracked debris — except the shape of the tree itself.
#
# This closes that hole. Add a top-level entry without deciding it belongs, and
# this fails with the exact name to justify or remove.
#
# WHAT IT CHECKS
#   1. the tracked top-level set is exactly ALLOWED_* below
#   2. every directory that is a documented home carries a README
#   3. no retired path resurfaces (presentation/, brand/, docs/handbook/, ...)
#   4. README.md's directory table names every tracked top-level directory
#
# Token: LAYOUT=PASS | LAYOUT=FAIL
# bash 3.2 safe. Deps: git, grep, sed.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || { echo "cannot enter repo"; echo "LAYOUT=FAIL"; exit 1; }

FAILED=0
ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; FAILED=$((FAILED + 1)); }

# The tracked top-level contract. Every entry here is a deliberate home.
#   ships to npm   : bin contracts skills templates tools
#   product UI     : apps
#   proves it works: tests scripts evidence
#   explains it    : docs
#   brand          : assets
ALLOWED_DIRS=".claude-plugin .cvg .github apps assets bin contracts docs evidence scripts skills templates tests tools"
ALLOWED_FILES=".briefspec.toml .gitattributes .gitignore .npmignore AGENTS.md OPERATING.md CHANGELOG.md CLAUDE.md CONTRIBUTING.md LICENSE Makefile README.md VERSION install.sh package.json"

# Directories whose purpose must be stated in a README next to the files.
README_REQUIRED="assets bin contracts docs evidence scripts skills templates tests"

# Paths retired by the 2026-08-17 reorganization. Resurfacing is a regression.
RETIRED="presentation brand brand-kit-v1 output test-results tmp docs/handbook docs/releases docs/reviews docs/decks assets/brand-kit converge-brand-kit-v1.zip TODO.md"

echo "=================================================================="
echo "test-repo-layout.sh — the tree shape is gated, not merely documented"
echo "=================================================================="
echo
echo "[1] the tracked top-level set is exactly the declared contract"

TOP_DIRS="$(git ls-files | awk -F/ 'NF>1 {print $1}' | sort -u)"
TOP_FILES="$(git ls-files | awk -F/ 'NF==1 {print $1}' | sort -u)"

for entry in $TOP_DIRS; do
  case " $ALLOWED_DIRS " in
    *" $entry "*) ;;
    *) bad "undeclared top-level directory '$entry/' — justify it in ALLOWED_DIRS or move it" ;;
  esac
done
for entry in $ALLOWED_DIRS; do
  case " $(echo $TOP_DIRS) " in
    *" $entry "*) ;;
    *) bad "declared directory '$entry/' is gone — update ALLOWED_DIRS if that was intended" ;;
  esac
done
for entry in $TOP_FILES; do
  case " $ALLOWED_FILES " in
    *" $entry "*) ;;
    *) bad "undeclared top-level file '$entry' — justify it in ALLOWED_FILES or move it" ;;
  esac
done
[ "$FAILED" -eq 0 ] && ok "top level is exactly $(echo $TOP_DIRS | wc -w | tr -d ' ') dirs + $(echo $TOP_FILES | wc -w | tr -d ' ') files, all declared"

echo
echo "[2] every documented home explains itself"
for d in $README_REQUIRED; do
  if [ -f "$d/README.md" ]; then
    ok "$d/README.md"
  else
    bad "$d/ has no README.md — a home nobody can explain is a home nobody maintains"
  fi
done

echo
echo "[3] retired paths stay retired"
RESURFACED=0
for p in $RETIRED; do
  if [ -n "$(git ls-files "$p" 2>/dev/null)" ]; then
    bad "retired path '$p' is tracked again — it was removed on purpose on 2026-08-17"
    RESURFACED=1
  fi
done
[ "$RESURFACED" -eq 0 ] && ok "none of the $(echo $RETIRED | wc -w | tr -d ' ') retired paths came back"

echo
echo "[4] README.md's directory table names every tracked top-level directory"
README_BODY="$(cat README.md)"
MISSING_ROW=0
for d in $TOP_DIRS; do
  case "$d" in
    .*) continue ;;  # dotfile homes are infrastructure, not part of the reader-facing table
  esac
  # An open prefix: the table may name a more precise home (`apps/cockpit/`)
  # than the top-level directory it lives under.
  case "$README_BODY" in
    *"\`$d/"*) ;;
    *) bad "README.md's table does not mention '$d/' — the map must match the territory"; MISSING_ROW=1 ;;
  esac
done
[ "$MISSING_ROW" -eq 0 ] && ok "every reader-facing directory appears in the README table"

echo
echo "=================================================================="
if [ "$FAILED" -ne 0 ]; then
  echo "failed: $FAILED"
  echo "LAYOUT=FAIL"
  exit 1
fi
echo "failed: 0"
echo "LAYOUT=PASS"
exit 0
