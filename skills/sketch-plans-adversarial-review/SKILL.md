---
name: sketch-plans-adversarial-review
description: Runs the Pass 3 swimlane plans through a different-family model as adversary, sharpens them in place, and ends at THE BARRIER — the owner's sign-off, the last human decision before the machine builds. Implements Converge Pass 4 (Consensus), the boundary between Phase 1 (human-led design, passes 0-4) and Phase 2 (machine-led build, passes 5-8). Use when the user says "adversarial review", "consensus pass", "attack the plans", "have Codex refute this", "sign off the plans", or "find what bites us at build time". Engine-agnostic via flags — the adversary is --adversary codex|kimi|gemini (default codex), never baked into the name; no tracker. Do NOT use to write new plans (that is Pass 3 reqs-to-swimlane-plans) or to cut tasks (that is Pass 5 task-spec) — this pass only hardens existing plans and takes the sign-off.
metadata:
  version: "0.2.1"
  compatibility: "Converge chain Pass 4 · Consensus — THE BARRIER. Runs after Pass 3 (reqs-to-swimlane-plans), before Pass 5 (task-spec). Engine/tracker-agnostic."
---

# sketch-plans-adversarial-review — Pass 4 · Consensus · **THE BARRIER**

Converge Pass 4 (Consensus): a *different-family* model attacks each swimlane plan default-to-refuted, every objection is FIXED or ACCEPTED-with-owner, and then the owner **signs off**.

**This pass is the barrier.** Everything above it (passes 0–4) is human-led design — making intent crystal-clear. Everything below it (passes 5–8) is machine-led build — the sealed spec is the only instruction, the eval is the only judge of done. There is no route decision here and no branch in the method: consensus always descends to Pass 5 (`task-spec`), whose six-tier sizing engine (XS→XXL) absorbs the whole range from a one-liner to a whole backbone.

> **Why the barrier sits here and not earlier.** This is the first moment the plan has survived a *different model* trying to break it. Signing off before that is signing off on an unexamined plan — and the machine would then faithfully build the flaw. The adversary is what makes the sign-off worth something.

## Important

- **The adversary must be a different model than the author.** The plans were written by Claude; a different engine (`--adversary`, default `codex`) attacks them. The same model reviewing its own plans produces agreement, not consensus — that defeats the entire pass. This is why Pass 4 binds a *different* model than every other pass in the chain.
- **Default to refuted.** A merely-plausible plan step is not "fine" — the adversary must state why it *might* be wrong or the objection stands. Silence is not passing.
- **Altitude lowers, it does not invert.** Pass 4 hardens what Pass 3 sketched. It creates NO new files and adds NO scope. New requirements are drift — push them back up the chain, never smuggle them in here. The diff on `swimlanes/*.plan` IS the record of what consensus changed.
- **Nothing is silently dropped.** Every logged objection ends in exactly one of FIX (revised in a plan) or ACCEPT (recorded risk + named owner + reason to proceed).
- **The sign-off is the output.** The pass is not finished when the objections are resolved — it is finished when the **owner signs off**. That signature is the hand-off from human design to machine build, and it is the one thing no script can do for you (see Step 4).
- **There is no fork, and no route to choose.** Consensus always descends to Pass 5 (`task-spec`). The old plan-driven path (Fork A / SDD) was retired in v3.4 and the branch was removed from the method entirely — task-spec's six-tier engine absorbs the whole range (a tightly-coupled slice is an `L` leaf, not a separate paradigm). The objection-log **schema still carries a `fork` field**, which is now a frozen compatibility token (`choice: B`), not a decision — see Step 4.

## Inputs / Outputs / Gate

| | Artifact |
|------|----------|
| **IN** | The swimlane tree (`swimlanes/<seam>/` — a lean PRD + one file per leg, from Pass 3 v0.7.0) + the tech-spec + the ADRs (`docs/adrs/*.md`) as ground truth, handed to a **different-family** adversary via the framed [`attack-playbook.md`](references/attack-playbook.md). |
| **OUT** | The **same plans, sharpened in place** (the diff is the record) + a **stamped objection log** at `swimlanes/.consensus/objection-log.json` ([schema](references/objection-log.schema.json)) — the deterministic gate target — and **the owner's sign-off**. No new plan files. |
| **GATE** | Two halves. **Machine:** a **different-family** model attacked (proven by the artifact's provenance stamp + input hashes, *not* a grep of a word); every objection is FIX or ACCEPT-with-owner; the plans have **not drifted** since the review (the gate re-hashes them). `check-consensus-gate.sh` ends in `CHECK_CONSENSUS=OK\|FAIL\|EMPTY\|USAGE_ERROR` — falsifiable, see Step 5. **Human:** the owner signs off — the barrier, which no script can check. |

## Flags

| Flag | Values | Default | Effect |
|------|--------|---------|--------|
| `--adversary` | `codex` \| `kimi` \| `gemini` | `codex` | Which *different-**family*** model runs the refutation. The invariant is a **different family** than the author (Claude = anthropic): `codex`=openai, `kimi`=moonshot, `gemini`=google. Self-preference bias is measured and family-correlated, so same-family review under-reports its own flaws. `claude -p` (fresh, no memory) is the explicitly-**weaker fallback** only. Dispatched headless by `cvg review --adversary <e>` (see `references/engine-adapter.md`). |

No `--tracker` flag: this pass registers nothing and produces no issues. It sharpens plans in place and ends at the owner's sign-off.

## Instructions

Run the four core steps in order, then the gate. This is Pattern 5 (domain-intelligence): the pass carries the knowledge of *what bites your stack at build time* — the real contracts, constraints, and cross-lane interfaces of the system being built — and applies it as the lens the adversary attacks through. (Example — in a dbt/warehouse project the bites might be the raw/source table contract produced by the ingest step, a single-writer data store, and the published-table interface the serving lane reads; in another stack they will be different seams. Name your own.)

### Step 1 — ATTACK (refute as a skeptic who didn't write it)

Dispatch the swimlane tree to the `--adversary` engine (headless, read-only, via `cvg review --adversary <e>`), framed by [`attack-playbook.md`](references/attack-playbook.md) as a skeptical principal engineer who did NOT write them and whose job is to REFUTE, not bless. The adversary **emits the stamped objection log** (`swimlanes/.consensus/objection-log.json`), never edits the plans.

- **One swimlane at a time, then leg by leg.** Refutation is per-lane and per-leg (Pass 3 is now `swimlanes/<seam>/` with one file per leg), ranked by build-time damage so the cheapest-to-kill wrong idea dies first — before any model/mart/endpoint exists.
- **Default to refuted.** Merely plausible is not enough; the adversary must say why a step might be wrong.
- Hunt the build-time bites, using your stack's real seams:
  - **Unverified assumptions about existing state** — where a plan assumes something unproven about the shape of a source/input contract, required audit/lineage columns, or a data-store constraint (e.g. single-writer, transaction limits).
  - **Build order** — a downstream artifact before the upstream it depends on: an output layer before the intermediate it derives from, an endpoint before the table it reads, a transform before its source is available.
  - **Cross-lane interface** — a consumer in one lane needs a field or contract that the producing lane never emits. (For example, in a warehouse-plus-serving project: a serving endpoint reads a column the transform lane never publishes.)
- Demand the **5–7 highest-leverage objections**, ranked by build-time damage, each citing a specific plan section.

### Step 2 — GROUND (check drift vs. tech-spec + ADRs)

The plans answer to the spec and the ADRs, not to the author model's memory of them. For each plan, find where it CONTRADICTS or DRIFTS:

- Claims a requirement it does not actually cover.
- Contradicts the spec's scope (builds something marked out-of-scope, or a metric never asked for).
- Violates a recorded ADR decision (e.g. an ADR pinning a data-store constraint, or the chosen layering/architecture).
- Disagrees on a number (freshness target, latency budget, success metric).

List each drift as `plan section ↔ spec/ADR section ↔ the conflict`, citing **both** sides. No hand-waving — this catches silent drift where a plan *sounds* right but quietly contradicts the agreed source of truth. If `docs/adrs/` is empty, ground against the tech-spec alone and log "ADRs absent" as an open question — do not invent ADR content.

### Step 3 — SHARPEN (fix or own every objection)

Back with the author model (Claude), take every objection from Steps 1–2 and do exactly one of:

- **FIX** — revise the relevant plan **in place** to resolve it.
- **ACCEPT** — record it as a known risk with a **named owner** and the reason to proceed.

**When argument can't settle an objection, settle it with a throwaway prototype.**
Some objections are empirical — "that join explodes at this volume", "that state
model can't express refunds" — and arguing them in prose just trades opinions.
Build the smallest disposable artifact that answers the question (a query
against real data, a 30-line state machine, a mocked contract), run it, and let
the result decide FIX or ACCEPT. The prototype is *evidence, not deliverable*:
throw it away afterwards. If it produced a snippet that encodes the decision
more precisely than prose can (a schema shape, a state machine, a contract),
inline just the decision-rich part into the plan and note it came from a
prototype — never the working demo itself, and never as implementation code
(the altitude rule still holds; the snippet records a *decision*).

Every cross-lane interface (the contract each lane hands to the next) must survive scrutiny or be corrected. Finish with a short **open-questions list**: each remaining item, its owner, and whether it blocks the build. Nothing may be silently dropped.

### Step 4 — THE BARRIER (the owner signs off)

This is the pass's defining act and the last human decision in the chain. Present
the owner with: the sharpened plans, every objection and its FIX/ACCEPT
disposition, the accepted risks with their named owners, and the open questions
that do *not* block the build. Then take the sign-off — explicitly, on the
record.

**What the owner is signing.** Not "the code will be correct" — that is the
eval's job. They are signing *this plan is the right thing to build, and I am
handing it to the machine.* After this point the sealed Task-Spec becomes the
only trusted instruction source and the eval becomes the only judge of done; no
one is required to read the diff.

> **Only a human can cross this line.** The gate script checks the
> machine-checkable half (a different-family adversary attacked, no objection is
> unresolved, no drift). It **cannot** check the sign-off — an agent must stop
> here and ask the owner. Do not proceed to Pass 5 on an unsigned plan.

**The `fork` compatibility token.** The gate still requires the retired fork
field in **two** places, and rejects `A` in both:

1. `objection-log.json` → a `fork` object with `choice: "B"` and a non-empty `reason`.
2. The top 15 lines of **every** `swimlanes/<seam>/swimlane-*.plan.md` → a line
   matching `FORK: B (task-driven)`.

This is a **frozen compatibility field, not a decision** — write it and move on.
Agents must never present it to the owner as a route to pick; the method has one
path. See `references/the-fork.md` for why the branch existed and why it was
removed.

### Step 5 — GATE (falsifiable; confirm before leaving this pass)

Run the bundled gate to make the exit condition machine-checkable:

```bash
bash .claude/skills/sketch-plans-adversarial-review/scripts/check-consensus-gate.sh --dir swimlanes/
# validates swimlanes/.consensus/objection-log.json (structure + provenance hashes);
# ends in CHECK_CONSENSUS=OK|FAIL|EMPTY|USAGE_ERROR. cvg review --check wraps this.
```

It fails (`CHECK_CONSENSUS=FAIL`, exit 1) unless all hold — checked against the
**stamped objection log**, not plan prose (so "a different model attacked" is
un-spoofable):

- [ ] A **different-family** engine (`--adversary`, default codex=openai) attacked — proven by the objection log's provenance stamp (engine/model/family + input `sha256`s that match the live plans), not a grep of a word.
- [ ] Plans were grilled against the tech-spec AND the ADRs for drift, each conflict citing both sides.
- [ ] Every logged objection is FIXED in a plan or ACCEPTED with a named owner — grep finds one resolution per objection.
- [ ] Every cross-lane interface (the contract each lane hands to the next) survived scrutiny or was corrected.
- [ ] The `fork` compatibility token is `B` + reason in the log **and** on a `FORK:` line atop every swimlane PRD (a frozen schema field, not a decision — see Step 4).
- [ ] An open-questions list exists; blockers are flagged.

**Then the half no script can check:**

- [ ] **The owner has signed off** — the barrier is crossed, and the work now belongs to the machine.

When the gate is green **and the owner has signed**, hand off to Pass 5 (`task-spec`). *Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches what this pass just sharpened — the surviving objections and the accepted risks — before the descent continues.

## Examples

**Example 1 — "attack the plans"**
User says *"have Codex refute the swimlane plans."* → Run Step 1 with `--adversary codex` against each `swimlanes/*.plan`, one at a time, default-to-refuted. The adversary returns 6 ranked objections, top one being a cross-lane interface gap — *a consumer lane reads a field the producing lane never emits* (for example, in a warehouse-plus-serving project: a serving endpoint reads a published column the transform lane never emits). → Result: objection logged with a plan-section citation, ready for Step 3.

**Example 2 — "consensus pass" end-to-end**
User says *"run the consensus pass."* → Steps 1–2 surface 7 objections + 2 drifts (e.g. a freshness or latency number that contradicts the tech-spec). Step 3 FIXes 6 in place, ACCEPTs 1 to a named owner (a data-store constraint under concurrent load), reconciles the drifting number to the spec. Step 4: present the sharpened plans, the one accepted risk and its owner, and the two non-blocking open questions — **the owner signs off**. Step 5 gate is green. → Hand off to Pass 5 (`task-spec`).

**Example 3 — a tightly-coupled slice that "only verifies as a whole"**
This used to trigger the retired plan-driven path. Now it changes nothing about the route: make the coupled slice a single **`L` leaf** (one coherent done-condition, `execution_backend: glm`) inside the task tree, and descend to Pass 5 like everything else.

**Example 4 — the owner is not available**
The gate is green but no one has signed. → **Stop.** Report that the machine half of the gate passed and the barrier is still closed. Do not cut task-specs; an unsigned plan is an unexamined mandate, and Pass 5 seals whatever it is given.

## Troubleshooting

- **Gate fails: "no fork declared" / "fork not declared at the top of PRD(s)".** → Cause: the retired compatibility token is missing from the objection log or from a swimlane PRD header. → Solution: set `fork.choice: "B"` + a one-line reason in `objection-log.json`, **and** put a `FORK: B (task-driven)` line in the first 15 lines of every `swimlane-*.plan.md`, then re-run. This is a frozen field, not a route decision — the gate rejects `A` because the plan-driven path is retired.
- **Gate fails: "objection without resolution."** → Cause: an objection was logged but never marked FIX or ACCEPT. → Solution: for each, either revise the plan in place (FIX) or add `ACCEPT — owner: <name> — reason: ...` (ACCEPT). No silent drops.
- **Adversary blesses everything.** → Cause: not framed default-to-refuted, or the same model is reviewing itself. → Solution: re-frame as a skeptical principal engineer who did NOT write the plans; confirm `--adversary` differs from the author model. If the adversary is down, use a fresh same-model session with no memory of authoring.
- **A new requirement appears during review.** → Cause: scope creep — that is drift, not sharpening. → Solution: log it as an open question and push it back up the chain (Pass 1/2/3). Do not add scope in Pass 4.
- **`docs/adrs/` is empty.** → Cause: Pass 2 ADRs not committed. → Solution: ground against the tech-spec alone and log "ADRs absent" as a blocking open question; do not fabricate ADR content.
- **No plans exist.** → Cause: Pass 3 hasn't run. → Solution: run `reqs-to-swimlane-plans` first; there is nothing to attack yet.

## References

- `references/attack-playbook.md` — the adversary's system prompt (default-to-refuted), the cross-family + per-leg dispatch contract, and the stack's build-time bite list.
- `references/engine-adapter.md` — how `cvg review` dispatches a headless engine (the read-only + schema-JSON + timeout + provenance contract, the invocation cheatsheet, `cvg doctor`).
- `references/objection-log.schema.json` — the stamped review-record schema the gate validates.
- `references/the-fork.md` — historical: why the branch existed, why task-driven won, and why the fork was removed from the method (v3.4). Read it to understand the `fork` compatibility token, not to choose a route.
- `scripts/check-consensus-gate.sh` — the falsifiable gate on the objection log (see Step 5); `tests/run-tests.sh` proves it discriminates.
