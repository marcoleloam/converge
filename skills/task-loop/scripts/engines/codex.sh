#!/usr/bin/env bash
# codex.sh — Pass 8 execution engine: OpenAI Codex CLI, headless.
#
# `--sandbox workspace-write` is the point: Codex confines writes to the working
# tree at the OS level, which makes fs.write a PREVENTED capability here rather
# than a merely DETECTED one. That difference is what the capability envelope's
# assurance field records, and it is why codex can satisfy a --require that
# generic cannot.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_engine_lib.sh"
eng_parse_args "$@"

CMD="${CVG_CODEX_CMD:-codex}"
[ "$ENG_MODE" = "available" ] && { command -v "$CMD" >/dev/null 2>&1; exit $?; }

RC=0
TRANSCRIPT="$(mktemp -t cvg-codex-transcript.XXXXXX)" || exit 4
cleanup_transcript() { rm -f "$TRANSCRIPT"; }
trap cleanup_transcript EXIT HUP INT TERM
cd "$ENG_WORKDIR" || exit 4
# Positional prompt rather than stdin: `codex exec [PROMPT]` accepts it directly,
# and passing it as an argument removes a whole class of plumbing failure (a
# backgrounded job losing its redirect) that is invisible in the transcript —
# it looks like the model produced nothing.
# stdin MUST be explicitly closed. `codex exec` documents that "if stdin is
# piped and a prompt is also provided, stdin is appended as a <stdin> block" —
# so with an open-but-never-closed stdin it reads the positional prompt, does
# the work, and then BLOCKS forever waiting for an EOF that never arrives. The
# watchdog eventually kills it at 124 and the whole attempt reads as a timeout,
# which hides the fact that the model finished minutes earlier.
# Model availability depends on the authenticated provider/account. Keep the
# operator's explicit tier mapping when configured; otherwise let Codex choose
# its supported default instead of pinning an expired model identifier.
ENG_ARGS=()
CODEX_MODEL="${CVG_CODEX_MODEL:-}"
if [ -z "$CODEX_MODEL" ]; then
  case "$ENG_MODEL" in
    haiku)  CODEX_MODEL="${CVG_CODEX_MODEL_HAIKU:-}" ;;
    sonnet) CODEX_MODEL="${CVG_CODEX_MODEL_SONNET:-}" ;;
    opus)   CODEX_MODEL="${CVG_CODEX_MODEL_OPUS:-}" ;;
  esac
fi
[ -z "$CODEX_MODEL" ] || ENG_ARGS+=(--model "$CODEX_MODEL")
case "$ENG_EFFORT" in
  low|medium|high) ENG_ARGS+=(-c "model_reasoning_effort=$ENG_EFFORT") ;;
  *)               : ;;
esac

to "$ENG_TIMEOUT" "$CMD" exec --sandbox workspace-write \
  "${ENG_ARGS[@]+"${ENG_ARGS[@]}"}" "$(cat "$ENG_PROMPT")" \
  </dev/null >"$TRANSCRIPT" 2>&1 || RC=$?

# A provider CLI may start MCP children that outlive the CLI process. If those
# children inherit this adapter's stdout pipe, the loop's command substitution
# never observes EOF even though the provider already completed the work. A
# regular file does not have that lifetime coupling: publish the completed
# transcript after the provider exits, then let cleanup unlink the inode.
cat "$TRANSCRIPT"

eng_finish "$RC"
