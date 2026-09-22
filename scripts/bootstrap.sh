#!/usr/bin/env bash
# bootstrap.sh — clone to a green `make check` with no manual exports.
#
# WHY THIS EXISTS
# A green run needs the exact Task-Spec 3.8.0 commit (runtime also accepts
# 3.9.x; this pin is the reviewed pairing), the exact Seamwise 0.2.0 commit,
# a Python that can import jsonschema, and the locked document-memory module.
# Before this script those were separate setup steps, so the
# honest onboarding cost was "read carefully, then assemble it yourself."
#
# Dependencies land under .engines/, .venv/, and tools/memory/node_modules/, all gitignored.
# The Makefile finds them automatically, so `make check` needs no arguments.
# Idempotent: re-running re-uses what is already correct.
#
# Token: BOOTSTRAP=OK | BOOTSTRAP=FAIL
# bash 3.2 safe. Deps: git, python3, Node.js >=22.17, npm.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || { echo "cannot enter repo"; echo "BOOTSTRAP=FAIL"; exit 1; }

# The release pairing. These are the same commits .github/workflows/ci.yml pins.
TASKSPEC_REPO="https://github.com/luanmorenommaciel/task-spec.git"
TASKSPEC_COMMIT="0e6180cfc3009bd4ef9cf7ab050b463e10d4af91"
TASKSPEC_VERSION="3.8.0"
SEAMWISE_REPO="https://github.com/luanmorenommaciel/seamwise.git"
SEAMWISE_COMMIT="5a398169c3fefcb65eb1a47c0cb4f967dfdc0515"
SEAMWISE_VERSION="0.2.0"
JSONSCHEMA_PIN="jsonschema==4.26.0"

ENGINES="$REPO/.engines"
VENV="$REPO/.venv"
FAILED=0

step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  ok   — %s\n' "$1"; }
bad()  { printf '  FAIL — %s\n' "$1"; FAILED=$((FAILED + 1)); }

echo "=================================================================="
echo "bootstrap — assembling the pinned release pairing"
echo "=================================================================="

step 1 "python virtualenv with jsonschema"
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV" || bad "could not create $VENV"
fi
if [ -x "$VENV/bin/python" ]; then
  if "$VENV/bin/python" -c "import jsonschema" 2>/dev/null; then
    ok "jsonschema already present"
  else
    "$VENV/bin/pip" install -q --disable-pip-version-check "$JSONSCHEMA_PIN" \
      && ok "installed $JSONSCHEMA_PIN" \
      || bad "could not install $JSONSCHEMA_PIN"
  fi
fi

# clone_engine <name> <repo> <commit> -> $ENGINES/<name> at that exact commit
clone_engine() {
  name="$1"; repo="$2"; commit="$3"
  dir="$ENGINES/$name"
  mkdir -p "$ENGINES"
  if [ -d "$dir/.git" ]; then
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
      ok "$name already at $commit"
      return 0
    fi
    git -C "$dir" fetch --quiet origin "$commit" 2>/dev/null || git -C "$dir" fetch --quiet origin
  else
    git clone --quiet "$repo" "$dir" || { bad "could not clone $name (private repo — is gh auth set up?)"; return 1; }
  fi
  git -C "$dir" checkout --quiet --detach "$commit" \
    && ok "$name checked out at $commit" \
    || { bad "could not check out $name at $commit"; return 1; }
}

step 2 "Task-Spec $TASKSPEC_VERSION"
if clone_engine task-spec "$TASKSPEC_REPO" "$TASKSPEC_COMMIT"; then
  got="$("$ENGINES/task-spec/bin/taskspec" --version 2>/dev/null | tr -d '[:space:]')"
  [ "$got" = "$TASKSPEC_VERSION" ] \
    && ok "reports $got" \
    || bad "expected $TASKSPEC_VERSION, got '${got:-nothing}'"
fi

step 3 "Seamwise $SEAMWISE_VERSION"
if clone_engine seamwise "$SEAMWISE_REPO" "$SEAMWISE_COMMIT"; then
  if [ -x "$VENV/bin/pip" ]; then
    "$VENV/bin/pip" install -q --disable-pip-version-check "$ENGINES/seamwise" \
      || bad "could not install seamwise into the venv"
    got="$("$VENV/bin/seamwise" --version 2>/dev/null)"
    case "$got" in
      *"$SEAMWISE_VERSION"*) ok "reports $got" ;;
      *) bad "expected $SEAMWISE_VERSION, got '${got:-nothing}'" ;;
    esac
  fi
fi

step 4 "locked native document-memory dependencies"
if ! command -v npm >/dev/null 2>&1; then
  bad "npm missing; install Node.js >=22.17 and npm"
elif npm ci --prefix "$REPO/tools/memory"; then
  ok "document memory dependencies installed without initializing a project vault"
else
  bad "could not install document memory dependencies"
fi

echo
echo "=================================================================="
if [ "$FAILED" -ne 0 ]; then
  echo "failed: $FAILED"
  echo "BOOTSTRAP=FAIL"
  exit 1
fi
echo "failed: 0 — the Makefile now finds these automatically."
echo
echo "  make check"
echo
echo "BOOTSTRAP=OK"
exit 0
