---
name: pass-to-lesson
description: Converge teaching companion — optional after ANY pass. Turns a just-closed pass's artifacts (BRD, tech-spec, ADRs, plans, specs, task-specs, harness, PRs) into a durable lesson at cvg/docs/lessons/lesson-*.md plus a spoken-style walkthrough, so the owner understands what the autonomous chain built — every component, the decision it encodes, what breaks downstream without it, and the roads not taken. Use when someone says "teach me what was built", "explain this pass", "walk me through the tech-spec/ADRs/plans", "debrief the pass", "what did you just do and why", or "start the lesson". Runs Locate / Read / Teach / Quiz and gates on every emitted artifact appearing in the walkthrough, every decision naming a rejected alternative, every term of art defined at first use, and the lesson ending in check-yourself questions. Explains decisions, never reopens them. Do NOT use to run a pass (each pass has its own skill) or to review/attack artifacts (that is Pass 4, sketch-plans-adversarial-review).
metadata:
  version: "0.2.1"
  compatibility: "Converge chain · teaching companion (optional, after any pass gate). Engine/tracker-agnostic; bash 3.2+ (macOS system bash safe)."
---

# pass-to-lesson — Converge teaching companion

> **Identity:** The teaching pass — turns a closed pass's artifacts into the owner's understanding, so delegation never becomes ignorance.
> **Domain:** Explanation, pedagogy, decision archaeology — runs at every altitude, changes nothing.
> **Converge Pass:** none — an optional companion, invocable after **any** pass's gate goes green.
> **Engine/flags:** the current session. Depth via `--depth`, the Feynman loop via `--quiz`. No tracker.
> **CLI:** `cvg lesson [<file>] [--immutable <taught>...]` → `CHECK_LESSON=PASS|FAIL|USAGE_ERROR`. Optional by design: it never blocks the descent.

Converge delegates the *writing* of every artifact to the chain — but it never delegates the *understanding*. Each pass ends with a gate and a handoff, and the owner is left holding a document they approved but may not be able to explain. This companion closes that gap: after a pass's gate passes, it reads everything the pass produced and teaches it back — component by component, decision by decision — and leaves a durable lesson under `cvg/docs/lessons/` so the understanding survives the conversation.

## Important

- **Teaching is part of the delegation contract.** An artifact the owner cannot explain is an artifact nobody owns. The chain wrote it; the owner must be able to defend it. This skill exists so "the autonomous did it" never becomes the answer to "why is it shaped this way?"
- **Teach the why, not the tour.** "This file contains the ADRs" teaches nothing. Every component gets the four-part treatment: what it is, why it is shaped this way, which decision it encodes, and **what breaks downstream without it**. The last part is the test — if you can't say what breaks, you haven't understood the component yet either.
- **Explain decisions, never reopen them.** The lesson is a debrief, not a review. If teaching surfaces a genuine disagreement, record it as a change request against the pass that owns the decision — never silently edit the artifact, and never argue the owner out of the pass's gate.
- **No unexplained jargon.** Every term of art (gate, swimlane, fork, ADR, harness, eval, frontier…) is defined in one plain sentence at first use and collected in the lesson's Vocabulary section. The owner consumes lessons by voice; an undefined term is a stall.
- **The learner's words are the gate.** The lesson isn't done when it's written — it's done when the owner can restate the TL;DR and the top decision in their own words (the quiz, Step 4). Understanding is falsifiable too.
- **Lessons are durable.** Like no-go records, lessons live in the repo (`cvg/docs/lessons/`) and are searchable — the owner re-reads them before client calls, onboarding, or the next pass. A lesson that exists only in chat scrollback is a lesson lost.

## Inputs / Outputs / Gate

| | Artifact |
|------|----------|
| **IN** | A pass that just closed (its artifacts, its gate output, the session that produced them) — or any named Converge artifact the owner points at. |
| **OUT** | A lesson at `cvg/docs/lessons/lesson-<pass-slug>-<topic>.md` from [references/lesson-template.md](references/lesson-template.md), plus a conversational walkthrough (and, with `--quiz on`, a Feynman check). |
| **GATE** | Every artifact the pass emitted appears in the component walkthrough; every decision names at least one rejected alternative; every term of art is defined at first use; the lesson ends with 3–5 check-yourself questions; nothing in the taught artifacts was modified. |

## Flags

Two kinds: **base flags** (shape the whole lesson) and **teaching modes**
(composable, each operationalizing one evidence-based learning technique — see
"Teaching modes" below). Modes compose: `--adept --review --teachback` is a
first-exposure lesson that leads with intuition, ships a review deck, and
closes with a mastery loop. Every mode applied is declared on the lesson's
`modes:` line (agents-first: greppable, so a later pass knows how it was taught).

| Flag | Default | Effect |
|------|---------|--------|
| `--depth full\|brief` | `full` | `full` = every component gets the four-part treatment. `brief` = TL;DR, top three components, top decision — a five-minute debrief for a pass the owner has seen before. |
| `--quiz on\|off` | `on` | `on` = end with the Feynman loop (owner explains back, you correct). `off` = deliver the lesson and stop — for async/absent owners reading the file later. Superseded by `--teachback` when that mode is on. |
| `--level eli5\|novice\|expert` | `novice` | The explanation altitude. `eli5` = plain analogy-first, no jargon; `novice` = the default four-part treatment; `expert` = terse, assumes vocabulary, leads with the decision. Manages the expertise-reversal effect — match the altitude to the learner. |

### Teaching modes (composable; each emits or reshapes, and is gated when present)

| Mode | Kind | What it makes the lesson DO | Technique · why |
|------|------|------------------------------|-----------------|
| `--adept` | emitter → `## ADEPT explanations` | Re-teaches each load-bearing component as **A**nalogy → **D**iagram → **E**xample → **P**lain-English → **T**echnical — intuition before formalism | Worked-example effect + Mayer dual coding; fixes "handed technical output with no mental model" |
| `--review [spaced]` | emitter → `## Review schedule` | Ships a flashcard deck (Q/A) + a dated retrieval schedule (day 1 · 3 · 7 · 21) | Spaced retrieval (the single strongest combo); fights *long-term* delegation-ignorance, not just the handoff moment |
| `--map` | emitter → `## Concept map` | Gives the owner a shuffled node list to assemble into the component/data-flow map, then shows the answer edges | Concept-map *construction* (generation beats studying a pre-made map); builds the architectural mental model |
| `--teachback` | reshape (quiz) | Upgrades `--quiz`: owner restates each load-bearing point; you grade the gaps and **re-teach only the misses**, then re-test | Self-explanation/Feynman + the mastery feedback loop (the real ~half of the "2-sigma" effect) |
| `--socratic` | reshape (walkthrough) | Delivers the walkthrough as a graduated question ladder (pump → hint → prompt → reveal) instead of a lecture; detects the misconception and targets it | Intelligent-tutoring dialogue moves (AutoTutor); forces active generation |
| `--why` | reshape (decisions) | For each locked decision, asks the owner "why X over Y?" and waits before revealing the recorded rationale | Elaborative interrogation + generation effect; stops passive acceptance of the machine's choices |
| `--mix` | reshape (check-yourself) | Interleaves the check-yourself questions across all components in shuffled order rather than block-by-block | Interleaving + desirable difficulty; blocked review feels fluent but doesn't transfer |

**Feedback-first invariant.** The highest-confidence lever in the evidence is
the *test → correct-only-the-misses → re-test* loop. Every reshape mode that
quizzes (`--teachback`, `--socratic`, `--why`, `--mix`) MUST re-teach only what
the owner missed and then re-test that — never re-lecture the whole thing, never
move on with a miss unaddressed.

## Instructions

### Step 1 — Locate (which pass closed, and what did it emit?)

Identify the pass being taught — from the conversation, or from the freshest artifacts on disk. The artifact map:

One pass, one typed folder — that is what makes "which pass emitted this?"
answerable from the floor rather than from memory:

| Pass | What it emitted (teach all of it) |
|:--:|---|
| 0 `idea-to-brd` | `cvg/docs/brd/*.md` — or a `cvg/docs/no-go/*.md` record |
| 1 `brd-docs-to-tech-req` | `cvg/docs/tech-spec/*.md` (requirements, metrics, gap register) |
| 2 `tech-req-to-adrs` | `cvg/docs/adrs/NNNN-*.md` + `cvg/docs/CONTEXT.md` |
| 3 `reqs-to-swimlane-plans` | `cvg/swimlanes/<seam>/` — one lane per folder, ordered legs inside |
| 4 `sketch-plans-adversarial-review` | the same plans sharpened in place (the diff IS the artifact) + `cvg/swimlanes/.consensus/objection-log.json` + the fork declaration |
| 5 `task-spec` | `cvg/tasks/T-*.md` — atomic, self-verifying, HMAC-sealed units |
| ① `task-specs-to-issues` | the tracker board — one issue per spec, `blocked-by` edges |
| 7 `task-to-runtime-contract` | `cvg/execution/<task-id>/execution-profile.yaml` + adapter manifests, bound evidence, and gate receipts |
| 8 `task-loop` | the PR (branch, diff, green eval) or the blocked-task report, plus the `cvg/receipts/` receipt |

A workspace created before the typed-folder layout keeps the legacy flat names
(`cvg/docs/brd-*.md`, `cvg/docs/tech-spec-*.md`); teach whichever the floor
actually shows.

Collect the full inventory: every file the pass created or changed (use git — the pass's commits bound the diff), the gate script's output, and any conversation context (locked decisions, accepted objections, open questions).

### Step 2 — Read (build the component inventory)

Read everything in the inventory. For each artifact, list its components at the granularity the owner will meet them — sections of a BRD, individual ADRs, lanes of a plan, fields of a task-spec, agents of a harness. For each component draft the four-part treatment: **what it is · why it is shaped this way · the decision it encodes · what breaks downstream without it**. Where the "why" isn't in the artifact, recover it from the pass's SKILL.md rules, the session, or the gate — and if it is genuinely unrecoverable, say so in the lesson rather than inventing a rationale.

### Step 3 — Teach (write the lesson, then walk it)

Write `cvg/docs/lessons/lesson-<pass-slug>-<topic>.md` from [references/lesson-template.md](references/lesson-template.md):

1. **TL;DR** — one breath: what exists now that didn't before, and what it unlocks.
2. **Why this pass exists** — its altitude, what it protects, who consumes its output next.
3. **The artifact, component by component** — the four-part treatment for every component in the inventory. Nothing emitted is skipped; a component too trivial to teach still gets one line saying why it's trivial.
4. **Decisions and roads not taken** — every decision the pass locked, each with at least one rejected alternative and the reason it lost. This is where understanding lives; a decision with no alternative is a description, not a decision.
5. **Vocabulary** — every term of art used above, one plain sentence each.
6. **What to watch** — open questions, `(guessed)` numbers, accepted risks, minor gaps: the lesson's honest edges.
7. **Check yourself** — 3–5 questions the owner should now be able to answer, each pointing at the section that answers it.

Then **walk it conversationally**: short plain-prose paragraphs in the pass's teaching order, voice-friendly — no tables read aloud, no bullet dumps. The file is the record; the walkthrough is the lesson.

### Step 3.5 — Apply the teaching modes (when flagged)

Declare every mode in effect on a **`modes:`** line directly under the lesson's
title blockquote (e.g. `> modes: adept, review, teachback`) — greppable, so a
later pass and `check-lesson.sh` both know how it was taught. Then:

**Emitter modes add an optional section** (order: after "Check yourself"):

- `--adept` → **`## ADEPT explanations`**. For each load-bearing component, one
  `### <component>` block carrying all five labels, in order: **Analogy:** /
  **Diagram:** (a small ASCII or mermaid sketch) / **Example:** (a concrete
  instance from the real artifact) / **Plain-English:** / **Technical:**. Lead
  with the analogy; never open with the technical line.
- `--review [spaced]` → **`## Review schedule`**. A flashcard deck — at least
  three `Q:` / `A:` pairs pulled from the load-bearing facts — followed by a
  dated retrieval schedule with at least the `day 1`, `day 3`, `day 7`, `day 21`
  checkpoints, each naming which cards to re-test. Spacing is the point: the
  schedule is not decoration.
- `--map` → **`## Concept map`**. A shuffled node list for the owner to
  assemble, then the answer as edge lines (`A --> B`, or a fenced `mermaid`
  graph). The owner builds it first; the answer is revealed below a
  `<!-- answer -->` marker.

**Reshape modes change how an existing section is produced** (no new section;
they are behavioral, declared on `modes:` and honored in the walkthrough/quiz):

- `--teachback` — the quiz becomes a mastery loop: grade each restatement, list
  the specific misses, re-teach ONLY those, re-test them. Supersedes `--quiz`.
- `--socratic` — deliver the walkthrough as a question ladder: pump ("what do
  you think happens if…?") → hint → prompt → reveal, one rung at a time.
- `--why` — at each decision, pose "why X over Y?" and wait for the owner's
  answer before revealing the recorded rationale from the Decisions table.
- `--mix` — shuffle the check-yourself questions across all components rather
  than grouping them by component.

**The feedback-first invariant** (above) binds every quizzing reshape: correct
only the misses, then re-test — never re-lecture, never leave a miss open.

### Step 4 — Quiz (the Feynman loop, `--quiz on`)

Ask the owner to explain back, in their own words: (a) the TL;DR, and (b) the single most load-bearing decision and why its alternative lost. Correct gently and concretely — point at the artifact line, not at the lesson. One round is usually enough; stop when the restatement would survive a client asking "why is it built this way?". What the owner *couldn't* restate marks the lesson section to sharpen — fix the file before closing.

Then run the gate through the CLI and walk the checklist:

```bash
cvg lesson                                          # finds the lesson under cvg/docs/lessons/
cvg lesson cvg/docs/lessons/lesson-<pass-slug>-<topic>.md \
  --immutable <every-artifact-the-lesson-teaches>    # optional; enforces "teaching changes nothing"
```

`cvg lesson` is a byte-exact pass-through to `scripts/check-lesson.sh`, so the
script stays runnable on its own (`bash scripts/check-lesson.sh <lesson>`) when
no CLI is installed. With no path it discovers the lesson under
`cvg/docs/lessons/` (then legacy `docs/lessons/`); because lessons accumulate,
more than one is a usage error that names them all rather than a guess.

The checker's **last line is always exactly one machine token** — `CHECK_LESSON=PASS` (exit 0), `CHECK_LESSON=FAIL` (exit 1), `CHECK_LESSON=USAGE_ERROR` (exit 2) — printed after the human `GATE:` summary line, so both a person and `cvg lesson` can read the verdict. It fails CLOSED on everything it can see: all seven sections present by exact template name (a `## Notes on why this pass exists` decoy does not count); every `### <component>` walkthrough block carrying *what breaks downstream*; the decisions table non-empty; 3–5 check-yourself questions; well-formed emitter-mode sections; and, with `--immutable`, a clean `git status --porcelain` across the taught artifacts (modified or untracked-but-referenced fails; outside a git repo it warns and skips). What it cannot see stays human, marked below:

- [ ] *(human)* **Every emitted artifact appears** in the component walkthrough (inventory vs. Section 3 — no silent skips). The script can't see the pass's real inventory from the lesson file alone.
- [ ] *(human)* **Every decision names a rejected alternative** and why it lost. The script proves the table has at least one row; that each row names a *real* alternative is this check.
- [ ] *(human)* **Every term of art is defined** at first use and collected under Vocabulary.
- [ ] *(script)* The lesson **ends with 3–5 check-yourself questions**.
- [ ] *(script, with `--immutable`)* **Nothing in the taught artifacts changed** — `git status` is clean apart from the lesson file.
- [ ] *(human, `--quiz on`)* The owner **restated the TL;DR and the top decision** in their own words.
- [ ] *(script)* **Every mode on the `modes:` line is honored** — each emitter mode's section is present and well-formed (`--adept` → all five ADEPT labels per `### <component>` block; `--review` → ≥3 flashcards + all four `day 1 · 3 · 7 · 21` checkpoints; `--map` → nodes + revealed edges); `check-lesson.sh` verifies the emitter modes it can see and warns on a `modes:` mode it can't confirm.

## Examples

**Example 1 — the canonical trigger.**
User: *"Pass 1 just closed — teach me what was built."* Actions: locate `cvg/docs/tech-spec/analytical-engine.md` and the gate output (Step 1) → inventory its sections and gap register (Step 2) → write `cvg/docs/lessons/lesson-pass-1-analytical-engine.md` and walk it: why requirements are falsifiable, which decision made metric M current→target, what the two minor gaps hold hostage (Step 3) → quiz: owner restates why "use DuckDB" was recorded as a preference, not a decision (Step 4). Result: the owner can defend the spec to the client without opening it.

**Example 2 — teach a single artifact, not a whole pass.**
User: *"Walk me through ADR 0003 — I don't get it."* Actions: scope the inventory to that ADR + `cvg/docs/CONTEXT.md` terms it uses; four-part treatment for the ADR's fact, evidence, and downstream dependents; `--depth brief` shaped output, lesson appended under `cvg/docs/lessons/`. Result: a five-minute targeted lesson, not a full-pass debrief.

**Example 3 — teaching surfaces a disagreement (negative).**
Mid-lesson the owner says *"that scope boundary is wrong — fix it."* Actions: do NOT edit `cvg/docs/brd/*.md`; record the objection as a change request against Pass 0 (or the gap register if Pass 1 already consumed it) and finish the lesson noting the contested line. Result: the artifact's provenance stays intact; the change flows through the pass that owns it.

**Example 4 — async owner.**
The pass closed overnight in an autonomous run; the owner reads later. Actions: run with `--quiz off`; the lesson file carries the full walkthrough and the check-yourself questions stand in for the quiz. Result: understanding is waiting in `cvg/docs/lessons/` when the owner is.

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| The lesson reads like a changelog ("added X, added Y") | The four-part treatment collapsed to "what it is" | For every component, force the fourth part first: what breaks downstream without it? Rewrite from there. |
| A decision has no alternative to name | It was a description, or the alternative was never articulated | Check the pass's session and gate; if the alternative is genuinely unrecorded, write "alternative unrecorded — inferred: X" and flag it under What to watch. |
| The owner fails the quiz on the same section twice | The lesson section teaches the what, not the why | Rewrite that section around its decision and failure mode, then re-quiz only that section. |
| Teaching keeps turning into re-litigating the pass | Debrief and review got blurred | Park every objection as a change request against the owning pass; the lesson explains the artifact as gated, disagreements ride separately. |
| The lesson is enormous and the owner tunes out | `--depth full` on a pass with a large artifact surface (a Pass 5 backlog, a Pass 6 board) | Use `--depth brief` for the walkthrough and let the full component table live in the file; teach the top three load-bearing components by voice. |
| No one can say which pass produced an artifact | Locate step skipped, or artifacts from several passes are interleaved | Bound the inventory with git (the pass's commits) before teaching; a lesson spanning two passes should be two lessons. |

## Notes

- **Why a companion, not a step inside each pass.** Every pass ends at its gate; welding a lesson onto each would couple ten skills to one pedagogy and make teaching mandatory. As a companion it is one skill, versioned once, invocable after any pass — and skippable when the owner already knows the terrain.
- **Why lessons are files.** The same reason no-go records are: memory that survives the session. `cvg/docs/lessons/` becomes the engagement's teaching trail — onboarding material for the next engineer and pre-read for the client call, for free.
- **Voice-first by design.** The owner dictates and listens. The walkthrough is prose a human can speak; the tables stay in the file.
- **Why the companion still gets a CLI door.** Optional is not the same as invisible. Every other skill in the chain is reachable as one `cvg` verb, and this one shipped a gate script, a machine token, and a workspace folder (`cvg/docs/lessons/`, created by `cvg init`) that nothing on the CLI could reach — so the only way to run it was to know the path to a script. A capability an agent cannot discover from `cvg help` or `cvg agent-context` is a capability that does not get used. The verb changes nothing about the pedagogy; it just makes the gate findable.

## Handoff

→ None — a lesson changes nothing downstream. The chain continues wherever the taught pass's own handoff points; this companion returns the owner there, now able to explain what they are approving.

## References

- `references/pass-prompt.md` — the steering prompt for this companion, shipped with the package (never copied into a project) exactly like every pass skill's. `cvg next` names it wherever a pass has closed, so an agent can find the teaching contract without being told it exists.
- `references/lesson-template.md` — the lesson skeleton (TL;DR · Why this pass exists · Component walkthrough · Decisions and roads not taken · Vocabulary · What to watch · Check yourself) with per-section guidance.
- `scripts/check-lesson.sh` — the gate (v0.3.0): exact-name section presence, *what breaks downstream* per `### <component>` block, a non-empty decisions table (whether each alternative is real stays a human criterion), 3–5 check-yourself questions counted, well-formed emitter-mode sections (ADEPT labels per block, all four review days), and optional `--immutable` enforcement that taught artifacts stay untouched. Last line is always `CHECK_LESSON=PASS|FAIL|USAGE_ERROR`.
