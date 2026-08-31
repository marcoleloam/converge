---
name: brd-docs-to-tech-req
description: Transforms a client BRD (cvg/docs/brd/|.pdf) into a verifiable tech-spec (cvg/docs/tech-spec/) — the engineering solution shape for the client's problem. Implements Converge Pass 1 (Intent), the top of the chain. Use when a brief has landed and someone says "turn this brief into a tech-spec", "start Converge pass 1", or "what are we actually building here". Runs the Understand / Prior-art / Interrogate (frontier rounds with recommended defaults, gap register) / Crystallize steps and gates on restating the problem in one paragraph AND the spec answers it, every requirement falsifiable and prioritized, success metrics traced to the BRD's KPIs, no unresolved blocker gaps. Stays above the stack — no schema, no engine choice. Do NOT use for architecture or stack decisions (that is Pass 3), when a signed-off tech-spec already exists (go to Pass 2, tech-req-to-adrs), or when no BRD exists at all (run Pass 0, idea-to-brd, to capture the brief first). Engine/format bound via flags, never baked into the name.
metadata:
  version: "0.2.1"
---

# brd-docs-to-tech-req — Converge Pass 1 (Intent)

> **Identity:** The intent compiler — restates the client's problem and crystallizes a verifiable solution shape.
> **Domain:** Requirement comprehension, scope definition, KPI-tied success metrics — above the stack.
> **Converge Pass:** 1 of 8 — Intent. First pass; descends from *the client's problem* to *our verifiable spec*.
> **Engine/flags:** authoring engine is a flag (default: Claude CoWork project, conversational, no repo). No tracker — Pass 1 produces a consensus doc, not issues.

Pass 1 is the highest-altitude pass in Converge. It turns a client's Business Requirements Document — prose pains, unquantified goals, fuzzy scope — into a **tech-spec**: a document where every requirement is falsifiable and every success metric traces to one of the client's own KPIs. It answers exactly one question: **what are we building, and how will we know it works** — never *how* it is built. The stack (data store, transform tooling, serving layer — whatever the project uses) is decided in Pass 3, not here.

## Important

- **The gate is falsifiability, not completeness.** A requirement belongs in the spec only if a future eval could pass or fail it. A requirement that cannot be made falsifiable goes to the open-assumptions list with a named owner — it does not get softened into the spec.
- **Brief-in, spec-out — never blur them.** The BRD is the client's, in the client's words. The tech-spec is ours. The entire job of Pass 1 is the translation between them. Do not paraphrase the BRD and call it a spec.
- **No premature technology.** No schema file, no data store, no transform tooling, no serving layer, no framework names. Describe WHAT the engine must do and HOW WELL. Naming a technology here is the most common Pass 1 failure.
- **Converged = the gate passed**, not "feels done." Even at this altitude the discipline holds: "verifiable" means a future eval could decide it.

## Instructions

### Step 1 — Understand (read like the engineer who must deliver it)

Read the BRD (`cvg/docs/brd/|.pdf`, e.g. `cvg/docs/brd-analytical-backbone.md` — the `cvg/` workspace comes first; bare `docs/` is the legacy fallback) as the senior engineer accountable for delivery, not as a summarizer.

- Find the **real pain**: who feels it, when, and what it costs — financial, operational, strategic — in the client's own numbers.
- Separate **symptoms from the underlying problem**. A brief that asks for "a dashboard" usually has a decision the client can't make underneath it.
- Name the **data the engine will act on** at the problem level — the shape of the source, not its schema (for example, in an analytics engagement: order, payment, customer, and product records arriving as raw source tables — described as business entities, not as a physical schema).
- Close by writing, in **one paragraph**, what "solved" looks like from the client's seat. This paragraph is half the gate — write it before you write anything else.

### Step 1.5 — Prior art (problem level only)

Before interrogating, survey what already exists **at the problem level** —
prior tech-specs under `cvg/docs/`, past learnings, earlier engagement documents.
Do **not** open the codebase, schemas, or configs — that is Pass 2's altitude.
For each hit, note: reuse, extend, or supersede (with one line of why). If
nothing exists, say so explicitly — that statement is the evidence you looked.
Prior art feeds the recommendations you offer in Step 2.

### Step 2 — Interrogate (frontier rounds, gaps as records)

Surface the questions that would most change what gets built. Draw them from:
**scope** (in / out / genuinely unclear boundary), **definition of done** (what
the client points at to say "yes, this works"), **soft numbers** (every KPI,
threshold, or "fast/reliable/accurate" not yet measurable), and **failure
expectations** (what should happen when input data is missing, late, or wrong
— a WHAT/HOW-WELL question, still above the stack).

**Facts vs decisions — the question budget rule.** If a *fact* can be found by
exploring the environment (the repo, `cvg/docs/`, prior engagements, the BRD
itself), look it up rather than asking — Step 1.5 exists so no question is
spent on what a file can answer. The *decisions*, though, are the client's:
put each one to them and wait. Never silently decide for them, and never ask
them to recall what you could read.

Run the interrogation as a protocol, not a checklist dump:

1. **Announce the map first** — "here is what I want to pin down" — so the
   client can see progress and steer. Treat the questions as a design tree:
   a question whose answer depends on another still-open question belongs to
   a *later round*.
2. **Ask the whole frontier as one numbered round** (default,
   `--questions batch`) — every question whose prerequisites are settled,
   each with **your best default answer** (grounded in the BRD and Step
   1.5's prior art): *"My recommendation: X — because Y. Confirm or
   redirect."* Then wait; the client answers the round in a single reply
   (voice/dictation-friendly). Pass 1's interrogation is typically 2–3
   questions, so this often collapses to one round. With `--questions one`,
   walk the same tree one question per turn.
3. If an answer is **vague, incomplete, or contradictory**, push back exactly
   once with a concrete follow-up in the next round ("give me a number — how
   many is 'a lot'?").
4. If an answer is **concrete**, lock it in by restating: *"Locked: <decision>."*
   Settled answers unblock the next round's questions; recompute the frontier
   until it is empty. **Decisions live on disk, never in the air** — the
   moment a decision locks, write it into the spec's decision record (the
   `Locked:` log the Confirmed decisions recap replays). A decision held
   only in conversation does not exist at the gate.
5. If the client **cannot resolve it** (or a question survives two rounds
   unanswered), it becomes a gap record — never a silently-assumed answer.

Record every unresolved item in the spec's **gap register** (inside the Open
assumptions section) as a typed record:

```yaml
- id: GAP-001
  type: scope | definition | number | data
  severity: blocker | minor        # blocker = the spec cannot be signed without it
  question: "..."
  blocks: "which requirement(s) this holds hostage"
  owner: "named client stakeholder"
  resolution: (open)               # replaced with the answer when resolved
```

A **blocker** gap fails the Pass 1 gate unless its `resolution:` is
affirmatively substantive — the verifier fails CLOSED: a missing, blank, or
sentinel resolution (`(open)`, `none`, `null`, `tbd`, `pending`,
`awaiting…` — quoted or not) counts as unresolved, and so does anything the
script cannot read as resolved. The spec cannot descend to Pass 2 carrying
a fatal unknown. Minor gaps may ride along with their owner named. Do not
stall waiting for perfect answers, and do not silently invent them — the
register is the honest middle.

**When the owner is not in the room, export the gaps as a questionnaire.**
A gap register full of `(open)` records addressed to an absent stakeholder
goes nowhere by itself. Render the open records as a fillable questionnaire —
one question per record, your recommended default pre-filled, a blank for
their answer — and send it to each named owner. Their returned answers land
in `resolution:` verbatim; the register converges instead of aging.

### Step 3 — Crystallize (write the signable tech-spec)

**Before writing anything: replay the Confirmed decisions recap.** List every
`Locked:` decision from Step 2 back to the client and give them one last
chance to correct a misread. Only then write — every requirement must trace
to a locked decision or a BRD line, never to an assumed answer.

Write the deliverable back to the client at `cvg/docs/tech-spec-*` (e.g. `cvg/docs/tech-spec-analytical-engine.pdf`). Structure it:

1. **TL;DR** — one line at the top (≤ 25 words: what gets built and why); the
   outcome statement below it holds to **at most 3 sentences** — detail
   belongs in requirements, not in a wall-of-text outcome.
2. **Problem restated** — one paragraph, plain language, from the client's seat (Step 1's paragraph, sharpened).
3. **Scope** — in / out, explicit, at the problem level.
4. **Requirements** — each with a **stable id**: `R-n` for requirements,
   `W-n` for wishes/wonts. Ids are how evals, ADRs, and gap records cite a
   requirement — never renumber once written down. Each one **verifiable**,
   tied to a client KPI, and
   **prioritized**: `must` only for what the stated outcome fails without;
   nice-to-haves are `should`/`could`; deliberate exclusions recorded as
   `wont` or scope-out. Phrase every requirement so an eval could pass or fail it (see the falsifiability rewrite in [references/falsifiable-requirements.md](references/falsifiable-requirements.md)).
5. **Success metrics** — as **current → target**, each traced to a KPI in the BRD.
6. **Data named** — the source records the engine consumes, at the problem level.
7. **Open assumptions & gap register** — the typed records from Step 2, each with a named owner; blockers resolved or the gate stays shut.

Emit per `--out-format`: `pdf` while the spec is a consensus object the client reads and signs; `md` once locked, so Pass 2 can read it. Stay above the stack throughout.

**Self-review before the gate.** Re-read the drafted spec with fresh eyes and
fix inline — no re-review loop, just fix and move on:

1. **Placeholder scan** — any TBD, TODO, or section written as filler? Fix it or move it to the gap register.
2. **Internal consistency** — do requirements contradict each other or the scope? Does every metric's target match the restated problem?
3. **Ambiguity** — could any requirement be read two different ways? Pick one reading and make it explicit.
4. **Altitude** — did a schema, engine, or framework name leak in? Strip it; the stack is Pass 3's.

### Step 4 — Gate (confirm before leaving this pass)

Do not descend to Pass 2 until every box is checked. The verifier has an
exit contract (v0.5.0): **draft validation and Pass 2 handoff authorization
are different verdicts.**

```bash
# while writing — structural validation only, NEVER authorizes descent:
bash .claude/skills/brd-docs-to-tech-req/scripts/check-tech-spec.sh --draft cvg/docs/tech-spec/<slug>.md

# the handoff gate (default) — passes ONLY a canonical spec: owner verdict
# 'canonical' on the Sign-off verdict line (fence-stripped; pending/draft
# there never authorizes) + a calendar-valid ISO date ON the verdict line
# or the line immediately following it:
bash .claude/skills/brd-docs-to-tech-req/scripts/check-tech-spec.sh cvg/docs/tech-spec/<slug>.md
```

Warnings are advisory, never fatal: stack-leak hits named by domain bucket
(from [references/leak-terms.txt](references/leak-terms.txt) — data,
web/frontend, infra/devops, ml/agents), requirement bullets without a
stable `R-n`/`W-n` id, and any `R-n`/`W-n` whose own line(s) carry no
number, unit, or comparator.

For harnesses and agents, the last output line is always a stable token —
including usage errors (exit 2):
`CHECK_TECH_SPEC=PASS|FAIL|DRAFT_OK|DRAFT_INCOMPLETE|USAGE_ERROR`.
The regression suite lives at `tests/run-tests.sh` (table-driven; every
negative fixture must fail for its intended reason).

- [ ] You can **restate the client's problem in one paragraph** from the client's seat.
- [ ] The tech-spec **answers the brief** — every client pain maps to at least one requirement.
- [ ] Scope (in / out) is explicit at the **problem level** — what the engine does and how well, not which stack does it.
- [ ] **Every requirement is verifiable** — a future eval could pass or fail it.
- [ ] **Every requirement traces to a locked decision or a BRD line** (the Confirmed decisions recap ran before writing).
- [ ] **Priorities are differentiated** — not everything is `must`; deliberate exclusions are `wont` or scope-out.
- [ ] Success metrics trace to the BRD's KPIs (**current → target**).
- [ ] The **data the engine acts on is named** (the source records/entities at the problem level, not a physical schema).
- [ ] **Open assumptions & gaps are recorded as typed records**, each with a named owner — and **every blocker gap carries an affirmatively substantive resolution** (the gate fails closed on missing, blank, or sentinel resolutions).
- [ ] **No premature technology** — no schema, no engine, no framework. The stack is Pass 3's.

## Inputs / Outputs / Gate

| | Artifact |
|------|----------|
| **IN** | The customer BRD + attachments/threads — `cvg/docs/brd/|.pdf` (e.g. `cvg/docs/brd-analytical-backbone.md`; the `cvg/` workspace first, bare `docs/` as the legacy fallback). The *what* and *why*, in the client's words. |
| **OUT** | A tech-spec — `cvg/docs/tech-spec/` or `.pdf` (e.g. `cvg/docs/tech-spec-analytical-engine.pdf`). The *how-well*, at a level the client signs off on. |
| **GATE** | Restate the problem in one paragraph AND the spec answers it: scope explicit, data named, every requirement falsifiable, success metrics traced to KPIs (current → target), assumptions owned. |

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--engine NAME` | `cowork` | Authoring engine. `cowork` = Claude CoWork project (conversational, no repo, no code) — the canonical Pass 1 engine. Swappable; the gate is engine-invariant. |
| `--out-format md\|pdf` | `pdf` | Deliverable format. `pdf` while the spec is a consensus object the client approves; `md` once locked so the build can read it. |
| `--questions batch\|one` | `batch` | Interrogation mode. `batch` (canonical) = frontier rounds: each round asks every question whose prerequisites are settled, numbered, with recommended defaults — one reply answers the round. `one` = strict one-question-at-a-time. |

**Flags are agent-side guidance, not mechanics.** They steer how the agent
runs the pass; nothing enforces them. The mechanical surface is
`scripts/check-tech-spec.sh` — it takes `[--draft] <spec.md>` only and
knows nothing about `--engine`, `--out-format`, or `--questions`. Do not
expect flag enforcement from the gate.

No tracker flag — Pass 1 emits a single consensus document, not a registered work set. Tracker binding starts at Pass 5 / register.

## Examples

**Example 1 — the canonical trigger.**
User: *"Turn this brief into a tech-spec — start Converge pass 1."* (`cvg/docs/brd-analytical-backbone.md` is present.)
Actions: Read the BRD (Step 1) → write the one-paragraph problem restatement → surface 2–3 scope/done/soft-number questions with default answers and owners (Step 2) → crystallize `cvg/docs/tech-spec-analytical-engine.pdf` with verifiable requirements and current→target metrics (Step 3) → run the gate checklist (Step 4).
Result: A signable tech-spec where every requirement is falsifiable and no technology is named. Hand off to `tech-req-to-adrs`.

**Example 2 — "what are we actually building here?"**
User points at a brief and asks what it really means. Actions: run Understand + Interrogate only; return the one-paragraph restatement plus the 2–3 highest-leverage questions. Result: shared clarity before any spec is committed — the buildable version of the brief.

**Example 3 — premature-stack request (negative).**
User: *"Write the tech-spec — it should use \<some specific database\> and \<some transform tool\> with a star schema."* Actions: accept the intent, but keep the stack out of the spec; record it as an open assumption for Pass 3. Result: the spec says the engine must "model orders and payments into query-ready facts within N seconds," not "use \<transform tool\>." Technology is deferred, not adopted.

## Troubleshooting

| Error / symptom | Cause | Solution |
|---|---|---|
| A requirement can't be eval'd | It's a wish, not a spec line ("make it fast") | Rewrite as current → target with a measurable threshold, or move it to open-assumptions with an owner. See [references/falsifiable-requirements.md](references/falsifiable-requirements.md). |
| The spec names a specific database / transform tool / physical schema | Descended into Pass 3 altitude | Strip the technology; restate as a WHAT/HOW-WELL requirement. The stack is decided in Pass 3. |
| Can't restate the problem in one paragraph | Understand step was skipped or the BRD is genuinely ambiguous | Re-read for the real pain and its cost; if still ambiguous, that's the top Interrogate question — assign it an owner. |
| Success metrics have targets but no baselines | KPI baseline not pulled from the BRD | Every metric is current → target; if current is unknown, record it as an assumption owned by the client. |
| Gate fails on an unresolved blocker gap | A fatal unknown was recorded but never substantively resolved — `resolution:` missing, blank, or a sentinel (`(open)`/`pending`/`tbd`/`awaiting…`, quoted or not) | Chase the named owner for the answer, write it into `resolution:` verbatim, re-run the gate. Downgrading a blocker to minor requires the client's explicit say-so — never yours. |
| No BRD exists | Pass 1 needs a client problem document as input | Do not invent one. For client work, get the brief. For an internal idea with no client, run **Pass 0 (`idea-to-brd`)** — it captures the idea as a BRD this pass consumes unchanged. Pass 1 does not fabricate intent. |
| A signed-off spec already exists | You're re-running a completed pass | Skip to Pass 2 (`tech-req-to-adrs`) unless the brief materially changed. |

## Notes

- **Altitude.** Pass 1 is the highest *required* pass: problem → verifiable spec. It comprehends the *what/why* and produces the *how-well*. Every later pass lowers altitude from here, so ambiguity left here is inherited by all of them.
- **Upstream.** When no client BRD exists (an internal idea, a founder thought), the optional **Pass 0 (`idea-to-brd`)** captures it as a BRD in the owner's voice. This pass consumes that BRD exactly as it would a client's — Pass 0 asks the stakeholder's questions, Pass 1 asks the engineer's; the brief/spec boundary holds either way.
- **Why this order.** No ADR, plan, task, or eval can be trusted if the problem it serves is unstated or unverifiable. Pass 2 checks this spec against the real repo; a soft Pass 1 makes every pass below it soft. Gate first, descend second.

## Handoff

→ **`tech-req-to-adrs`** (Converge Pass 2) consumes this tech-spec (`cvg/docs/tech-spec-*`), reconciles it against the real repo, and records the binding technology decisions as ADRs under `cvg/docs/adrs/`.

*Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches what this pass just produced — every component, the decision it encodes, what breaks downstream without it — before the descent continues.
```
