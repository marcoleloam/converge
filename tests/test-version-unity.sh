#!/usr/bin/env bash
# test-version-unity.sh — Converge ships as ONE unit, at ONE version.
#
# WHY THIS EXISTS
# Before 2026-07-29 the package carried NINE accidental version lineages: the
# skills once declared seven different `metadata.version` values (0.3.0 .. 1.1.0)
# or none at all, `bin/cvg` said 0.21.0, and two gate
# scripts kept private numbers behind their own `--version` flags. Nothing
# reconciled them, so "which version of Converge is this?" had no answer — and a
# skill could be edited without anything downstream noticing.
#
# The fix is not to force independent products onto one number. VERSION owns the
# Converge package; Task-Spec is now an external engine with an explicit compatible
# range. A Converge declaration must equal VERSION, and the engine boundary must
# resolve to 3.8.x or 3.9.x (reviewed release pin remains 3.8.0).
#
# WHAT COUNTS AS A VERSION HERE
# RELEASE versions unify — they answer "which Converge is this?". SCHEMA/FORMAT
# versions deliberately do NOT: `format_version: 3`, `VALIDATOR_VERSION="2"`,
# `agent_contract.version: 2` and `hmac-sha256-v3` describe a DATA CONTRACT whose
# whole purpose is to change independently of the release. Conflating the two
# would force a data migration on every release, which is the opposite of what a
# schema version is for. This gate checks release versions only, and the SCHEMA
# allowlist below is the recorded distinction.
#
# Usage:
#   bash tests/test-version-unity.sh            # gate (exit 0 pass / 1 fail)
#   bash tests/test-version-unity.sh --sync     # rewrite every site to VERSION
#
# Last line is always exactly one machine token:
#   VERSION_UNITY=PASS | VERSION_UNITY=FAIL | VERSION_UNITY=SYNCED
#
# bash 3.2 safe (stock macOS). Deps: grep, sed, awk.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || { echo "cannot enter repo"; echo "VERSION_UNITY=FAIL"; exit 1; }

SYNC=false
[ "${1:-}" = "--sync" ] && SYNC=true

PASS=0; FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL+1)); }

echo "=================================================================="
echo "test-version-unity.sh — one package, one version"
echo "=================================================================="

# ----- the source of truth -----
if [ ! -f VERSION ]; then
  echo "  FAIL — no VERSION file at the repo root; there is no source of truth"
  echo "VERSION_UNITY=FAIL"; exit 1
fi
PKG="$(tr -d ' \t\n\r' < VERSION)"
case "$PKG" in
  [0-9]*.[0-9]*.[0-9]*) ok "VERSION declares a semver: $PKG" ;;
  *) bad "VERSION is not a semver: '$PKG'"; echo "VERSION_UNITY=FAIL"; exit 1 ;;
esac

# ----- the release-version declaration sites -----
# Each entry: <file>|<sed-anchor>|<human label>. Anchors are exact variable
# assignments so a comment mentioning a version is never mistaken for one.
SITES="
bin/cvg|CVG_VERSION|the CLI
skills/idea-to-brd/scripts/check-brd.sh|CHECK_BRD_VERSION|the Pass 0 gate
skills/brd-docs-to-tech-req/scripts/check-tech-spec.sh|CHECK_TECH_SPEC_VERSION|the Pass 1 gate
"

echo
echo "[1] every code declaration equals VERSION"
printf '%s\n' "$SITES" | while IFS='|' read -r file var label; do
  [ -n "${file:-}" ] || continue
  if [ ! -f "$file" ]; then bad "$label: $file is missing"; continue; fi
  got="$(grep -m1 -E "^${var}=" "$file" 2>/dev/null | sed -E 's/^[A-Z_]+="?([^"]*)"?.*/\1/')"
  if [ -z "$got" ]; then
    bad "$label: no ${var}= declaration in $file"
  elif [ "$got" = "$PKG" ]; then
    ok "$label ($var) = $PKG"
  elif [ "$SYNC" = true ]; then
    sed -i.bak -E "s/^${var}=.*/${var}=\"${PKG}\"/" "$file" && rm -f "$file.bak"
    echo "  sync — $label ($var): $got -> $PKG"
  else
    bad "$label ($var) = $got, VERSION says $PKG — run with --sync"
  fi
done

# The subshell above cannot export counters back on bash 3.2 (no lastpipe), so
# re-derive the verdict from the files themselves rather than trusting a variable
# that the pipeline discarded. A gate that mis-reports its own result is worse
# than no gate.
CODE_DRIFT=0
for pair in \
  "bin/cvg:CVG_VERSION" \
  "skills/idea-to-brd/scripts/check-brd.sh:CHECK_BRD_VERSION" \
  "skills/brd-docs-to-tech-req/scripts/check-tech-spec.sh:CHECK_TECH_SPEC_VERSION"
do
  f="${pair%%:*}"; v="${pair##*:}"
  got="$(grep -m1 -E "^${v}=" "$f" 2>/dev/null | sed -E 's/^[A-Z_]+="?([^"]*)"?.*/\1/')"
  [ "$got" = "$PKG" ] || CODE_DRIFT=$((CODE_DRIFT+1))
done

# ----- JSON manifests -----
# These were MISSED by the first version of this gate, and the miss was caught by
# lint-skill-docs.sh rather than by CI: unifying the shell versions left
# plugin.json and marketplace.json at 3.6.0, so `task-spec` shipped claiming two
# different versions. A gate that enumerates "every declaration" has to actually
# enumerate them, including the ones that are not shell variables.
echo
echo "[1b] JSON manifests equal VERSION"
for jf in .claude-plugin/plugin.json .claude-plugin/marketplace.json \
          package.json apps/cockpit/package.json; do
  if [ ! -f "$jf" ]; then bad "$jf is missing"; continue; fi
  got="$(grep -m1 -E '"version"[[:space:]]*:' "$jf" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
  if [ "$got" = "$PKG" ]; then
    ok "$jf = $PKG"
  elif [ "$SYNC" = true ]; then
    sed -i.bak -E "s/(\"version\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\1\"${PKG}\"/" "$jf" && rm -f "$jf.bak"
    echo "  sync — $(basename "$jf"): $got -> $PKG"
  else
    bad "$(basename "$jf") = $got, VERSION says $PKG — run with --sync"
    CODE_DRIFT=$((CODE_DRIFT+1))
  fi
done

# ----- every skill declares metadata.version, and it matches -----
echo
echo "[2] every skill declares metadata.version = VERSION"
SKILL_N=0; SKILL_BAD=0
for d in skills/*/; do
  [ -f "$d/SKILL.md" ] || continue
  [ "$(basename "$d")" = "task-spec" ] && continue
  SKILL_N=$((SKILL_N+1))
  name="$(basename "$d")"
  got="$(awk '/^---[[:space:]]*$/{n++; next} n==1' "$d/SKILL.md" \
         | grep -m1 -E '^[[:space:]]+version:' | sed -E 's/.*version:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  if [ "$got" = "$PKG" ]; then
    continue
  elif [ "$SYNC" = true ] && [ -n "$got" ]; then
    sed -i.bak -E "s/^([[:space:]]+)version:[[:space:]]*\"?[^\"]*\"?[[:space:]]*$/\1version: \"${PKG}\"/" "$d/SKILL.md" \
      && rm -f "$d/SKILL.md.bak" && echo "  sync — $name: $got -> $PKG"
  else
    bad "$name declares version '${got:-<none>}', VERSION says $PKG"
    SKILL_BAD=$((SKILL_BAD+1))
  fi
done
[ "$SKILL_BAD" -eq 0 ] && ok "$SKILL_N skill(s) at $PKG"

# ----- no skill may reintroduce a private release lineage -----
# A per-skill `license:` is the same failure in a different field: one shipped
# unit cannot carry two licences (task-specs-to-issues once claimed Apache-2.0
# inside an MIT repo). The root LICENSE governs; skills declare none.
echo
echo "[3] no skill carries a private licence"
LIC="$(grep -l -E '^license:' skills/*/SKILL.md 2>/dev/null | tr '\n' ' ')"
if [ -z "$LIC" ]; then
  ok "no per-skill licence claims (root LICENSE governs the unit)"
else
  bad "per-skill licence found in: $LIC — the root LICENSE governs"
fi

# ----- the CLI's front door must claim the package version -----
# bin/README.md said v0.20.0 while the binary said 0.1.0 — the same class
# d6e8c92 fixed on the root readme, caught by a reviewer instead of a gate.
echo
echo "[3b] bin/README.md (the CLI front door) claims the package version"
if head -20 bin/README.md | grep -q "cvg $PKG"; then
  ok "bin/README.md header says cvg $PKG"
else
  bad "bin/README.md header claims a version the binary denies (wants: cvg $PKG)"
fi

# ----- the root front door must claim the package version -----
# d6e8c92 fixed the root readme claiming an old version, and a reviewer caught
# it — not a gate. This is that gate: both identity claims must equal VERSION.
echo
echo "[3c] README.md (the root front door) claims the package version"
if grep -q "Converge $PKG" README.md && grep -q "cvg $PKG" README.md; then
  ok "README.md says Converge $PKG and cvg $PKG"
else
  bad "README.md claims a version the package denies (wants: Converge $PKG / cvg $PKG)"
fi

# ----- the independent engine boundary must be explicit and satisfiable -----
echo
echo "[4] Task-Spec is independently versioned and compatibility-gated"
SCHEMA_OK=0
REQUIRED="$(grep -m1 '^CVG_TASKSPEC_REQUIRED=' bin/cvg | cut -d'"' -f2)"
TASKSPEC_VERSION_BIN="${TASKSPEC_BIN:-${CVG_TASKSPEC_BIN:-taskspec}}"
ENGINE="$("$TASKSPEC_VERSION_BIN" version 2>/dev/null | tail -1 | tr -d '[:space:]')"
if [ "$REQUIRED" = "3.8.0" ]; then
  ok "Converge declares the Task-Spec 3.8.0 pin"
else
  bad "CVG_TASKSPEC_REQUIRED must declare the reviewed 3.8.0 pin"
  SCHEMA_OK=1
fi
case "$ENGINE" in
  3.8.*|3.9.*) ok "installed Task-Spec engine is inside the supported 3.8.x–3.9.x range ($ENGINE)" ;;
  *) bad "installed Task-Spec engine is outside 3.8.x–3.9.x ('$ENGINE')"; SCHEMA_OK=1 ;;
esac

echo
echo "=================================================================="
echo "RESULTS: $PASS passed, $FAIL failed  (package version $PKG)"
if [ "$SYNC" = true ]; then
  echo "VERSION_UNITY=SYNCED"; exit 0
fi
if [ "$FAIL" -eq 0 ] && [ "$CODE_DRIFT" -eq 0 ] && [ "$SCHEMA_OK" -eq 0 ]; then
  echo "VERSION_UNITY=PASS"; exit 0
else
  echo "VERSION_UNITY=FAIL"; exit 1
fi
