---
name: evidence-to-next-pass
description: Converge descent conductor — derives the current and next pass from workspace evidence, enforces order with fail-closed pre/post hooks, and hands the agent the owning pass prompt. Use when someone asks "what's next", "where are we", "continue", "start pass N", "guide me through Converge", or requests a step-by-step or guided chat. In guided chat, present the stable choices from `cvg next --guided` and wait at every pass boundary; never infer CONTINUE. Run the pre-hook first, the pass prompt second, and the post-hook plus authoritative gate last. Do NOT use this skill to waive a gate, treat evidence presence as a verdict, or pick a lane (`cvg lane` owns that).
metadata:
  version: "0.2.1"
  compatibility: "Converge chain · sequence layer above all passes. Engine/tracker-agnostic; bash 3.2+ (macOS system bash safe); read-only — never mutates the workspace."
---

# evidence-to-next-pass — the descent, in order, every time

> **Identity:** The conductor — knows where the descent stands and what comes next, by reading the floor, not by remembering.
> **Domain:** Sequencing, pre/post enforcement, prompt delivery. Runs above every pass, changes nothing.
> **Converge Pass:** none — the layer that walks passes 0→8 in lane order.
> **Engine/flags:** any session. `scripts/next-pass.sh next|pre|post`, `--guided`, `--lane FULL|NORMAL|FAST`.

The nine passes are enforced individually by their gates — but the *order between
them* used to live in the human's (or the conductor agent's) head. This skill makes
the sequence itself machine-derived: every pass leaves evidence in a known
`cvg/` folder, so the current position is always readable from the workspace.
No state file, no memory, no drift between sessions.

## The three verbs

```bash
bash scripts/next-pass.sh next [--guided] [--lane FULL|NORMAL|FAST] # position + optional choices
bash scripts/next-pass.sh pre  <N> [--lane ...]            # may pass N start?
bash scripts/next-pass.sh post <N>                         # did pass N leave its artifact?
```

- **`next`** prints the evidence board (one line per pass in the lane, ✓ or ·),
  then `NEXT_PASS=<N>` (or `DONE`), the steering prompt to hand the agent
  (the owning skill's `references/pass-prompt.md`), and the gate that closes it.
  Also available as **`cvg next`**.
- **`next --guided`** adds a stable user-choice boundary without changing the
  sequence or writing session state. Also available as **`cvg next --guided`**.
- **`pre N`** is the fail-closed door: every lane pass before N must have left
  its evidence. `PASS_PRE=OK` or `PASS_PRE=MISSING` (exit 1) naming
  exactly what's absent.
- **`post N`** verifies pass N's own artifact landed in its folder:
  `PASS_POST=OK` or `PASS_POST=INCOMPLETE` (exit 1) — and always
  reminds you which `cvg` gate gives the *authoritative* verdict.

## How a chat session uses this

1. Session opens (or resumes) → run `next`. It says where the descent stands —
   no scroll-back, no re-explaining, no tokens spent reconstructing state.
2. Before steering a pass → `pre N`. If it refuses, the missing step IS the
   instruction.
3. Steer the pass with its prompt file — one file, not the whole method.
4. After the pass → `post N`, then the pass's own `cvg` gate. Both must be
   green before `next` will move on.

## Guided chat mode

Read [references/guided-chat-contract.md](references/guided-chat-contract.md)
when the user asks for a guided, procedural, or step-by-step experience.

The short form is:

1. Run `cvg next --guided` at session start, resume, and after a green pass.
2. Present the emitted `CONTINUE`, `EXPLAIN`, `INSPECT`, and `PAUSE` choices.
3. Wait. Never interpret silence, enthusiasm, or a previous choice as the next
   `CONTINUE`.
4. On `CONTINUE`, run `cvg next pre N`, load only the printed pass prompt, and
   perform that one pass.
5. Run `cvg next post N` and the printed authoritative gate. A red gate stays in
   the pass; a green gate returns to step 1.

The CLI derives position, the pass skill teaches the work, and the pass gate
decides. Chat is the human-facing control surface, not a second authority.

## The one rule

**Evidence presence is not a verdict.** The conductor reads that a BRD file
exists; only `cvg capture` says it PASSES. The conductor sequences; the gates
decide. It can refuse forward motion (pre-hook), but it can never grant it —
a `PASS_PRE=OK` with a failing gate downstream still fails.

Pass 6 (Register) is opt-in and never blocks the sequence; its evidence is
reported as informational. Lane selection belongs to `cvg lane` — pass the
lane you were given, don't infer one.

## Where the prompts live

Each **pass skill** owns its own steering prompt at
`skills/<pass-skill>/references/pass-prompt.md` — this skill owns only the
pass→skill map that resolves them, and `references/folder-map.md` (the
cross-pass folder-discipline table). Prompts ship with the package and are
**never copied into a consuming project**: one copy, always current, no files
the project did not author.
