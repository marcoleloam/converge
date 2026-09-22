# Skills reference

The native `converge` entry accompanies eleven method skills. Pass 5 Tasking is
standalone [`taskspec`](https://github.com/luanmorenommaciel/task-spec), not a mirrored skill.

## Native entry · `converge`

**Purpose:** Start or resume a demand through existing `cvg deliver` commands
and retrieve cited project context through `cvg memory`.

**When:** Deliver this demand, resume it, inspect its current checkpoint, or
search project document memory.

**Not:** A replacement for owner approval, Task-Spec authorization, independent
acceptance, or the pass skills. It adds no autonomous execution authority.

**Evidence:** The observed delivery checkpoint and memory citations; `READY`
memory never means a demand is authorized or accepted.

## Pass 0 · `idea-to-brd` (optional)

**Purpose:** Turn a raw idea with no client brief — a founder thought, an
internal itch — into a BRD written in the owner's voice, or into a no-go record
when the pain doesn't justify a build.

**When:** Someone says "I have an idea", "capture this idea", "write the brief",
"grill me about this idea", or "start Converge pass 0".

**Not:** When a BRD exists (enter at Pass 1) or to write a tech-spec (that IS
Pass 1).

**Gate:** `CHECK_BRD=PASS` — the pain carries a provenance-tagged number, at
least one KPI is in the owner's terms, scope in/out are non-empty, every open
question has a named owner.

## Pass 1 · `brd-docs-to-tech-req`

**Purpose:** Transform a client BRD into a verifiable tech-spec with falsifiable
requirements and metrics traced to the BRD's KPIs.

**When:** A brief has landed and someone says "turn this brief into a tech-spec",
"start Converge pass 1", or "what are we actually building here".

**Not:** For architecture or stack decisions (that is Pass 3), when a signed-off
tech-spec already exists (go to Pass 2), or when no BRD exists at all (run Pass
0 first).

**Gate:** `CHECK_TECH_SPEC=PASS` — restate the problem in one paragraph AND the
spec answers it, every requirement falsifiable and prioritized, success metrics
traced to the BRD's KPIs, no unresolved blocker gaps.

## Pass 2 · `tech-req-to-adrs`

**Purpose:** Ground the Pass 1 tech-spec against the real system and record
grounding decisions as ADRs under `docs/adrs/`.

**When:** User says "structure pass", "write the ADRs", "ground the spec against
the repo", "is this greenfield or brownfield", or "start Pass 2".

**Not:** For solution design or "build X" statements — that is Pass 3 planning;
stay at terrain altitude.

**Gate:** `CHECK_ADR=OK` — terrain named, every grounding decision recorded as
an ADR, each cites evidence, none says "build X".

## Pass 3 · `reqs-to-swimlane-plans`

**Purpose:** Split the system into one sketch plan per swimlane along its natural
seams — plan altitude only, no tasks and no implementation code.

**When:** User says "decompose", "decompose this", "swimlane plans", "split it
into plans", "find the seams", or "split the lane into legs".

**Not:** For atomic tasks or implementation code — that is Pass 5 (`task-spec`).

**Gate:** `CHECK_PLAN=OK` — one plan per genuine seam, each listing legs,
dependencies, build order, inherits ADR decisions; plan altitude held.

## Pass 4 · `sketch-plans-adversarial-review`

**Purpose:** Run the Pass 3 swimlane plans through a different-family model as
adversary, sharpen them in place, and end at THE BARRIER — the owner's sign-off,
the last human decision before the machine builds.

**When:** User says "adversarial review", "consensus pass", "attack the plans",
"have Codex refute this", "sign off the plans", or "find what bites us at build
time".

**Not:** To write new plans (that is Pass 3) or to cut tasks (that is Pass 5) —
this pass only hardens existing plans and takes the sign-off.

**Gate:** `CHECK_CONSENSUS=OK` — a different-family engine attacked, every
objection is FIX or ACCEPT-with-owner, the owner has signed off.

## Pass 5 · standalone `taskspec`

**Purpose:** Turn accepted legs into atomic, vendor-neutral Task-Spec units whose
runnable evals travel with the work. HMAC seal prevents silent goalpost edits.

**When:** Use the Task-Spec CLI directly (`taskspec plan`, `taskspec gate --stamp`,
`taskspec accept`).

**Not:** Converge does not install a mirrored Task-Spec skill; it consumes the
external CLI and its published contracts.

**Gate:** `TIER=1` — the task is a signed runnable leaf.

See: [Task-Spec repository](https://github.com/luanmorenommaciel/task-spec)

## Pass 6 · `task-specs-to-issues` (opt-in)

**Purpose:** Project signed Task-Specs onto tracker issues — one issue per spec,
with `blocked-by` links carrying the dependency graph — so the execution loop
reads a board instead of repo files.

**When:** User says "register the tasks", "push tasks to Linear", "push tasks to
GitHub issues", "task-specs to issues", or "bridge the backlog onto a tracker".

**Not:** Skip it to keep the queue repo-local in `tasks/`. Not for authoring
tasks (Pass 5) or running them (Pass 8).

**Gate:** `CHECK_REGISTER` — 1:1 mapping holds, every dependency edge is one
`blocked-by` link, no orphans, no cycles.

## Pass 7 · `task-to-runtime-contract`

**Purpose:** Bind one signed Task-Spec to an enforceable, task-scoped runtime
contract, and emit the task brief the worker reads.

**When:** Pass 7 · Bind (7A contract + 7B brief), after Pass 6 Register (opt-in)
and before `task-loop` executes the issue.

**Not:** To author Task-Specs, select work across tasks, or execute the task.

**Gate:** `CHECK_RUNTIME_CONTRACT=PASS` — sign-off, freshness, evidence, topology
substance, ownership, capability closure, and honest assurance all verify.

## Pass 8 · `task-loop`

**Purpose:** Take ONE issue, verify its Pass 7 execution profile, read its signed
Task-Spec and hash-bound evidence, cut a branch, write code, and run the task's
own eval in a bounded refinement loop until GREEN, then open a PR.

**When:** A user or CI says "run issue N", "execute this task", "build task T-...",
"work the loop", or "drive this issue to a green-eval PR".

**Not:** To choose or fan out across tasks — that is the Manager, a future CI/CD
concern outside the pass chain.

**Gate:** `TASK_LOOP=SETTLED` or `TASK_LOOP=LOCAL_SETTLED` — the task's own eval
is GREEN, path policy holds, one named terminal state.

## Utility · `evidence-to-next-pass`

**Purpose:** Derive where the descent stands from workspace evidence, enforce
order with pre/post hooks, and hand the agent the right pass prompt. Optional
guided mode turns each boundary into stable user choices without storing chat
state.

**When:** Someone asks "what's next", "where are we in the descent", "continue
the run", "start pass N", "guide me through Converge", "step by step", or
before steering ANY pass in a chat session.

**Not:** To waive or replace a `cvg` gate (evidence presence is not a verdict)
or to pick the lane (`cvg lane` owns that).

**Gate:** `NEXT_PASS=<N>` or `DONE`; guided presentation also emits
`GUIDED_CHAT=AWAITING_CHOICE|DONE` while leaving `NEXT_PASS` last.

## Utility · `pass-to-lesson` (optional)

**Purpose:** After any pass's gate goes green, read everything the pass produced
and teach it back — every component, the decision it encodes, what breaks
downstream without it.

**When:** Someone says "teach me what was built", "explain this pass", "walk me
through the tech-spec/ADRs/plans", "debrief the pass", or "what did you just do
and why".

**Not:** To run a pass (each pass has its own skill) or to review/attack artifacts
(that is Pass 4).

**Gate:** `CHECK_LESSON=PASS` — every emitted artifact appears in the walkthrough,
every decision names a rejected alternative, every term defined, 3–5 check-yourself
questions, artifacts untouched.

## Utility · `skill-creator`

**Purpose:** Author, evaluate, package, and structurally validate agent skills.

**When:** Users want to create a skill from scratch, edit or optimize an existing
skill, run evals to test a skill, or benchmark skill performance.

**Gate:** Validated skill package.
