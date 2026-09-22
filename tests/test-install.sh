#!/usr/bin/env bash
# test-install.sh — the install surface, exercised the way a stranger will use it.
#
# Everything here runs against a THROWAWAY consuming repo, never this checkout.
# The install path is the one part of Converge that is only ever exercised by
# people who are not us, so it gets tested the same way they'll hit it: clone,
# run install.sh, use `cvg` from PATH with no environment set.
#
# Bash 3.2 compatible (stock macOS).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0

ok()  { printf '  ok   — %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL — %s\n' "$1"; FAIL=$((FAIL + 1)); }
local_state_fingerprint() {
  local f
  for f in config identity projection.lock; do
    printf '%s:' "$f"
    if [ -f "$SRC/.cvg/$f" ]; then
      cksum < "$SRC/.cvg/$f"
    elif [ -e "$SRC/.cvg/$f" ]; then
      printf 'NON_REGULAR\n'
    else
      printf 'MISSING\n'
    fi
  done
}
file_mode() {
  # GNU first: on Linux, BSD-style `stat -f` is FILESYSTEM status and exits 0
  # with the wrong answer, so it must be the fallback, never the first try.
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

echo "=================================================================="
echo "install surface"
echo "=================================================================="

T="$(mktemp -d -t cvg-install.XXXXXX)"
git -C "$T" init --quiet
SOURCE_LOCAL_BEFORE="$(local_state_fingerprint)"

OUT="$(bash "$SRC/install.sh" --target "$T" --bin-dir "$T/bin" 2>&1)"
RC=$?

if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^INSTALL=OK$'; then
  ok "a clean install succeeds and emits INSTALL=OK"
else
  bad "install failed (rc=$RC)"
fi

# Every skill, and only skills — skills/README.md must not become a skill dir.
AGENT_COUNT="$(find "$T/.agents/skills" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')"
CLAUDE_COUNT="$(find "$T/.claude/skills" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')"
GROK_COUNT="$(find "$T/.grok/skills" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')"
EXPECTED="$(find "$SRC/skills" -maxdepth 2 -name SKILL.md ! -path '*/task-spec/SKILL.md' | wc -l | tr -d ' ')"
if [ "$AGENT_COUNT" = "$EXPECTED" ] && [ "$CLAUDE_COUNT" = "$EXPECTED" ] && [ "$GROK_COUNT" = "$EXPECTED" ]; then
  ok "every skill installs for Codex/Kimi, Claude Code, and Grok Build ($EXPECTED each)"
else
  bad "installed agents=$AGENT_COUNT claude=$CLAUDE_COUNT grok=$GROK_COUNT, expected $EXPECTED each"
fi

# The release default is a pinned copy. The CLI companion must travel with it.
VOUT="$("$T/bin/cvg" version 2>&1)"
if printf '%s' "$VOUT" | grep -q '^cvg ' \
  && [ -f "$T/bin/cvg" ] && [ ! -L "$T/bin/cvg" ] \
  && [ -f "$T/bin/.cvg-ui.sh" ] \
  && [ -f "$T/.agents/bin/_cvg_compose.py" ] \
  && [ -f "$T/.agents/bin/cvg-agent-context.py" ] \
  && [ -f "$T/.agents/contracts/cli-command-matrix.json" ]; then
  ok "pinned cvg copy runs with its packaged UI companion"
else
  bad "pinned cvg package is incomplete: $(printf '%s' "$VOUT" | head -1)"
fi

# A consuming repo has no CVG_HOME and no .cvg/ — the CLI must still work.
LOUT="$(cd "$T" && env -u CVG_HOME "$T/bin/cvg" lane "fix a typo in the readme" 2>&1)"
if printf '%s' "$LOUT" | grep -q '^LANE=FAST$'; then
  ok "the CLI works from a consuming repo with no configuration"
else
  bad "the CLI needs configuration a new user does not have"
fi

# Project-local state must resolve against the consuming repo, even though the
# PATH command is a symlink back into the Converge tool checkout. Invoke from
# inside the canonical cvg/ workspace to exercise nearest-project discovery.
(cd "$T" && env -u CVG_HOME -u CVG_PROJECT_ROOT "$T/bin/cvg" init >/dev/null)
SNAPSHOT_OUT="$(cd "$T" && env -u CVG_HOME -u CVG_PROJECT_ROOT "$T/bin/cvg" snapshot --json)"
if printf '%s' "$SNAPSHOT_OUT" | python3 -c 'import json,sys; s=json.load(sys.stdin)["data"]["snapshot"]; assert s["source"] == "workspace" and s["schemaVersion"] == "3.0"' 2>/dev/null; then
  ok "installed CLI produces a real workspace snapshot without the source checkout"
else
  bad "installed snapshot command is unavailable or malformed"
fi
DRY_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup identity --map backend:future-engine=dry@example.invalid \
  --dry-run 2>&1)"
if printf '%s' "$DRY_OUT" | grep -q '^DRY_RUN=OK$' \
  && [ ! -e "$T/.cvg/identity" ]; then
  ok "identity writes participate in the global no-op dry-run contract"
else
  bad "identity dry-run changed project state or missed DRY_RUN=OK"
fi

REPO_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup repo \
  --url https://example.invalid/acme/consumer/blob/main 2>&1)"
TRACKER_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  TSI_FAKE_STORE="$T/fake-tracker" "$T/bin/cvg" setup tracker fake 2>&1)"
IDENTITY_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup identity \
  --map backend:future-engine=engine@example.invalid \
  --map agent:reviewer=reviewer@example.invalid \
  --map default=default@example.invalid 2>&1)"
if printf '%s' "$REPO_OUT" | grep -q '^SETUP_REPO=OK$' \
  && printf '%s' "$TRACKER_OUT" | grep -q '^SETUP_TRACKER=OK$' \
  && printf '%s' "$IDENTITY_OUT" | grep -q '^SETUP_IDENTITY=OK$' \
  && grep -q '^spec_base_url=https://example.invalid/acme/consumer/blob/main$' "$T/.cvg/config" \
  && grep -q '^tracker=fake$' "$T/.cvg/config" \
  && grep -q '^backend:future-engine=engine@example.invalid$' "$T/.cvg/identity" \
  && [ ! -e "$T/cvg/.cvg" ]; then
  ok "installed setup writes config and identity to the consuming project root"
else
  bad "installed setup confused tool home, workspace directory, and project root"
fi

LIST_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  TSI_FAKE_STORE="$T/fake-tracker" "$T/bin/cvg" setup identity --list \
  --dry-run 2>&1)"
if printf '%s' "$LIST_OUT" | grep -q '^SETUP_IDENTITY=OK$' \
  && ! printf '%s' "$LIST_OUT" | grep -q '^DRY_RUN=OK$'; then
  ok "identity discovery is correctly classified as read-only"
else
  bad "identity discovery was incorrectly short-circuited as a mutation"
fi

if [ "$(file_mode "$T/.cvg/config")" = "600" ] \
  && [ "$(file_mode "$T/.cvg/identity")" = "600" ]; then
  ok "machine-local .cvg choices are permissioned 0600"
else
  bad "machine-local .cvg choices are not permissioned 0600"
fi

# A local-state path is still an input boundary. Never follow a symlink while
# replacing config: that could read an unrelated target into the new file or
# make setup appear to write somewhere it does not own.
mv "$T/.cvg/config" "$T/.cvg/config.keep"
printf 'target-must-stay-untouched\n' > "$T/config-target"
ln -s "$T/config-target" "$T/.cvg/config"
SYMLINK_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup repo \
  --url https://example.invalid/acme/unsafe/blob/main 2>&1)"
SYMLINK_RC=$?
if [ "$SYMLINK_RC" -ne 0 ] \
  && [ -L "$T/.cvg/config" ] \
  && [ "$(cat "$T/config-target")" = "target-must-stay-untouched" ] \
  && printf '%s' "$SYMLINK_OUT" | grep -q 'refusing non-regular or symlinked'; then
  ok "machine-local config refuses a symlink without touching its target"
else
  bad "machine-local config followed or replaced a symlink"
fi
rm -f "$T/.cvg/config"
mv "$T/.cvg/config.keep" "$T/.cvg/config"

# Identity is its own input boundary and must never follow a symlink.
mv "$T/.cvg/identity" "$T/.cvg/identity.keep"
printf 'identity-target-must-stay-untouched\n' > "$T/identity-target"
ln -s "$T/identity-target" "$T/.cvg/identity"
IDENTITY_SYMLINK_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup identity --map backend:future-engine=unsafe@example.invalid 2>&1)"
IDENTITY_SYMLINK_RC=$?
if [ "$IDENTITY_SYMLINK_RC" -ne 0 ] \
  && [ -L "$T/.cvg/identity" ] \
  && [ "$(cat "$T/identity-target")" = "identity-target-must-stay-untouched" ] \
  && printf '%s' "$IDENTITY_SYMLINK_OUT" | grep -q 'regular, non-symlink'; then
  ok "identity refuses a symlink without touching its target"
else
  bad "identity followed or replaced a symlink"
fi
rm -f "$T/.cvg/identity"
mv "$T/.cvg/identity.keep" "$T/.cvg/identity"

# v0.1 ships one public name. Near-miss legacy/plural commands must not quietly
# survive as aliases and make the contract ambiguous again.
OLD_PLURAL_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup identities --list 2>&1)"
OLD_PLURAL_RC=$?
OLD_PEOPLE_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  "$T/bin/cvg" setup people --list 2>&1)"
OLD_PEOPLE_RC=$?
if [ "$OLD_PLURAL_RC" -eq 2 ] && [ "$OLD_PEOPLE_RC" -eq 2 ] \
  && printf '%s' "$OLD_PLURAL_OUT" | grep -q '^SETUP=USAGE_ERROR$' \
  && printf '%s' "$OLD_PEOPLE_OUT" | grep -q '^SETUP=USAGE_ERROR$'; then
  ok "identity is the only setup name"
else
  bad "a legacy or plural setup alias is still accepted"
fi

# The local choices/cache must not show up in `git add .` candidates, even when
# the consuming repo began with no .gitignore. setup owns the machine-local
# boundary through .git/info/exclude.
printf 'project\tdemo\tFAKE-PROJECT-demo\n' > "$T/.cvg/projection.lock"
STATUS_OUT="$(cd "$T/cvg/tasks" && env -u CVG_HOME -u CVG_PROJECT_ROOT \
  TSI_FAKE_STORE="$T/fake-tracker" "$T/bin/cvg" setup 2>&1)"
LOCAL_TRACKED="$(git -C "$T" status --porcelain --untracked-files=all \
  | awk '{print $2}' | grep -E '^\\.cvg/(config|identity|projection\\.lock)$' || true)"
if printf '%s' "$STATUS_OUT" | grep -q 'projection.lock: 1 objects cached' \
  && [ -z "$LOCAL_TRACKED" ]; then
  ok "project-local cache discovery is correct and all local .cvg state is Git-excluded"
else
  bad "local .cvg state leaked into Git or resolved against the tool checkout"
fi

SOURCE_LOCAL_AFTER="$(local_state_fingerprint)"
if [ "$SOURCE_LOCAL_BEFORE" = "$SOURCE_LOCAL_AFTER" ]; then
  ok "installed CLI never mutates the Converge tool checkout's local .cvg state"
else
  bad "installed CLI mutated the Converge tool checkout instead of its consumer"
fi

# Re-running must not damage a working install.
OUT2="$(bash "$SRC/install.sh" --target "$T" --bin-dir "$T/bin" 2>&1)"
EXPECTED_SKIPS=$((EXPECTED * 3))   # three harness dirs: .agents, .claude, .grok
if printf '%s' "$OUT2" | grep -q "skipped $EXPECTED_SKIPS" && "$T/bin/cvg" version >/dev/null 2>&1; then
  ok "re-running the installer is safe and skips what is already there"
else
  bad "re-running the installer is not idempotent"
fi

# Installing into the checkout itself is a mistake worth refusing.
if ! bash "$SRC/install.sh" --target "$SRC" >/dev/null 2>&1; then
  ok "installing onto the Converge checkout itself is refused"
else
  bad "the installer overwrote its own source"
fi

# --copy must pin, not link — explicit and default copy have the same contract.
T2="$(mktemp -d -t cvg-install2.XXXXXX)"
git -C "$T2" init --quiet
bash "$SRC/install.sh" --target "$T2" --no-bin --copy >/dev/null 2>&1
if [ -d "$T2/.agents/skills/idea-to-brd" ] && [ ! -L "$T2/.agents/skills/idea-to-brd" ] \
  && [ -d "$T2/.claude/skills/idea-to-brd" ] && [ ! -L "$T2/.claude/skills/idea-to-brd" ] \
  && [ -d "$T2/.grok/skills/idea-to-brd" ] && [ ! -L "$T2/.grok/skills/idea-to-brd" ] \
  && [ -f "$T2/.agents/bin/_cvg_compose.py" ] \
  && [ -f "$T2/.agents/bin/cvg-agent-context.py" ] \
  && [ ! -e "$T2/.agents/bin/cvg-plan-tasks.py" ] \
  && [ -f "$T2/.agents/contracts/converge-composition-receipt-v1.schema.json" ] \
  && [ -f "$T2/.agents/tools/memory/index.mjs" ] \
  && [ -f "$T2/.agents/tools/memory/package.json" ] \
  && [ -f "$T2/.agents/tools/memory/package-lock.json" ] \
  && [ -f "$T2/.agents/tools/memory/LICENSE" ] \
  && [ ! -d "$T2/.agents/tools/memory/node_modules" ] \
  && [ -f "$T2/.agents/skills/converge/SKILL.md" ] \
  && [ ! -L "$T2/.agents/skills/converge" ] \
  && [ ! -d "$T2/.agents/skills/task-spec" ]; then
  ok "--copy pins Converge skills and helpers without embedding Task-Spec"
else
  bad "--copy still produced a symlink"
fi

# --symlink is retained as an explicit development mode.
T3="$(mktemp -d -t cvg-install3.XXXXXX)"
git -C "$T3" init --quiet
bash "$SRC/install.sh" --target "$T3" --symlink --bin-dir "$T3/bin" >/dev/null 2>&1
if [ -L "$T3/.agents/skills/idea-to-brd" ] \
  && [ -L "$T3/.claude/skills/idea-to-brd" ] \
  && [ -L "$T3/.grok/skills/idea-to-brd" ] \
  && [ -L "$T3/.agents/bin/_cvg_compose.py" ] \
  && [ -L "$T3/.agents/bin/cvg-agent-context.py" ] \
  && [ ! -e "$T3/.agents/bin/cvg-plan-tasks.py" ] \
  && [ -L "$T3/.agents/contracts/cli-command-matrix.json" ] \
  && [ -L "$T3/.agents/tools/memory" ] \
  && [ -L "$T3/.agents/skills/converge" ] \
  && [ -L "$T3/bin/cvg" ] \
  && "$T3/bin/cvg" version >/dev/null 2>&1; then
  ok "--symlink explicitly enables the live development install"
else
  bad "--symlink did not produce a working development install"
fi

rm -rf "$T" "$T2" "$T3"

echo "------------------------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS — %d install checks green.\n' "$PASS"
  exit 0
fi
printf 'FAIL — %d of %d install checks red.\n' "$FAIL" "$((PASS + FAIL))"
exit 1
