# Pass 8 · The Loop — attempt → verify → repeat

**Mission:** drive ONE bound task to a terminal state. The engine attempts,
the sealed evals verify, and the kernel repeats within budgets. You (the
steering agent) do not implement — the loop's engine does, in a fresh
process, in an isolated worktree.

**Inputs:** a bound spec from the `cvg ready` frontier.

**Procedure:**
1. Preflight the ceiling: `cvg loop --estimate --issue <id>` — know the
   budget before you authorize spending it.
2. `cvg loop --issue <id> --agent claude|codex|kimi|omp`. Flags may only
   *tighten* the spec's budgets. Watch for the terminal token:
   `TASK_LOOP=SETTLED` (shipped through the outward legs) ·
   `LOCAL_SETTLED` (success that stopped at a local commit because the
   policy denies external writes — correct, not a failure) · `NO_OP` ·
   or an honest failure: `BLOCKED | STALLED | EXHAUSTED | CANCELLED | ERROR`.
3. On settlement, accept: `cvg tasks accept <spec>` → evals re-run by the
   referee, blast radius checked, seal verified → `ACCEPT`.
4. Where it earns it, ask the cross-family judge:
   `cvg verify --task <spec> --judge <other-family>` → `CHECK_VERIFY=UPHELD`
   (or `REFUTED` — a refutation is the system working; bring it to the human).
5. Confirm the receipt landed in `cvg/receipts/`, then `cvg ready` for the
   next task. `EXHAUSTED` is a planned landing: work-in-progress is
   committed and `--resume` continues from the checkpoint.

**Boundaries:** never edit an eval to make it pass (the seal breaks; the
gate refuses); never claim done — only the tokens above are done.

**Exit:** every ready task settled, accepted, receipted — the frontier empty.
