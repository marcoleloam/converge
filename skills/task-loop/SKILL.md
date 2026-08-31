---
name: task-loop
description: The single execution loop for Converge Pass 8 (The Loop). Takes ONE issue (--issue N passed by a human or CI), verifies its Pass 7 execution profile, reads its signed Task-Spec and hash-bound evidence, cuts a branch, writes code, and runs the task's own eval in a bounded refinement loop until GREEN, then enforces the path policy and opens a PR. Use when a user or CI says "run issue N", "execute this task", "build task T-...", "work the loop", or "drive this issue to a green-eval PR". Knows one task deeply and never picks which task to run. Do NOT use to choose or fan out across tasks; that is the Manager, a future CI/CD concern outside the pass chain.
metadata:
  version: "0.2.1"
  compatibility: "Converge chain Pass 8; consumes cvg/tasks/T-*.md (then tasks/) + cvg/execution/<task-id>/execution-profile.yaml, resolved against the workspace and not the git root; any stack"
---

# task-loop — Pass 8 · The Loop (the execution loop)

The single EXECUTION loop of the Converge chain. Take exactly ONE issue that was handed to you (`--issue N`), verify its Pass 7 runtime contract, read its signed Task-Spec and bound evidence, cut a branch, write the code, and run **that task's own eval** in a tight local loop until it is GREEN. Before settlement, prove the diff stayed inside the Task-Spec path policy; then open a PR that closes the issue.

## Important — read these rules first

- **You never pick the task.** `--issue N` is required and comes from outside (a human, or CI). Absence of `--issue N` is an error, not an invitation to triage the backlog. Choosing *which* issue to run is the Manager's job, and the Manager is a future CI/CD concern (see below), not this skill and not a numbered pass.
- **Converged = the eval passed, not "feels done".** The merge gate is the exact eval command the task-spec carries, run in a clean subshell and exiting 0 — never an eyeballed diff. No green eval, no PR.
- **BIND before ACT is non-negotiable.** `CHECK_RUNTIME_CONTRACT=PASS` must be current before writing. Load the Task-Spec eval and every evidence reference in the profile.
- **Stay inside the task.** Respect `touches_paths` and `do-not-touch` from the spec. One task, deeply — never wander into a sibling task or refactor the world.
- **This is Pattern 3 (iterative refinement).** RED feeds the exact failure back and revises in a bounded local loop; it does not escalate or hop tasks. A task that cannot go green is surfaced as a blocked report, never papered over.

## The Manager remains outside this skill

The **Manager concern** — which issue runs, when, how many tasks run in
parallel, dependency settlement, locks, and worktrees — is an orchestration
layer **outside the numbered pass chain**: a future CI/CD concern (e.g. GitHub
Actions as scheduler, the PR as state settlement, branch protection as the
gate), tracked on the project roadmap. A human or that CI implementation
supplies `--issue N`; this loop drives that one issue to a green-eval PR and
stops. Task-local helpers allowed by the execution profile do not authorize
cross-task fan-out.

## Inputs / Outputs / Gate

| | Artifact | Path |
|---|----------|------|
| **IN** | ONE signed Task-Spec plus its current Pass 7 execution profile and bound evidence | `cvg/tasks/T-<id>.md` (then `tasks/`) · `cvg/execution/<task-id>/execution-profile.yaml` |
| **OUT** | A Pull Request that closes the issue (branch + diff + green eval in the body), a local commit when the policy denies external writes, OR an explicit blocked-task report | PR or commit on a `task/<id>-<slug>` branch |
| **GATE** | The task's own eval is **GREEN** — the exact `eval_N()` / Exit Check command from the spec exits 0, run not read | `bash`-run eval from `cvg/tasks/T-<id>.md` |

**Paths resolve against the workspace, never the git root.** `cvg/` may sit
below the repo root (`<repo>/projects/demo/cvg/`), so the loop derives its
workspace from the tasks dir it found and runs the spec's evals there. Anchoring
to the git root instead is the one bug this pass has re-learned repeatedly: it
sent the loop looking for its own task in the parent repo, and it made every
authorized path look like a policy violation because `git diff` reported the
whole repo while the `fs.write` scope was workspace-relative.

The eval is whatever the task-spec ships — it is written for *your* stack, not assumed to be any particular one. It typically drives the project end-to-end (prep/ingest → transform → assert the output/contract layer → optionally exercise the serving layer) and asserts the far end. The task-spec already ships this eval as runnable bash; you run it, you do not re-invent it. (For example, in a dbt/warehouse project the eval might run the project's build step, then the transform step, then query the published tables — but any stack's eval works the same way: run it, do not read it.)

## Flags

| Flag | Values | Default | Meaning |
|------|--------|---------|---------|
| `--issue N` | issue id / task id / spec path | **required** | The single issue this loop owns. No default — absence is an error. You do not re-pick it. |
| `--agent` | `claude` \| `codex` \| `kimi` | `claude` | The coding engine that ACTS. `kimi` for mechanical, tightly-specced work; `claude` for judgment work (contract/interface design); `codex` when passed. |
| `--no-agent` / `--gate-only` | flag | off | Verdict without an attempt. `--no-agent` runs the kernel's preflight and lands `BLOCKED` on RED; `--gate-only` skips the kernel entirely and runs the single-shot verify-and-settle leg. |
| `--max-iterations` · `--max-seconds` · `--max-tokens` | integer | from the spec | **Tighten** a budget for this run. They can only lower the spec's ceiling — a loop whose limit can be raised at the call site has no limit. |
| `--resume` | flag | off | Continue from the durable checkpoint instead of restarting — a restart would re-run side effects the previous attempts already applied. |
| `--allow-external-writes` | flag | off | Permit the push/PR leg when the profile's policy does not. |
| `--dry-run` | flag | off | Print the resolved spec, budgets and engine; touch nothing. |
| `--base` | branch | detected | Base branch for the diff and the PR. |
| `--contract` | profile path | `cvg/execution/<task-id>/execution-profile.yaml` | Explicit Pass 7 profile override. |
| `--legacy-no-contract` | flag | off | Supervised migration escape hatch; never use for new execution. |

The engine is a flag, never baked into the skill name. Whoever passes `--issue N` may also pin `--agent`; the loop does not change the issue.

## What makes this a loop and not a gate

Read [`references/loop-spec.md`](references/loop-spec.md) before changing
anything here — it is the design and its sources. The short version: a loop
specification is an external, bounded artifact carrying a **trigger, a goal, a
verification, a stopping rule and a memory**. Converge's trigger is
`cvg loop --issue`, its goal is the spec's Exit Check, its verification is the
eval plus an independent judge, its stopping rule is a named terminal state, and
its memory is the workspace on disk.

That distinction was earned the hard way. Until `loop-kernel.sh` existed, this
pass ran the eval **once** and reported RED or GREEN — while every spec declared
`budget_iterations`, `circuit_breaker_no_progress` and `on_terminal_failure` that
**nothing enforced**. A control that lives in an artifact and not in the runtime
is decoration; it is the same defect class as an `external_writes: deny` policy
no code consults. Four properties keep it honest now:

- **Each attempt is a fresh process.** A retry inside one session re-reads every
  prior failure, so cost grows quadratically while attention degrades — and
  content buried deep in a long context is attended to least. State lives on
  disk (`cvg/loop/<task-id>/`: the brief, the attempt log, the checkpoint), never
  in a conversation.
- **Budgets are three-axis and checked *before* the call.** Iterations, wall
  clock, and tokens fail differently — an agent can burn a token budget in four
  huge-context attempts or hang overnight on one tool call. Checking after the
  call means the money is already spent.
- **Stagnation beats a fixed count.** When the same check fails the same way
  `circuit_breaker_no_progress` times, the loop lands `STALLED` rather than
  spending its remaining budget re-deriving the same wrong answer. That is
  usually an upstream gap, not a coding failure.
- **Budget exhaustion is a planned landing.** Work-in-progress is committed to
  the branch and a `HANDOFF.md` records state and next steps, so `EXHAUSTED` is
  a report, not a crash.

## Terminal states — an error is never a success

The loop lands in exactly one named state, and only the first three exit zero.
Naming them is what stops a loop from calling *"I got tired of iterating"* a win.

| State | Meaning |
|---|---|
| `TASK_LOOP=SETTLED` | green eval, external writes permitted, PR opened |
| `TASK_LOOP=LOCAL_SETTLED` | green eval, the policy denies external writes — stopped at a local commit |
| `TASK_LOOP=NO_OP` | already green on arrival; nothing to do |
| `TASK_LOOP=BLOCKED` | needs a human, or an upstream input is missing |
| `TASK_LOOP=STALLED` | the stagnation detector fired |
| `TASK_LOOP=EXHAUSTED` | a budget ceiling was reached; handoff written |
| `TASK_LOOP=CANCELLED` | an external stop signal arrived (`cvg/loop/<id>/STOP`) |
| `TASK_LOOP=ERROR` | the loop itself could not continue safely |

## Engine adapters — the only place a vendor is spelled

The kernel knows no vendor. Each engine is one adapter under
`scripts/engines/<name>.sh` answering two calls: `--available` (can this host
run it?) and `--prompt-file F --workdir D` (run ONE attempt with a fresh
context, transcript to stdout, and `ENGINE_TOKENS=<n>` when the CLI reports
usage). Adding an engine is a new file, never a change to the loop. Every
attempt runs under a hard wall-clock cap — a hung engine must not hang the loop,
which was observed live in Pass 4 with `codex exec` blocking at 0% CPU — and
because macOS ships neither `timeout` nor `gtimeout`, a pure-bash watchdog
enforces the same cap and normalizes a timeout to exit 124.

## Instructions

### Step 1 — BIND + READ (verify the contract, then load evidence)

Resolve `--issue N` to `cvg/tasks/T-<id>.md` (then `tasks/`), locate its execution
profile beside the specs, and
require `CHECK_RUNTIME_CONTRACT=PASS`. Read the Task-Spec fully: goal,
`touches_paths`, anti-patterns, `do-not-touch`, and its Success Criteria plus
Exit Check. Load each hash-bound ADR, approved project-knowledge entry, and
cached external document named by the profile. Instantiate only the task-local
capabilities and topology the profile permits.

Stop conditions (do not code, emit a blocked report instead):
- No `--issue N` supplied → this loop never picks a task.
- The task-spec is missing or `signed_off: false` → upstream gap (Pass 5 gate not passed).
- The profile is missing or stale, or bound evidence is missing → upstream gap (Pass 7 Bind).

### Step 2 — ACT (cut a branch, write the code)

Cut a fresh branch `task/<id>-<slug>` off the default branch — never commit to
`main`. Hand the Task-Spec plus its bound evidence and adapter contract to
`--agent`. Use the candidate-path guard through a native hook when the runtime
supports it. Write only inside `touches_paths` and `creates_paths`; honor
`do-not-touch`.

### Step 3 — EVAL (run the task's own eval)

Run the exact eval the spec carries, in a clean subshell, via the bundled runner:

```bash
bash .claude/skills/task-loop/scripts/run-issue-eval.sh --issue <id>
```

It extracts the `eval_N()` bodies + Exit Check from the spec, runs each under `set -euo pipefail` **with the workspace as the working directory** (so a spec's own relative paths resolve where its author meant them to), and reports **GREEN** (Exit Check exits 0) or **RED** (with the failing eval's output). What "green" means is whatever the spec's eval asserts for your stack — a transform passing its tests, an output table returning the contracted shape, a serving endpoint returning the contracted response, etc. (For example, in a dbt/warehouse project: the transform step and its schema tests pass, a published table query returns the contracted shape, an API endpoint returns a contracted 200.) Run it — do not eyeball the diff.

### Step 4 — SETTLE (RED → revise locally · GREEN → open the PR)

- **RED:** feed the exact eval output back to `--agent`, revise inside `touches_paths`, and re-run Step 3. This is the bounded local refinement loop (Pattern 3) — it never leaves this issue and never touches another task. `budget_iterations` is now *enforced* by the kernel rather than merely declared; when it or the wall-clock/token ceiling runs out the loop lands `EXHAUSTED` with a handoff, and an upstream gap lands `BLOCKED` with a **blocked-task report** (what failed, the last eval output, the suspected upstream gap).
- **RED twice with the same failure → stop patching, start diagnosing.** Two consecutive REDs on the same assertion with no new hypothesis means the loop is guessing, and guessing burns `budget_iterations` without converging. Switch modes inside the same budget: (1) **reproduce minimally** — isolate the smallest input/command that shows the failure; (2) **hypothesize** — state in one sentence *why* it fails; (3) **verify the hypothesis** — with a read or an instrumented run, *before* writing the fix; (4) fix once, re-run the eval. A fix applied to a confirmed cause converges in one iteration; a fix applied to a guess converges by accident.
- **GREEN:** run the portable runtime-contract path guard over the complete diff.
  An out-of-scope path turns settlement RED even when the eval passed. Only
  after both gates pass may the loop open its one PR and emit its execution
  receipt.

## Entry point

```bash
cvg loop --issue <task-id>                    # the loop: attempt → verify → repeat, bounded
cvg loop --issue <task-id> --dry-run          # resolved spec, budgets and engine; touch nothing
cvg loop --issue <task-id> --gate-only        # a verdict with no agent and no attempts
cvg loop --issue <task-id> --resume           # continue from the durable checkpoint
cvg loop --issue <task-id> --agent codex --max-iterations 3
```

`cvg loop` routes to `scripts/loop-kernel.sh` — the kernel *is* the loop, and
`open-issue-pr.sh` is only its settlement leg (still reachable directly, and via
`--gate-only`, for a single-shot verdict).

This loop never picks its own work — `--issue` is required. The signed Task-Spec
is the only instruction source; the tracker issue is state, never instruction.
Stop an unattended run by writing `cvg/loop/<task-id>/STOP`; the loop honors it
at the next brake check and lands `CANCELLED`.

## Settlement — scoped, ordered, policy-governed

Settlement is where a green eval becomes a commit, and it is the easiest place to
quietly do more than was authorized. Three rules:

**Stage only the authorized paths.** Staging comes from the contract's `fs.write`
scope, never `git add -A`. This matters for a non-obvious reason: the postflight
guard inspects the *diff*, and `git diff` never lists **untracked** files — so a
brand-new file outside the task's scope could ride into the commit unseen. Every
staged path is re-checked against the scope before commit; anything outside it
un-stages the change and writes a blocked receipt.

**External writes are a separate effect.** The profile's `policy.external_writes`
defaults to `deny`. Settlement therefore stops at a **local commit** and prints
`TASK_LOOP=LOCAL_SETTLED`. Push and PR happen only when the policy allows it or
`--allow-external-writes` is passed explicitly. Commit, push, tracker mutation and
PR creation are four distinct effects, not one.

**The success receipt is written last.** It used to be written before the branch
even existed, so it could claim a settlement that never happened. A `pass` receipt
is now emitted only once the outcome it reports is known; a red run writes a
`blocked` receipt and stops.

## Gate — confirm before leaving this pass

- [ ] Exactly one issue was worked — the one named by `--issue N`; no other task was touched.
- [ ] The runtime contract passed and every bound evidence file was READ before code.
- [ ] Work happened on a `task/<id>-<slug>` branch, never directly on `main`.
- [ ] The task's eval was RUN (not eyeballed) and is GREEN — the exact command exits 0.
- [ ] The diff stays inside `touches_paths` and respects `do-not-touch`.
- [ ] The portable path-policy gate is PASS after the final diff.
- [ ] Output is a structured execution receipt plus either a PR that closes the
  issue (green eval in the body) or an explicit blocked-task report.
- [ ] The run landed in exactly ONE named terminal state, and no error or
  exhausted budget was reported as a success.

*Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches the PR — what changed, the decision each hunk encodes, what the eval actually proved — before the owner reviews or merges it.

When these hold, the issue has converged: green eval, branch, PR.

## Examples

**Example 1 — "run issue T-20260625-staging-views" (illustrated with a dbt/warehouse stack)**
Read the spec (staging views over your source tables,
`touches_paths: transform/models/staging`), require its runtime contract PASS,
and load the bound ADRs. Branch `task/staging-views`. `--agent kimi` writes the
models. The eval goes RED on row parity, the confirmed cause is fixed, and the
next run is GREEN. The path guard also passes, so one PR closes the issue.

**Example 2 — "execute this task" with no issue given**
No `--issue N`. → **Result:** stop and report that the loop never picks a task; a human or CI must pass `--issue N` (choosing which issue is the future CI/CD Manager's job).

**Example 3 — "build task T-...-published-tables" but its ADR is missing**
Spec cites an ADR that does not exist under `docs/adrs/`. → **Result:** emit a blocked-task report naming the missing ADR (a Pass 2 gap) — do not guess the decision.

## Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| Loop asks which task to run | No `--issue N` | Pass `--issue N`; this loop never triages. Fan-out is the future CI/CD Manager. |
| Eval fails with "syntax error"/"unbound variable" | Broken eval bash, not a real assertion failure | Fix belongs upstream in the task-spec (Pass 5 gate). Emit a blocked report, don't hack the eval. |
| Eval RED after budget exhausted | Task not settleable in `budget_iterations`, or upstream gap | The loop lands `EXHAUSTED` and writes `cvg/loop/<id>/HANDOFF.md`. Read the handoff, fix the cause (often upstream), then `--resume`. Do not open a PR. |
| `TASK_LOOP=STALLED` after a few attempts | The same check failed the same way `circuit_breaker_no_progress` times | Believe it — more iterations will not help. Diagnose instead: reproduce minimally, state why it fails, verify that hypothesis, then fix once. Usually an upstream gap. |
| "could not resolve --issue … under /…/tasks" | The loop was anchored to the git root, not the workspace | Run from the workspace, or pass `--tasks-dir`. `cvg/tasks/` is discovered before `tasks/`; a workspace below the repo root is a supported layout. |
| Engine attempt produces nothing and the log ends in a timeout note | The engine CLI hung on a model round-trip | Expected and contained — the adapter's watchdog kills it at the cap and normalizes to 124. Check the engine's auth, or pick another `--agent`. |
| The loop must be stopped now | An unattended run is doing the wrong thing | `touch cvg/loop/<task-id>/STOP`. It lands `CANCELLED` at the next brake check, before spending anything more. |
| Green diff but you want to "also fix" a nearby file | Scope creep past `touches_paths` | Stay in scope. Open a new task-spec for the other change; this loop owns one task. |
| Committed to `main` | Skipped the branch step | Branch first (`task/<id>-<slug>`); revert `main`. The PR is the unit of merge. |
