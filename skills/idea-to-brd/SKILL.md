---
name: idea-to-brd
description: Converge Pass 0 (Capture) — optional, like Register (Pass 6). Turns a raw idea with no client brief — a founder thought, an internal itch, a voice-note transcript — into a BRD (cvg/docs/brd/ or .pdf) written in the owner's voice, so Pass 1 can consume it unchanged — or into a no-go record when the pain doesn't justify a build. Use when someone says "I have an idea", "capture this idea", "write the brief", "grill me about this idea", or "start Converge pass 0". Runs Scope-check / Grill (frontier rounds — every unblocked question at once with defaults, one reply per round; facts looked up, do-nothing cost probed, pre-mortem run) / Draft / Self-review and gates on the pain carrying a provenance-tagged number, at least one KPI in the owner's terms, in/out scope each non-empty, and every open question owned. Produces the brief, NEVER the spec — no requirements, no solution shape, no technology. Do NOT use when a BRD exists (enter at Pass 1) or to write a tech-spec (that IS Pass 1).
metadata:
  version: "0.2.1"
  compatibility: "Converge chain Pass 0 · Capture (optional). Runs before Pass 1 (brd-docs-to-tech-req) when no BRD exists. Engine/tracker-agnostic; bash 3.2+ (macOS system bash safe)."
---

# idea-to-brd — Converge Pass 0 (Capture)

> **Identity:** The capture pass — makes a raw idea articulate as a brief, in the owner's voice.
> **Domain:** Idea capture, stakeholder interrogation, problem articulation — one rung above Pass 1.
> **Converge Pass:** 0 of 8 — Capture. **Optional**, like Register (Pass 6): client work with a real brief enters at Pass 1 directly; take this pass only when no BRD exists.
> **Engine/flags:** conversational capture (default: the current session). Output format via `--out-format`. No tracker.

Pass 0 is the on-ramp for non-client work. Pass 1's contract assumes a brief has landed (`cvg/docs/brd-*.pdf|md`) — but internal projects, founder ideas, and "I have this thing in my head" moments have no client BRD. Without this pass, the temptation is to write the tech-spec directly and skip the brief, which blurs the exact boundary Pass 1 protects (*brief-in, spec-out — never blur them*). Pass 0 produces the missing brief: the pain, the goals, the owner's own numbers — and stops there.

## Important

- **The output is the brief, never the spec.** A BRD states what hurts, who feels it, what it costs, and what success looks like — in the owner's words. The moment it states a requirement, a solution shape, or a technology, it has jumped to Pass 1 altitude (or worse, Pass 3). Pass 0 asks the stakeholder's questions; Pass 1 asks the engineer's.
- **Facts vs decisions.** If a fact can be found by exploring the environment — the repo, prior docs, past engagements — look it up rather than asking. The *decisions* are the owner's: put each one to them and wait. Never burn a question on something a file can answer.
- **Rounds, not turns.** The grill is a design tree worked in **frontier rounds**: each round asks every question whose prerequisites are already settled — numbered, each with a recommended default — then waits for one reply. Answers reshape the tree, the frontier is recomputed, the next round goes out. One reply answers a whole round, which is what makes the grill dictation-friendly: the owner talks through the block instead of ping-ponging twenty turns. (`--questions one` keeps strict one-at-a-time for owners who prefer turns.)
- **"Too small for a BRD" is the anti-pattern.** Every idea goes through this — a one-tool utility, a single report, a config-sized product. Small ideas are where unexamined assumptions cost the most. The BRD can be short (half a page for a truly small idea), but it must exist and pass the gate.
- **Pass 0 is allowed to say "don't build it."** The pass has two honest exits: a gated BRD, or a **no-go record**. If the grill shows the cost of doing nothing is tolerable, the correct output is a short parked note — not a strained BRD. Killing an idea here is the cheapest kill in the whole descent; a gate that can only pass or "not yet" pressures the interview to manufacture numbers, and the no-go exit removes that pressure.
- **Numbers carry provenance.** Every number in the BRD is tagged `(measured)`, `(estimated)`, or `(guessed)`. A guessed number is not a fact — it spawns an open question to verify it, with an owner. A fabricated figure that looks load-bearing is worse than an honest unknown; the tags keep Pass 1 honest about which metrics it can trace and which it must re-interrogate.
- **Converged = the gate passed**, not "feels captured." The gate is falsifiable: a number in the pain, a KPI in the owner's terms, scope boundaries with entries, owners on every open question.

## Inputs / Outputs / Gate

| | Artifact |
|------|----------|
| **IN** | A raw idea with no BRD — a conversation, a voice-note transcript, a whiteboard photo, a half-page of notes. The owner is in the room (or reachable). |
| **OUT** | A BRD at `cvg/docs/brd/<slug>.md` (or `.pdf`) in the owner's voice — the same artifact shape a client engagement would hand Pass 1. Artifacts land in the `cvg/` workspace first, then the bare directory; an explicit path always wins (bare `docs/` is the legacy fallback). **Or**, when the pain doesn't clear the bar: a no-go record at `cvg/docs/no-go/<slug>.md` (the idea, the date, the owner of the call, why it didn't clear, what would reopen it). |
| **GATE** | *(BRD exit)* The pain is stated with a provenance-tagged number (cost, count, or frequency); at least one KPI is named in the owner's terms; scope in/out each has at least one entry; every open question has a named owner; no requirement, solution shape, or technology appears (altitude is advisory — the checker WARNs, the human judges voice). *(No-go exit)* The record states why (the do-nothing answer), what would reopen it, its parking date, and the owner of the call — a parked idea, not a deleted one. |

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--out-format md\|pdf` | `md` | BRD format. `md` is the default (Pass 1 reads it directly); `pdf` when the brief is itself a consensus object others sign. The gate runs on the markdown source (the PDF is a rendering of it) — gate the `.md`, render the `.pdf`. |
| `--questions batch\|one` | `batch` | Interrogation mode. `batch` (canonical) = frontier rounds: each round asks every question whose prerequisites are settled, numbered, each with a recommended default — one reply answers the whole round (voice/dictation-friendly). `one` = strict one-question-at-a-time, for owners who prefer turns. |

No `--engine` beyond the session and no tracker — Pass 0 emits one document.

## Instructions

### Step 1 — Scope-check (is this one idea?)

Before asking anything, assess the idea's shape. If it describes multiple independent systems ("a platform with chat, billing, and analytics"), flag the decomposition **first** — don't burn questions refining details of an idea that is really four ideas. Help the owner pick the first slice; each slice gets its own BRD → Pass 1 cycle.

Then explore what the environment already knows: prior BRDs and tech-specs under `cvg/docs/` (the `cvg/` workspace first, then the bare `docs/` fallback), related repos, earlier notes. Every fact found here is a question you don't ask.

### Step 2 — Grill (the stakeholder's questions, in frontier rounds)

Map the grill as a **design tree**: every branch below breaks into the questions that hang off it, and a question whose answer depends on another still-open question belongs to a *later round*, not this one. Announce the map — "here is what I want to pin down" — then work the tree. The branches, in order of leverage:

1. **The pain** — who feels it, when, and what it costs. Push for a number: hours lost, money leaked, decisions delayed. "A lot" is not a cost. Tag every number's provenance: `(measured)`, `(estimated)`, or `(guessed)` — a guessed number spawns an owned open question to verify it. Never squeeze until a fiction pops out; an honest `(guessed)` beats a confident invention.
2. **The do-nothing test** — *"what happens if we build nothing?"* If the honest answer is "not much," stop here and take the **no-go exit** (see below): the pain isn't real enough yet. This one question is the cheapest kill in the entire descent.
3. **The goal** — what changes if this exists, in the owner's own metric. This becomes the KPI Pass 1 traces success metrics to.
4. **Scope boundary** — what is explicitly in, what is explicitly out, and which boundary is genuinely undecided.
5. **Success, from the owner's seat** — what will they point at in three months to say "this worked"?
6. **Constraints** — business constraints only (budget, deadline, compliance, people). Technology is not a Pass 0 topic; if the owner names a stack, record it as a *preference* under open questions, never as a decision.
7. **The pre-mortem** — *"it's six months from now, this shipped, and it failed — what killed it?"* The other branches all ask about success; this is the one question that reaches the assumptions they structurally can't. Answers land as risks or owned open questions. It is also the closest thing Pass 0 has to an adversary while staying a twenty-minute conversation.

**Round protocol** (default, `--questions batch`):

1. **Open with the whole first frontier** — every question askable now with no settled prerequisite (typically the pain, the do-nothing test, and the goal). Number each and attach your best default grounded in Step 1's findings (*"My recommendation: X — because Y. Confirm or redirect."*). Then wait for one reply.
2. **The owner answers the round in a single message** — by voice or text, in any order, skipping what they can't answer yet.
3. **Recompute the frontier.** Lock concrete answers by restating (*"Locked: 1 — <answer>. 3 — <answer>."*); settled answers unblock the next round's questions (scope and success hang off the goal; the pre-mortem goes last, once there is a shape to kill). Push back exactly once per vague answer — "give me a number" — as a numbered item in the next round. Carry unanswered questions forward; after two carries, convert each to an owned open question instead of nagging.
4. **Facts never enter a round.** A question that a file, prior doc, or lookup can answer is your job, not the owner's — look it up (dispatch a sub-agent if it's slow) and only hold back the questions downstream of a still-running lookup; ask the rest of the frontier now.
5. **The do-nothing test rides in round one.** If its answer is "not much," cancel the remaining rounds and take the no-go exit (Step 2b).
6. The grill is done when **the frontier is empty** — every branch visited, nothing silently assumed.

With `--questions one`, walk the same tree one question per turn. Either mode: what the owner cannot resolve becomes an **open question with a named owner** — never a silently-assumed answer. If the named owner is not in the room, the open-questions section doubles as a questionnaire to send them.

### Step 2b — The no-go exit (when the grill says don't)

If the do-nothing test (branch 2) shows tolerable inaction — no real cost, no
real urgency, success indistinguishable from today — do **not** draft a BRD.
Write `cvg/docs/no-go/<slug>.md` instead: the idea in two lines, the date,
the owner of the call, why it didn't clear the bar (the do-nothing answer,
verbatim), and **what would reopen it** (the condition or number that, if it
changed, makes this worth revisiting). Parked, not deleted — a no-go record
is a searchable memory that prevents re-litigating the same idea from
scratch. Then stop; there is no handoff from a no-go.

### Step 3 — Draft (write the BRD in the owner's voice)

Write `cvg/docs/brd/<slug>.md` from [references/brd-template.md](references/brd-template.md): Executive summary (written LAST — one breath, ≤ 60 words) · Problem · Goals & KPIs · Scope (in/out) · Definition of success · Stakeholders · Risks · Constraints · Open questions · Source · Sign-off (present from the first draft, verdict `_pending_` — only the owner flips it to `canonical`, and Pass 1 must not consume an unsigned brief). Every line traces to a locked answer or a Step 1 finding. Keep the owner's vocabulary — the BRD is *theirs*; Pass 1 does the translation to engineering language, not you.

Three drafting rules from the grill carry into the document:

- **Every number keeps its provenance tag** — `(measured)`, `(estimated)`, or `(guessed)` — and every `(guessed)` number has a matching open question to verify it.
- **When more than one stakeholder is named, name the decider** — the one person who breaks ties when stakeholders disagree. A BRD with two owners and no decider ships its first conflict downstream to Pass 1's gap register.
- **Pre-mortem answers land under Risks** — each one either accepted in writing or converted to an owned open question.

### Step 4 — Self-review, then gate

Re-read the draft with fresh eyes and fix inline (no re-review loop):

1. **Placeholder scan** — any TBD, TODO, or vague filler? Fix or move to open questions.
2. **Internal consistency** — do the goals contradict the scope? Does the success definition match the pain?
3. **Ambiguity** — could any line be read two ways? Pick one, make it explicit.
4. **Altitude** — any requirement, solution shape, or technology that leaked in? Strip it or demote it to a recorded preference.

Then run the gate checker and walk the checklist. The checker has an exit
contract (v0.4.0): **draft validation and handoff authorization are
different verdicts.** Authorization is anchored to the verdict line itself —
the word `canonical` in guidance prose or a fenced example proves nothing
(all checks run with fenced code blocks stripped), section headings match
the template exactly (`## Problematic` is not `## Problem`), the sign-off
date must be a calendar-real ISO date (2026-02-31 is not a date), scope
entries must say something (`- none` is not an entry), every numbered
Problem line carries its provenance tag on that line, and open questions
not in the record shape fail closed.

```bash
# while writing — structural validation only, NEVER authorizes handoff:
bash .claude/skills/idea-to-brd/scripts/check-brd.sh --draft cvg/docs/brd/<slug>.md

# the handoff gate (default) — passes ONLY a canonical brief: owner verdict
# 'canonical' + calendar-real ISO date, real Scope In/Out entries, nonblank
# owners, every numbered Problem line provenance-tagged on its line, every
# (guessed) number linked to an open question:
bash .claude/skills/idea-to-brd/scripts/check-brd.sh cvg/docs/brd/<slug>.md

# the no-go exit has a validator too (marker, calendar-real date, why,
# what-would-reopen, named owner):
bash .claude/skills/idea-to-brd/scripts/check-brd.sh --no-go cvg/docs/no-go/<slug>.md
```

The checker reads `.md` only — a `.pdf` brief is a consensus object; convert
it (or re-emit `--out-format md`) before gating. For harnesses and agents,
the last output line is always a stable token — including usage errors
(exit 2):
`CHECK_BRD=PASS|FAIL|DRAFT_OK|DRAFT_INCOMPLETE|NOGO_OK|NOGO_INVALID|USAGE_ERROR`.
Owner-voice and altitude judgments stay warnings in every mode — the human
judges voice. Hygiene is likewise advisory, never a failure: the checker
WARNs when no do-nothing answer appears in the body, when the executive
summary runs past 60 words, or when Stakeholders names no decider. The
regression suite lives at `tests/run-tests.sh`
(table-driven; every negative fixture must fail for its intended reason).

- [ ] The **pain carries a number** — cost, count, or frequency, in the Problem section — and **every number carries a provenance tag**; every `(guessed)` one has a matching open question to verify it.
- [ ] The **do-nothing test was asked** — and its answer justifies building (otherwise you should be on the no-go exit, not here).
- [ ] **At least one KPI** is named in the owner's terms under Goals.
- [ ] **Scope in and out** each have at least one entry; the undecided boundary (if any) is an open question.
- [ ] **The pre-mortem ran** — its answers sit under Risks, each accepted or converted to an owned open question.
- [ ] **Every open question has a named owner**, and if more than one stakeholder is named, **the decider is named**.
- [ ] The BRD is in the **owner's voice** — no requirement, no solution shape, no technology decision.
- [ ] **Definition of success** is written from the owner's seat.
- [ ] The **Executive summary reads in one breath** (written last; if it can't, revisit the scope-check).
- [ ] The **Sign-off block is present** — verdict stays `_pending_` until the owner writes `canonical`; an unsigned BRD is a draft, not a handoff.

## Examples

**Example 1 — the canonical trigger.**
User: *"I have an idea — grill me and write the brief."* Actions: scope-check (one idea, no prior art under `cvg/docs/`) → grill the branches in frontier rounds — round one asks the pain, the do-nothing test, and the goal in one numbered block with defaults; the owner answers in one voice reply; two more rounds close the tree → draft `cvg/docs/brd-cost-dashboard.md` in the owner's voice → self-review, strip a leaked "use DuckDB" into a recorded preference → `check-brd.sh` green. Result: a BRD Pass 1 consumes exactly as it would a client's.

**Example 2 — the idea is really four ideas.**
User describes a platform with ingestion, chat, billing, and analytics. Actions: stop at Step 1 — flag the decomposition, help pick the first slice (ingestion), capture only that BRD; the other three become one-line stubs in a parking list. Result: one gated BRD, not a four-headed brief no pass can consume.

**Example 3 — a BRD already exists (negative).**
User: *"Capture this idea"* but `cvg/docs/brd-analytical-backbone.pdf` covers it. Actions: point at the existing brief and route to Pass 1 (`brd-docs-to-tech-req`); Pass 0 does not duplicate a landed brief. Result: no second BRD; the chain enters at the right pass.

**Example 4 — the no-go exit.**
User: *"I want an internal tool that auto-formats our meeting notes."* The grill reaches the do-nothing test: *"what happens if we build nothing?"* — honest answer: "nothing, really; formatting takes two minutes and nobody has complained." Actions: stop the grill; write `cvg/docs/no-go-meeting-notes-formatter.md` — the idea, the date, the owner of the call, the do-nothing answer verbatim, and the reopen condition ("revisit if note volume grows past ~20/week or someone downstream actually consumes them"). Result: idea killed for the price of four questions — the cheapest kill in the descent — and parked where it can be found instead of re-pitched from scratch.

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| The BRD reads like a spec (requirements, "the system shall") | Altitude leak into Pass 1 | Rewrite in the owner's voice: pains, goals, success — Pass 1 owns the translation to requirements. |
| Gate fails: no number in the Problem section | The pain was accepted as "a lot" / "too slow" | Re-ask with a forced quantifier: hours per week, dollars per month, incidents per quarter. If the owner truly doesn't know, record it as `(guessed)` with an owned open question to verify — or ask the do-nothing test: a pain nobody can quantify may not clear it. |
| The number feels invented under pressure | The gate's demand for a digit squeezed out a fiction | Tag it `(guessed)` and spawn the verification question — never launder a guess into a `(measured)`-looking fact. If most numbers are guessed, consider whether the do-nothing test was answered honestly. |
| Every idea that enters becomes a BRD | The no-go exit is never taken | Suspicious — run the do-nothing test earlier and harder. A capture pass that never says "don't" is decorating ideas, not evaluating them. |
| The owner keeps naming technologies | Enthusiasm for the how before the what | Record each as a *preference* under open questions ("owner prefers X — revisit at Pass 3"); keep the body technology-free. |
| Questions stall — the owner can't answer | The named owner of that branch isn't in the room | Record it as an open question with the right owner named; the section doubles as a questionnaire to send them. Don't invent the answer. |
| The owner answers only half a round | Normal — a round is an offer, not a form | Lock what came back, carry the rest to the next frontier; after two carries, convert each leftover to an owned open question. |
| A round mixes questions that depend on each other | Frontier computed wrong | A question whose answer depends on another question in the same round belongs to a later round — re-split and re-send only the independent ones. |
| The idea keeps growing mid-grill | Scope-check was skipped or too gentle | Return to Step 1: re-slice, park the growth as new one-line stubs, finish the first slice's BRD. |
| "This is too small to need a BRD" | The anti-pattern | Write the half-page version anyway — the gate still runs. Small ideas hide the costliest assumptions. |

## Notes

- **Why a separate pass, not a Pass 1 mode.** Pass 0 and Pass 1 both interrogate, but they ask different questions: Pass 0 asks the *stakeholder's* (what hurts, what does it cost), Pass 1 asks the *engineer's* (definition of done, soft numbers made measurable, failure expectations). Collapsing them produces a document that is neither a clean brief nor a falsifiable spec — the exact blur Pass 1's first rule forbids.
- **Optional by design.** Like Register (Pass 6), this pass is taken only when its precondition holds (no BRD exists). The spine's numbering and story are unchanged; client engagements never see this pass.
- **Provenance of the rounds protocol.** The frontier-rounds grill adapts Matt Pocock's `batch-grill-me` skill (github.com/mattpocock/skills): the design tree, the per-round frontier, and facts-never-block-the-round are his; Pass 0 adds the fixed branch map, the no-go exit, provenance tags, and the gate.

## Handoff

→ **`brd-docs-to-tech-req`** (Converge Pass 1, Intent) consumes this BRD exactly as it would a client's — reads it like the engineer who must deliver it, interrogates the engineering questions, and crystallizes the falsifiable tech-spec. Nothing downstream knows or cares that the brief was captured rather than handed over.

*Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches what this pass just produced — every component, the decision it encodes, what breaks downstream without it — before the descent continues.

## References

- `references/brd-template.md` — the BRD section skeleton (Executive summary · Problem · Goals & KPIs · Scope · Definition of success · Stakeholders · Risks · Constraints · Open questions · Source · Sign-off) with per-section guidance, plus the no-go record shape.
- `scripts/check-brd.sh` — the falsifiable gate with an exit contract: canonical mode (default, the ONLY path to the Pass 1 handoff verdict), `--draft` (validation while writing, never authorizes), `--no-go` (validates the other honest exit). Machine token on the last line for agents.
- `tests/run-tests.sh` + `tests/fixtures/` — the gate's table-driven regression suite (canonical green in two domains, every negative failing for its intended reason).
