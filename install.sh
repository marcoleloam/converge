#!/usr/bin/env bash
# install.sh — make Converge usable from a consuming repo.
#
# Two things get installed, and they are deliberately separate:
#
#   1. the SKILLS  → <target>/.agents/skills/*   for Codex + Kimi (AGENTS.md family)
#                  → <target>/.claude/skills/*   for Claude Code
#                  → <target>/.grok/skills/*     for Grok Build
#   2. the CLI     → `cvg` on your PATH          so the gates are runnable by hand
#
# Copy (default) pins the complete 0.2.1 tool surface so a consuming repository
# does not depend on this checkout. `--symlink` is the explicit development mode.
#
# It also works with no checkout at all — the one-line install:
#
#   curl -fsSL https://raw.githubusercontent.com/luanmorenommaciel/converge/main/install.sh | bash
#
# When run standalone it shallow-clones the released source to a temp dir and
# hands off to the installer inside the clone. No TTY is assumed (a piped
# script has none), and every choice is overridable:
#   CVG_REF=v0.2.0 pin an exact release tag  (default: main)
#   CVG_REPO_URL=<url>    install from a fork or mirror
#
# This script installs. It never configures, never writes a credential, and
# never configures credentials. Re-running it is safe.
#
# Bash 3.2 compatible (stock macOS).
set -euo pipefail

# Resolve symlinks before locating ourselves: npm installs bins as symlinks
# (node_modules/.bin/cvg-install → this file), and the symlink's directory has
# no skills/ beside it — which would wrongly trigger the remote bootstrap.
_inst_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_inst_self" ]; do
  _inst_link="$(readlink "$_inst_self")"
  case "$_inst_link" in
    /*) _inst_self="$_inst_link" ;;
    *)  _inst_self="$(dirname "$_inst_self")/$_inst_link" ;;
  esac
done
CVG_SRC="$(cd "$(dirname "$_inst_self")" && pwd)"
unset _inst_self _inst_link
TARGET="$PWD"
MODE="copy"
BIN_DIR=""
DO_BIN=1
FORCE=0
ORIG_ARGS=("$@")

usage() {
  cat <<EOF
usage: install.sh [--target DIR] [--copy|--symlink] [--bin-dir DIR] [--no-bin] [--force]

  --target DIR   repo to install into            (default: current directory)
  --copy         copy the complete tool surface  (default; pins this version)
  --symlink      link to this checkout            (development only)
  --bin-dir DIR  where to install \`cvg\`          (default: first writable of
                 ~/.local/bin, /usr/local/bin)
  --no-bin       skip the CLI, install skills only
  --force        replace existing skill entries

Examples
  # one-line install into the current repo (no checkout needed)
  curl -fsSL https://raw.githubusercontent.com/luanmorenommaciel/converge/main/install.sh | bash
  # from a checkout
  cd ~/my-project && bash /path/to/converge/install.sh
  bash install.sh --target ~/my-project --copy
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)  [ $# -ge 2 ] || { echo "ERROR: --target requires a directory" >&2; exit 2; }; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#--target=}"; shift ;;
    --copy)    MODE="copy"; shift ;;
    --symlink) MODE="symlink"; shift ;;
    --bin-dir) [ $# -ge 2 ] || { echo "ERROR: --bin-dir requires a directory" >&2; exit 2; }; BIN_DIR="$2"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}"; shift ;;
    --no-bin)  DO_BIN=0; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# --- 0. remote bootstrap ------------------------------------------------------
# No skills/ or bin/cvg beside this file means we are running standalone
# (curl | bash, or a copied script). Fetch the released source and hand off to
# the installer inside the clone. The clone is temporary: the default copy mode
# pins everything into the target, so nothing references it afterwards — which
# is also why --symlink is refused here (it would link into a deleted dir).
if [ ! -d "$CVG_SRC/skills" ] || [ ! -f "$CVG_SRC/bin/cvg" ]; then
  [ "$MODE" = "symlink" ] && { echo "ERROR: the one-line install is copy-only — clone the repo for a --symlink development install" >&2; exit 2; }
  command -v git >/dev/null 2>&1 || { echo "ERROR: the one-line install needs git on PATH" >&2; exit 2; }
  REPO_URL="${CVG_REPO_URL:-https://github.com/luanmorenommaciel/converge.git}"
  REF="${CVG_REF:-main}"
  echo "Converge one-line install — fetching $REPO_URL @ $REF"
  CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/converge-install.XXXXXX")"
  trap 'rm -rf "$CLONE_DIR"' EXIT
  git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$CLONE_DIR" \
    || { echo "ERROR: could not clone $REPO_URL @ $REF" >&2; exit 2; }
  bash "$CLONE_DIR/install.sh" --target "$TARGET" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  exit $?
fi

[ -d "$TARGET" ] || { echo "ERROR: target '$TARGET' does not exist" >&2; exit 2; }
TARGET="$(cd "$TARGET" && pwd)"

# Task-Spec is an independent engine and release lineage. Converge installs its
# own orchestration skills only; it refuses to smuggle an older engine copy into
# the consuming repository.
TASKSPEC_BIN="${CVG_TASKSPEC_BIN:-$(command -v taskspec 2>/dev/null || true)}"
[ -n "$TASKSPEC_BIN" ] || {
  echo "ERROR: Task-Spec engine is required. Install taskspec 3.8.x first:" >&2
  echo "  git clone https://github.com/luanmorenommaciel/task-spec.git" >&2
  echo "  bash task-spec/install.sh --global --copy" >&2
  exit 2
}
TASKSPEC_VERSION="$("$TASKSPEC_BIN" version 2>/dev/null | tail -1 | tr -d '[:space:]')"
case "$TASKSPEC_VERSION" in
  3.8.*) ;;
  *) echo "ERROR: Converge 0.2 requires taskspec 3.8.x (found '$TASKSPEC_VERSION')" >&2; exit 2 ;;
esac

if [ "$TARGET" = "$CVG_SRC" ]; then
  echo "ERROR: target is the Converge checkout itself. Install INTO a consuming repo." >&2
  exit 2
fi

echo "Converge → $TARGET"
echo "  source : $CVG_SRC"
echo "  mode   : $MODE"
echo

# --- 1. skills ---------------------------------------------------------------
INSTALLED=0
SKIPPED=0

for SKILL_DIR in "$TARGET/.agents/skills" "$TARGET/.claude/skills" "$TARGET/.grok/skills"; do
  mkdir -p "$SKILL_DIR"
  case "$SKILL_DIR" in
    */.agents/skills) printf '  shared skills (Codex + Kimi):\n' ;;
    */.claude/skills) printf '  Claude Code skills:\n' ;;
    */.grok/skills)   printf '  Grok Build skills:\n' ;;
  esac
  for src in "$CVG_SRC"/skills/*/; do
    [ -f "$src/SKILL.md" ] || continue
    name="$(basename "$src")"
    [ "$name" = "task-spec" ] && continue
    dest="$SKILL_DIR/$name"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if [ "$FORCE" -eq 1 ]; then
        rm -rf "$dest"
      else
        printf '  skip   %-32s (exists — use --force to replace)\n' "$name"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
    fi
    if [ "$MODE" = "copy" ]; then
      cp -R "$src" "$dest"
      # A pinned package must not carry developer-machine bytecode, caches, or
      # metadata. Python .pyc files embed their source path and would make the
      # supposedly clean install depend on this checkout.
      find "$dest" -type d \( -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache \) -prune \
        | while IFS= read -r cache_dir; do rm -rf "$cache_dir"; done
      find "$dest" -type f \( -name '*.pyc' -o -name '*.pyo' -o -name .DS_Store \) -delete
    else
      ln -s "${src%/}" "$dest"
    fi
    printf '  ok     %-32s\n' "$name"
    INSTALLED=$((INSTALLED + 1))
  done
done

# The copied CLI resolves its tool home to <project>/.agents. Keep Converge's
# native planning helpers and workspace templates there; Task-Spec itself stays
# on PATH as the separately installed engine.
mkdir -p "$TARGET/.agents/bin" "$TARGET/.agents/contracts" "$TARGET/.agents/templates/workspace"
if [ "$MODE" = "copy" ]; then
  cp "$CVG_SRC/bin/_cvg_compose.py" "$TARGET/.agents/bin/_cvg_compose.py"
  cp "$CVG_SRC/bin/cvg-agent-context.py" "$TARGET/.agents/bin/cvg-agent-context.py"
  cp "$CVG_SRC/bin/cvg-classify-lane.py" "$TARGET/.agents/bin/cvg-classify-lane.py"
  cp "$CVG_SRC/contracts/"*.json "$TARGET/.agents/contracts/"
  cp "$CVG_SRC/templates/workspace/"*.md "$TARGET/.agents/templates/workspace/"
else
  ln -sf "$CVG_SRC/bin/_cvg_compose.py" "$TARGET/.agents/bin/_cvg_compose.py"
  ln -sf "$CVG_SRC/bin/cvg-agent-context.py" "$TARGET/.agents/bin/cvg-agent-context.py"
  ln -sf "$CVG_SRC/bin/cvg-classify-lane.py" "$TARGET/.agents/bin/cvg-classify-lane.py"
  for contract in "$CVG_SRC"/contracts/*.json; do
    ln -sf "$contract" "$TARGET/.agents/contracts/$(basename "$contract")"
  done
  for template in "$CVG_SRC"/templates/workspace/*.md; do
    ln -sf "$template" "$TARGET/.agents/templates/workspace/$(basename "$template")"
  done
fi

# --- 2. the CLI --------------------------------------------------------------
BIN_NOTE=""
if [ "$DO_BIN" -eq 1 ]; then
  if [ -z "$BIN_DIR" ]; then
    for cand in "$HOME/.local/bin" /usr/local/bin; do
      if [ -d "$cand" ] && [ -w "$cand" ]; then BIN_DIR="$cand"; break; fi
    done
    # ~/.local/bin is the conventional user-writable spot; create it if nothing else fits
    [ -z "$BIN_DIR" ] && { BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; }
  fi
  mkdir -p "$BIN_DIR"
  if [ -e "$BIN_DIR/cvg" ] && [ "$FORCE" -eq 0 ] && [ ! -L "$BIN_DIR/cvg" ]; then
    BIN_NOTE="  skip   cvg (a real file already sits at $BIN_DIR/cvg — use --force)"
  else
    rm -f "$BIN_DIR/cvg"
    if [ "$MODE" = "copy" ]; then
      cp "$CVG_SRC/bin/cvg" "$BIN_DIR/cvg"
      chmod +x "$BIN_DIR/cvg"
      cp "$CVG_SRC/bin/_ui.sh" "$BIN_DIR/.cvg-ui.sh"
      chmod 644 "$BIN_DIR/.cvg-ui.sh"
      BIN_NOTE="  ok     cvg pinned at $BIN_DIR/cvg"
    else
      ln -s "$CVG_SRC/bin/cvg" "$BIN_DIR/cvg"
      BIN_NOTE="  ok     cvg → $BIN_DIR/cvg"
    fi
  fi
  echo
  echo "$BIN_NOTE"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "  note   $BIN_DIR is not on your PATH — add it to use \`cvg\` directly" ;;
  esac
fi

# --- 3. verify ---------------------------------------------------------------
echo
VALIDATOR="$TARGET/.agents/skills/skill-creator/scripts/quick_validate.py"
if [ -f "$VALIDATOR" ] && python3 "$VALIDATOR" "$TARGET/.agents/skills/idea-to-brd" >/dev/null 2>&1; then
  echo "verified: Converge skills parse; Task-Spec engine is $TASKSPEC_VERSION"
else
  echo "WARNING: could not verify the install — run:"
  echo "  python3 $VALIDATOR $TARGET/.agents/skills/idea-to-brd"
fi

echo
echo "installed $INSTALLED skill(s), skipped $SKIPPED."
cat <<EOF

Next:
  1. initialize the tracked Converge control plane:
       cvg init
  2. provision the repo-private signing key:
       cvg setup signing
  3. restart Codex, Kimi, or Claude Code so it discovers the installed skills
  4. inspect readiness, then pick your lane:
       cvg setup
       cvg lane "what you are about to build"

INSTALL=OK
EOF
