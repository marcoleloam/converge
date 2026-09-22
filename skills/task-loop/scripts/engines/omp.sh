#!/usr/bin/env bash
# OMP execution adapter: host process + postflight detection, NOT a sandbox.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_engine_lib.sh"
eng_parse_args "$@"
CMD="${CVG_OMP_CMD:-omp}"
[ "$ENG_MODE" = "available" ] && { command -v "$CMD" >/dev/null 2>&1; exit $?; }

# Model-role suffixes own thinking effort; never overwrite them with a lane's
# vendor-neutral effort. No --profile: credentials and role mappings stay global.
MODEL="@task"
case "$ENG_MODEL" in
  haiku) MODEL="@smol" ;;
  opus) MODEL="@slow" ;;
esac
PROMPT="$(cat "$ENG_PROMPT")" || exit 4
ROOM="$(mktemp -d -t cvg-omp.XXXXXX)" || exit 4
trap 'rm -rf "$ROOM"' EXIT HUP INT TERM
cd "$ENG_WORKDIR" || exit 4
STARTED=$SECONDS
RC=0
# Exclude ambient discovery (including MCP) without changing global settings or
# relaxing the operator's existing provider/tool deny and prompt policies.
for KEY in disabledProviders tools.approval; do
  LEFT=$(( ENG_TIMEOUT - (SECONDS - STARTED) ))
  [ "$LEFT" -gt 0 ] || { eng_finish 124; exit 124; }
  to "$LEFT" "$CMD" config get "$KEY" --json </dev/null >"$ROOM/$KEY.json" 2>"$ROOM/config.err" || RC=$?
  if [ "$RC" -ne 0 ]; then cat "$ROOM/config.err" >&2; eng_finish "$RC"; exit "$RC"; fi
done
python3 - "$ROOM" <<'PY' || exit 4
import json
import sys
from pathlib import Path
room = Path(sys.argv[1])
disabled = json.loads((room / "disabledProviders.json").read_text())["value"]
approval = json.loads((room / "tools.approval.json").read_text())["value"]
if not isinstance(disabled, list) or not isinstance(approval, dict):
    raise ValueError("OMP config did not return provider/tool policies")
for source in ("native", "claude", "codex", "gemini", "github", "opencode", "cursor", "windsurf", "agents-md"):
    if source not in disabled:
        disabled.append(source)
# Bash is required for task evaluation. Explicit user deny/prompt still wins;
# destructive-command safety prompts also remain active in approval mode write.
approval.setdefault("bash", "allow")
(room / "worker.json").write_text(json.dumps({
    "disabledProviders": disabled,
    "enabledProviders": [],
    "mcp": {"enableProjectConfig": False},
    "tools": {"approval": approval},
}))
PY
LEFT=$(( ENG_TIMEOUT - (SECONDS - STARTED) ))
[ "$LEFT" -gt 0 ] || { eng_finish 124; exit 124; }
# Close stdin: print mode otherwise waits forever for piped input before its
# own max-time starts. Capture to a file so surviving child pipes cannot hang us.
to "$LEFT" "$CMD" --cwd "$ENG_WORKDIR" --config "$ROOM/worker.json" \
  --model "$MODEL" --mode json --no-session --no-extensions --no-skills \
  --no-rules --no-title --tools read,bash,edit,write,grep,glob,lsp \
  --approval-mode write --max-time "$LEFT" -p "$PROMPT" \
  </dev/null >"$ROOM/transcript.jsonl" 2>&1 || RC=$?
cat "$ROOM/transcript.jsonl"
if [ "$RC" -eq 0 ]; then
  python3 - "$ROOM/transcript.jsonl" <<'PY' || RC=$?
import json
import sys
messages = []
with open(sys.argv[1]) as stream:
    for line in stream:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        message = event.get("message", {})
        if event.get("type") == "message_end" and message.get("role") == "assistant":
            messages.append(message)
usage = [m["usage"]["totalTokens"] for m in messages
         if isinstance(m.get("usage", {}).get("totalTokens"), int)]
if usage:
    print(f"ENGINE_TOKENS={sum(usage)}")
# An empty/truncated stream or provider abort cannot count as a clean attempt,
# even if a CLI version exits zero. Evaluation and acceptance remain separate.
if not messages or messages[-1].get("stopReason") != "stop":
    print("OMP did not finish an assistant turn successfully", file=sys.stderr)
    sys.exit(1)
PY
fi
eng_finish "$RC"
