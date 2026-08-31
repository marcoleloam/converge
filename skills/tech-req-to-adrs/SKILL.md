---
name: tech-req-to-adrs
description: >-
  Converge Pass 2 (Structure). Reads the Pass 1 tech-spec plus the real codebase
  and writes grounding ADRs under docs/adrs/ — facts and constraints about the
  terrain, never solution design. Use when the user says "structure pass",
  "write the ADRs", "ground the spec against the repo", "is this greenfield or
  brownfield", or "start Pass 2 / Converge Structure". Names the ground, runs the
  brownfield to verify, records each grounding decision as a numbered ADR that
  Pass 3 can stand on, and pins the domain vocabulary in a docs/CONTEXT.md
  glossary as terms crystallize. NOT for solution design or "build X" statements
  — that is Pass 3 planning; stay at terrain altitude.
  Engine is Claude Code on the repo; engine/tracker-agnostic, no baked names.
metadata:
  version: "0.2.1"
  converge_pass: 2
  pass_name: structure
  compatibility: "Claude Code; bash 3.2+ (macOS system bash safe)"
---

# tech-req-to-adrs — Converge Pass 2 (Structure)

Ground the Pass 1 tech-spec against the real system and record the grounding
decisions as ADRs. This pass lowers altitude from *what to build* (the spec) to
*what is true about the terrain we build on* (the ADRs). The deliverable is
files under `docs/adrs/`, not a session summary — v1 produced no file and the
understanding died with the session; this version writes it down so Pass 3 can
stand on it.

- **Converge pass:** 2 of 8 — STRUCTURE.
- **In:** the Pass 1 tech-spec (`docs/tech-spec-*.pdf|md`) + the real repo.
- **Out:** `docs/adrs/NNNN-<slug>.md`, one grounding decision per file, plus `docs/CONTEXT.md` — the domain glossary, updated as terms crystallize.
- **Gate:** the terrain is *named* and every grounding fact is recorded as an ADR a stranger can reconstruct — with no "build X" in any of them.

## Important

- **Terrain, not design.** An ADR records a **fact or constraint that already holds** and its evidence. The instant it says "build the output table that…" it has drifted into Pass 3 and must be split: the fact stays here, the design moves on. This no-drift invariant is the single failure mode of this pass and the only thing the gate truly enforces.
- **Run the brownfield; do not assume it.** Grounding requires reading and *running* the real source, not summarizing a doc. Reconcile the real state of your data store (row counts, contents, freshness) against what the spec assumed before you write a word.
- **Evidence over assertion.** Every ADR cites the line, count, or command output that makes it true (for example, a schema constraint such as `payments.order_id ... REFERENCES orders(order_id)` in a relational project, or the equivalent grounding fact for your stack), so the next engine trusts the file, not the author.
- **No engine/tracker flags.** The engine is fixed (Claude Code on the repo). There is no adversary and no tracker here; those bind in Pass 4 (`--adversary`) and the Fork B register (`--tracker`).
- **Lifecycle: proposed → accepted → deprecated | superseded (v0.4.0).**
  Records are born `proposed` and become `accepted` at review — never at
  scaffold time. **Accepted ADRs are immutable**: when a recorded fact stops
  being true (a fenced absence gets built, a schema migrates), do not edit
  history — scaffold the replacement with `--supersede NNNN`; the script
  stamps both directions (`supersedes:` / `superseded_by:`) and `--check`
  verifies the links. The pass cannot close while any record is still
  `proposed` (`--check --final`).
- **Records speak machine (agents are first-class consumers).** Metadata
  lives in YAML frontmatter (`status`, `date`, `ground`, `spec_ref`,
  `supersedes`, `superseded_by`, `deciders`) so Pass 3 / Pass 5 agents grep
  fields, never prose. `spec_ref` cites the requirement ID(s) (`R-n`) the
  fact grounds — the chain the whole descent stands on: R-n in the spec →
  ADR grounds it → plan cites the ADR → task eval verifies R-n. `--check`
  ends in a stable token: `CHECK_ADR=OK|FAIL|EMPTY|USAGE_ERROR`.

## Instructions

Three steps, in order: **Name the ground → Ground → Record**. The order is
load-bearing — you cannot record a constraint you have not verified, and
recording first would enshrine assumptions.

### Step 1 — Name the ground

State plainly whether this is **greenfield** (nothing exists; the ADRs record the
constraints the spec imposes) or **brownfield** (a working base exists; the ADRs
record what is already true). Write it in the first record — scaffold it with
`scaffold-adr.sh --context` → `docs/adrs/0000-context.md` (Terrain / Given
surface / Build surface / Spec pointer) — so every later decision is anchored
to known terrain. `--check` requires the 0000 record to exist.

Inventory the *given* surface concretely: which sources, stores, build steps, and
serving components already run today, and which the spec still asks to build.
Example — a brownfield data project might be: a source database, a seeder, a
read-only landing into a data store, and no transform or serving layer yet. Name
your own given surface explicitly; a reader must know what is *given* before
reading what *must hold*.

### Step 2 — Ground (check spec against the real system)

Pressure-test the spec against reality — run it, do not read about it:

- Run the project's data-prep / ingest step end to end, then confirm the real state matches what the spec assumed (e.g. row counts, freshness, or parity between a source and its landing).
- Confirm the current shape of the terrain: which layers actually exist versus which the spec still asks later passes to build.
- Read the source schema (or the equivalent contract for your stack) and interrogate the spec against it. Surface the 3–4 facts that would bite Pass 3 if assumed wrong. For example, in a relational/warehouse project these might be:
  - **Join:** how do the core entities actually relate? (e.g. a foreign-key seam such as `payments.order_id ... REFERENCES orders(order_id)`.)
  - **Grain:** what is the real time grain? (e.g. timestamp columns typed as `TIMESTAMPTZ` — UTC.)
  - **Metric:** what does a key business term actually mean against the real columns and any facilitator data that must never leak into the pipeline?

Every fact you intend to record must trace to a schema line, a row count, or a command output you actually observed.

### Step 3 — Record (write the ADRs)

For each grounding decision, scaffold and fill one `docs/adrs/NNNN-<slug>.md` with
the bundled script:

```bash
bash .claude/skills/tech-req-to-adrs/scripts/scaffold-adr.sh "payments join on order_id"
# → docs/adrs/0001-payments-join-on-order-id.md  (auto-numbered, dated, templated)
```

The script auto-increments `NNNN`, slugifies the title, stamps the date, and lays
down a fixed skeleton: YAML frontmatter (status born `proposed`, `spec_ref` for
the requirement IDs) + Context / Decision / **Rejected reading** (the worthiness
test says the fact could have been otherwise — record the otherwise so no later
agent re-litigates it) / Evidence (the observation AND the runnable command that
re-proves it, in a fenced block) / Consequences (ending in "Re-verify when: …" —
the event that would invalidate the fact). Fill it so each record states
**what is** and **what must hold**, cites its evidence, and names its
consequence for downstream passes — never a build instruction. Delete every
template comment as you fill: `--check` fails any record still carrying one,
and any required section left empty. Example — the representative set for a
relational/warehouse project might be:

- `0001-payments-join-on-order-id` — the only orders↔payments seam.
- `0002-utc-date-grain` — all time columns are `TIMESTAMPTZ`; the date grain is UTC.
- `0003-revenue-is-paid-only` — revenue counts paid payments, not order totals.
- `0004-control-data-never-lands` — facilitator/test-only data is fenced out; the pipeline only sees production sources.

Your set will name whatever seams, grains, and definitions your own terrain makes true.

**Not every fact deserves an ADR.** Write one only when all three hold:
(1) **hard to reverse** — assuming it wrong would cost real rework downstream;
(2) **downstream passes stand on it** — a plan, task, or eval will cite it;
(3) **it could plausibly have been otherwise** — a genuine ambiguity was
resolved, not a triviality restated. A fact that fails the test is a line in
the glossary or the context record, not its own numbered file — ADR inflation
buries the four decisions that matter under twenty that don't.

**Pin the vocabulary as it crystallizes (`docs/CONTEXT.md`).** Grounding is
where fuzzy business words meet real columns — "revenue", "active", "order"
stop being prose and start being definitions. The moment a term is resolved
(e.g. *revenue = sum of paid payments, not order totals*), write it into
`docs/CONTEXT.md` right there — don't batch it. The glossary holds **terms
only**: canonical name, one-line meaning, the evidence line it traces to.
No implementation details, no build notes — it is a dictionary, not a spec.
When a term in the tech-spec conflicts with how the data actually behaves,
that conflict is itself a grounding fact: resolve it, record the winner in
the glossary, and cite the evidence. Downstream passes (plans, task-specs,
harness KBs) use these canonical terms instead of re-deriving them.

## Gate — confirm before leaving this pass

Run the checker, then eyeball the invariant:

```bash
bash .claude/skills/tech-req-to-adrs/scripts/scaffold-adr.sh --check
```

- [ ] The terrain is **named** (greenfield or brownfield) in `0000-context.md` (`--check` enforces its presence).
- [ ] Every record's frontmatter `status` sits in the lifecycle enum; the pass closes with `--check --final` — nothing left `proposed`, supersede links bidirectional.
- [ ] Every ADR cites the requirement ID(s) it grounds (`spec_ref: R-n`) — the spec→ADR→plan→eval chain starts here.
- [ ] For brownfield, the base was *run*, not assumed: the project's data-prep/build step was executed and its real state reconciled against the spec's assumptions; the current layer inventory is confirmed.
- [ ] Every grounding decision is its own `docs/adrs/NNNN-<slug>.md` file.
- [ ] Each ADR records a **fact/constraint** with cited evidence — none says "build X" or designs a solution (`--check` greps for build-verbs and flags drift).
- [ ] Every structural fact the spec leans on (join/relationship rules, grain, key business definitions) is pinned to a real schema/source line or command output.
- [ ] Every ADR passes the three-condition worthiness test (hard to reverse · stood on downstream · could have been otherwise) — no ADR inflation.
- [ ] Every business term the spec leans on that could be misread ("revenue", "active", "order") is pinned in `docs/CONTEXT.md` — terms only, each tracing to its evidence.
- [ ] A reader with no session context can reconstruct the given-vs-build picture from `docs/adrs/` alone.

Converged = the checklist passes, not "feels done."

## Examples

**Example 1 — "Run the structure pass on the service."**
Actions: read the Pass 1 tech-spec (`docs/tech-spec-*.pdf|md`); run the project's
data-prep/build step and reconcile its real output against the spec's assumptions;
read the source schema (or equivalent contract); scaffold `0000-context`
(green/brownfield) plus one numbered ADR per structural fact the spec leans on; run
`scaffold-adr.sh --check`.
Result: `docs/adrs/` holds the records; `--check` is green; Pass 3 can read them.

**Example 2 — "Is this greenfield or brownfield, and what are we standing on?"**
Actions: Step 1 only — write `docs/adrs/0000-context.md` naming it green/brownfield
and listing the given surface (what runs today) vs. the build surface (what the spec
still asks later passes to add).
Result: the given-vs-build map is a file, not a memory.

**Example 3 — "Ground the spec against the repo" but the draft ADR says "build a fact table keyed on order_id."**
Actions: split it. Keep the fact (e.g. `0001-payments-join-on-order-id`: payments
join orders on `order_id`); delete the build clause and hand the "fact table" design
to Pass 3.
Result: the ADR passes `--check`; no design leaks into Pass 2.

## Troubleshooting

- **`--check` fails: "build-verb detected in ADR".** → An ADR designs a solution (build/create/implement/add). → Split it: keep the fact, move the design to Pass 3 (`reqs-to-swimlane-plans`).
- **The real state disagrees with the spec (e.g. row counts differ between a source and its landing).** → The prep step was stale or something changed a record mid-run. → Re-run the project's data-prep step; if the discrepancy persists, it IS a grounding fact — record it (e.g. an ADR on which anomalies survive into the landing).
- **No tech-spec exists.** → Pass 1 has not run. → Stop and run `brd-docs-to-tech-req` first; Pass 2 needs the spec as input.
- **Tempted to write "build X".** → You have left terrain altitude. → Stop; that belongs to Pass 3. Pass 2 records only what *is* and what *must hold*.
- **Facilitator/test-only data leaks into the pipeline.** → A fence that should exclude it failed. → That is a real defect and a grounding fact; record it and flag the leak, do not silently drop it.

## Handoff

→ **`reqs-to-swimlane-plans`** (Pass 3, DECOMPOSE) reads `docs/adrs/*.md` as its
grounding inputs and splits the system at its real seams into `swimlanes/*.plan`
files. Every plan must trace back to a fact recorded here, may not contradict
a recorded ADR, and uses the canonical terms pinned in `docs/CONTEXT.md`.

*Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches what this pass just produced — every component, the decision it encodes, what breaks downstream without it — before the descent continues.

## References

- `references/adr-vs-design.md` — the no-drift boundary: worked examples of a grounding ADR vs. a design ADR, and how to split a mixed one.
- `references/grounding-checklist.md` — the brownfield run-and-reconcile protocol (row parity, schema inventory, join/grain/metric interrogation).
