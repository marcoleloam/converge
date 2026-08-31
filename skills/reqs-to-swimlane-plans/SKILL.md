---

name: reqs-to-swimlane-plans
description: Implements Converge Pass 3 (DECOMPOSE). Reads the Pass 2 ADRs (docs/adrs/) plus the in-session understanding and splits the system into one sketch plan per swimlane (swimlanes/*.plan) along its natural seams — by feature or component, plan altitude only, no tasks and no implementation code. Decomposition chain — seam → swimlane → leg → task-spec; each lane's pieces are legs (one responsibility + one proving test), yielding 1:N task-specs at Pass 5. Use when the user says "decompose", "decompose this", "swimlane plans", "split it into plans", "find the seams", "one plan per lane", or "split the lane into legs". Each plan lists legs, dependencies, build order, and inherits the ADR decisions; the downstream lane names the exact upstream interface it consumes. Engine- and tracker-agnostic; runs in the same session as Pass 2, after structure is confirmed and before the plans are attacked in adversarial review. Not for atomic tasks or implementation code — that is Pass 5 (task-spec).
metadata:
  version: "0.2.1"
  compatibility: Claude Code on the repo; same session as Pass 2 (tech-req-to-adrs). No engine/tracker flags.
---

# reqs-to-swimlane-plans — Converge Pass 3 (DECOMPOSE)

> **Identity:** The decomposition pass that cuts a confirmed system into one sketch plan per swimlane, along its real seams.
> **Domain:** Plan-altitude decomposition, swimlane partitioning, ADR inheritance, seam/interface naming.
> **Decomposition chain:** **seam → swimlane → leg → task-spec.** The seam is the joint; the lane is what gets planned; the leg is the lane's named stretch (one responsibility, one proving test); the task-spec is the atomic unit with an eval — born at Pass 5, never here. See `references/legs.md`.
> **Converge Pass:** 3 of 8 — DECOMPOSE. Lowers altitude from Pass 2's "what is true about the terrain" (ADRs) to "what to build in each lane, and in what order" (plans) — but never as far as Pass 5's tasks or code.
> **Engine/flags:** Claude Code, SAME session as Pass 2. No flags — single transformation.

## Important — read first

- **Plan altitude only. This is the one guardrail that defines the pass.** A plan describes *what* each lane contains and *in what order* it is built. The moment a plan holds a query body, a handler body, or an atomic task with an eval, it has left Pass 3 and skipped the adversarial review meant to harden the plan first. When you feel the urge to write implementation code, stop — that is Pass 5.
- **Inherit the ADRs; never re-decide them.** Decisions were bound in Pass 2 under `docs/adrs/`. Plans stand on those facts. A plan that contradicts an ADR, or silently re-settles something an ADR already settled, fails the gate.
- **Same-session handoff.** The Pass 2 understanding lives only in this session — no file reloads it. That is why Pass 3 shares Pass 2's session and takes no engine flag. Cross a session boundary and the input is gone; re-run Pass 2.
- **The number of lanes is the number of real seams — not a quota.** Two lanes (for example, a transform lane vs. a serve lane) is one common shape, not a rule; a system may reveal one lane or five. An unnamed seam is a hidden coupling; a forced extra lane is a fake one.

## Inputs / Outputs / Gate

| Slot | Contract |
|------|----------|
| **IN** | The Pass 2 understanding (held in-session) **+** the ADRs at `docs/adrs/*.md` (each a numbered decision file — e.g. a join-key decision, a date-grain decision, a metric-definition decision). |
| **OUT** | **One directory per swimlane** under `swimlanes/`: `swimlanes/<seam>/` holding a **lean PRD index** `_lane.md` **plus one file per leg** `leg-NN-<tech>.md`. Nothing inside the folder repeats the folder. The PRD links to its legs; it never embeds their detail. The folder carries the type and the file carries the slug — the same rule the typed `docs/` folders use — while the **stable id stays fully qualified in frontmatter** (`leg: swimlane-<seam>-leg-NN`; `<tech>` a swappable label). |
| **GATE** | One plan per genuine seam, each listing **features / dependencies / build-order / proving-tests** and inheriting the relevant ADR decisions; the downstream lane names the exact upstream interface it consumes; **plan altitude held** (no tasks, no implementation code). Plus the seam-economics hardening: **one steel-thread lane** (H1), per-lane **risk + owner** (H2/H3), stated **seam evolution** (H4), and any cycle **broken and recorded** (H5). See the full checklist under [Gate](#gate--confirm-before-leaving-this-pass). |

## Flags

No engine/tracker flags — this is a single transformation. It runs in the SAME session as Pass 2 because the understanding is the handoff and cannot survive a session boundary. There is no adversary and no tracker at this pass: the adversary binds in Pass 4 (`--adversary`), the tracker in the Pass 5/register fork (`--tracker`). The lane count is not a flag either — it is the number of genuine seams the architecture reveals (see Step 1).

## Instructions

### Step 1 — DECOMPOSE: find the natural seams

From the loaded Pass 2 understanding and the ADRs, split what is being built into its top-level pieces and justify where each boundary falls.

- Cut along **natural seams — by feature OR by component**, never arbitrary slices.
- Name each seam and the **dependency direction** between the resulting groups. Do not plan the contents yet.
- The seam itself is an **interface**, and it must be nameable. *Example — a data pipeline whose upstream inputs are already fixed:* the seam falls cleanly above those inputs — a **transform** lane that shapes the data (Component A) and a **serve** lane that exposes it (Component B), with the **published-output contract** (the tables/columns A produces and B consumes) as the interface between them. Your seams will follow your own system's real boundaries.
- If a boundary is fuzzy, that is signal: either it is a real seam (name the interface) or a false one (fold the lanes back together).
- **Prefer the highest seam, and the fewest.** Cut at the highest point the architecture allows — above implementation detail, at the published contract — and resist adding seams: every seam is an interface someone must freeze, attack (Pass 4), and honor (Pass 5). The fewer seams across the system, the better; the ideal number is the smallest that still separates genuinely independent work.
- **The deep-lane test.** For each proposed lane you should be able to answer, without reading its internals: *what does it do, how do you use it (its interface), what does it depend on* — and **what is this lane's secret** (the decision most likely to change, per Parnas)? If a lane can't be understood from its interface alone — if a consumer would need to see inside it — the boundary is wrong: move it or fold the lane. A clean interface around a volatile decision is only the right cut if that decision sits *inside* the lane. *(This is Ousterhout's "deep module": a narrow interface hiding large, changeable functionality.)*
- **Name the steel-thread lane (H1 — walking skeleton).** Exactly one lane in the set is the **thin vertical path that exercises every seam end-to-end** (build → prove) before the component lanes fatten. Mark it `thread=yes` on its lane-meta line. Cutting only "by component" (e.g. transform vs serve) is a *horizontal* slice — it can leave a plan set where no lane is independently demonstrable and integration mismatches hide until late; the steel thread is the antidote. Prove the skeleton connects, then flesh out.
- **Annotate seam risk and sequence risk-first (H2).** On each lane's lane-meta, record `risk=low|med|high` — the confidence that the frozen contract / hard constraint is *right*. Risk rarely tracks effort: spike the highest-risk seam **ahead of** pure dependency order, so a fatal contract mismatch surfaces before the easy 80% is built.
- **A seam is one-way — break cycles explicitly (H5).** The seam test *requires* a one-way dependency. When two lanes genuinely co-depend, do not smear the boundary: break the cycle with dependency inversion (both depend on an extracted shared contract), an async/event boundary (one sync cycle → two one-way flows), or a promoted shared kernel — and record which technique you used as a blocks-build open question.
- **Use the canonical vocabulary.** Name lanes, interfaces, and components with the terms pinned in `docs/CONTEXT.md` (Pass 2's glossary). A plan that invents a synonym for a defined term creates drift the adversary then has to catch.

### Step 2 — SWIMLANE: one plan per seam

Write one sketch plan per seam under `swimlanes/`. **One lane, one plan, one focus.** Each plan should carry:

1. **Identity + lane-meta line** — which component this is (e.g. A · Transform / B · Serve), its input/output contract, and the greppable **`lane-meta: thread=<yes|no> · risk=<low|med|high> · owner=<stream>`** line. **`owner` (H3 — Conway)** names the single stream/team that owns the lane (or `shared`/`platform`); a seam that splits one owner or fuses two is a coordination smell — flag it, because architecture mirrors the org's communication structure.
2. **Legs — the lane's named stretches** — the pieces inside the lane, each named **`leg-NN-<tech>`** in build order (`leg-01-dlt`, `leg-04-dbt-bronze`, `leg-01-fastapi` — which is also the filename, since the folder already names the swimlane; cited outside the plan by the fully-qualified key `swimlane-<seam>-leg-NN`). **Nomenclature (field-grounded):** the **stable reference key is `swimlane-<seam>-leg-NN`** (2-digit zero-pad so ids sort); the **`<tech>` is a lowercase-kebab tool slug appended as a *swappable display label*, never part of the key** — swapping DuckLake→Iceberg or dlt→Airbyte must not break a single cross-reference (embedding volatile tech in an identifier is the classic id anti-pattern). Each leg carries **one responsibility in prose** + **one proving-test cluster** (what its tests assert, never test code), is **independently finishable** (buildable/provable without any later leg), and is **sized to one build-order step + one context window** — bigger is two legs; two stretches sharing one proving test are one leg. No quotas. See `references/legs.md`.
3. **The consumed interface + seam evolution (downstream lanes only)** — the exact upstream tables/columns/fields this lane reads, so the seam is explicit. A downstream lane names precisely which published outputs each endpoint/tool/consumer reads and **never reaches below the seam** into an upstream lane's internals. **Seam evolution (H4):** the frozen contract *will* change — state how safely. Additive changes (a new column/field/endpoint) are non-breaking; renames, removals, and newly-required fields are **breaking** and need a coexistence window before this lane cuts over. Recommend a consumer-driven contract test the upstream must keep green, so a later change can't silently break this lane.
4. **Dependencies** — a small DAG showing the build order between the lane's own pieces and its inbound seam.
5. **Build order** — a sane sequence, with the gating input called out (for example, a frozen acceptance-question set may gate the output layer and the final serving surface).
6. **Tests that prove each leg** — at plan altitude: *what* each test asserts, keyed by leg (`leg-NN`), not the test code. The leg never carries an eval — the eval binds at Pass 5, when the leg yields its **1:N task-specs** (the leg's responsibility becomes the task's intent, its proving-test cluster the eval seeds).
7. **Open questions** — anything the ADRs do not cover, with an owner and whether it blocks the build. Surface it here; do not invent the answer inside the plan.

### The swimlane is a directory: a lean PRD + one file per leg (v0.8.0)

The folder names the seam **once**. `swimlanes/models/` holds `_lane.md` and
`leg-01-staging.md` — not `swimlanes/models/swimlane-models.plan.md` and
`swimlane-models-leg-01-staging.md`, which restated the directory in every
filename and pushed the only part that differs off to the right. `_lane.md`
sorts above the legs, and a **lane is recognized by containing a lane PRD, never
by its directory name** — which is what allows the prefix to go without any gate
losing the ability to find a swimlane.

A swimlane is **`swimlanes/<seam>/`** (legacy `swimlanes/<seam>/` still gated), containing:

- **The PRD — `_lane.md`** — a *lean index*. Field-grounded
  structure (Spec Kit / arc42 / Amazon PR-FAQ): **lane-meta · identity + why ·
  Seam · Architecture** (mermaid `flowchart LR` + adjacent numbered steps —
  dual coding) **· Non-Goals** (the #1 anti-bloat device — explicit
  out-of-scope) **· Legs index** (a table that *links* to each leg file, one
  line of responsibility each) **· Dependencies · Build order · Open questions ·
  Spec traceability.** The PRD holds **no leg detail** — it stays black-box
  altitude so it never bloats as legs grow.
**What a `Yields` bullet may contain.** One unit of work, stated plainly, and
nothing else. It is read directly by `cvg tasks plan` at Pass 5 — the preview
derives one proposed Task-Spec per bullet and names it from the bullet's own words
— so rationale, cross-references and edit notes in a bullet become noise in a task
name. Reasoning belongs in **Responsibility** or **Independence**; ownership rules
belong in **Independence**; a decision the leg has not made ("one unit, or three if
they prove similar") must be **made here**, because Pass 5 cannot count an
undecided list and will not guess. This is guidance, not a gate: a length or
format heuristic would flag legitimate prose as often as it caught a real leak.

- **One file per leg — `leg-NN-<tech>.md`** — atomic and
  independently evolvable. Structure (Spec Kit user-story / INVEST / Gherkin /
  Shape Up): **frontmatter** (`leg:` the stable key, `parent`, `swimlane`,
  `status`, `spec_ref`, `depends_on`) **· Responsibility** (one job) **· Proves**
  (**declarative Given/When/Then acceptance criteria, 1–3, never an eval**) **·
  Independence · Consumes/Produces · Appetite** (size token) **· Yields** (the
  1:N task-specs it seeds at Pass 5) **· Re-verify when.** Status enum:
  `proposed → accepted → in_progress → done` (+ `superseded`); an accepted leg is
  edited by superseding, not in place.

Bidirectional links (like ADR supersede): the PRD's Legs index links **down** to
each leg; each leg's `parent:` frontmatter + a top back-link points **up**. Every
file is scaffolded with `new-plan.sh` (`"<seam>"` for the PRD, `--lane <seam>
--leg NN-<tech>` for a leg) and gated together by `--check`.

**Naming the stack is allowed here — as a reversible pick, not a silent lock.**
Pass 3 may bind the concrete tool per leg (the `<tech>` label) — the tech-spec's
A-1 expects the stack decided against the ADRs at this pass. But bind it at the
*last responsible moment* and treat it as replaceable: the choice rides in the
swappable `<tech>` label and (where a genuine alternative was rejected) an open
question or a note — never in the stable id, and never as code.

Keep each plan tight and skimmable. Plan altitude only.

### Step 3 — GROUNDED: each lane inherits the ADRs

Tie every lane back to the bound decisions in `docs/adrs/`.

- Each lane honors the decisions the ADRs bound for it — for example, a transform lane honors any ADR-fixed join path and grain; a serve lane honors any ADR-fixed read boundary (reading only the published contract, read-only, never reaching into an upstream store or below-contract internals).
- Trace each component back to the tech requirement or ADR it satisfies (a short "spec traceability" note per plan makes this checkable).
- A plan that contradicts an ADR, or that re-decides something an ADR already settled, fails this step — fix the plan, do not edit the ADR here.

### Step 4 — Gate and hand off

Run the [Gate checklist](#gate--confirm-before-leaving-this-pass). When every box holds, the `swimlanes/<seam>/` directories are the input to Pass 4 (`sketch-plans-adversarial-review`), where a **different** model attacks them one at a time (PRD then legs) and names the fork.

## Gate — confirm before leaving this pass

- [ ] One **`swimlanes/<seam>/`** directory per genuine seam, each holding a lean PRD `_lane.md` + one file per leg `leg-NN-<tech>.md`. (`--check` also accepts the legacy `swimlane-<seam>/swimlane-<seam>.plan.md` + `swimlane-<seam>-leg-NN-<tech>.md`, so a workspace written before the rename never reads as EMPTY — the one failure mode that would silently drop a pass's evidence.)
- [ ] The split follows a natural seam — by feature or component — and each boundary is **justified**, not a guess and not a quota.
- [ ] **The PRD is a lean index** — lane-meta, Seam, Architecture (mermaid + steps), **Non-Goals**, a Legs-index table linking to each leg file, Dependencies, Build order, Open questions — and holds **no leg detail**.
- [ ] **Each leg file is complete and atomic** — frontmatter (stable `leg:` key, `parent`, `status`), a single **Responsibility**, **Proves** as **Given/When/Then** (1–3, no evals), Independence, Consumes/Produces, Appetite, Yields.
- [ ] **Links are bidirectional and consistent** — every leg file is referenced in the PRD index (no orphan) and every index row has a file (no dangling); legs are **contiguous** `leg-01..leg-0N` across the files.
- [ ] **Leg nomenclature holds** — the **filename** is `leg-NN-<tech>.md` (the folder already names the swimlane, so repeating it in every file only pushes the part that differs to the right); the **stable key** is the fully-qualified `swimlane-<seam>-leg-NN`, carried in the leg's `leg:` frontmatter and used by every cross-reference (`depends_on`, the objection log, Pass 5 task-specs). Filename is human affordance, frontmatter is machine key — conflating the two is what produced the redundancy. `<tech>` is a swappable label, **never** part of the key.
- [ ] Each leg carries one responsibility in prose + one proving-test cluster, is **independently finishable**, and fits one context window — bigger is two legs; two stretches sharing one proving test are one leg.
- [ ] No leg carries an eval — the eval binds at the task-spec; each leg yields **1:N task-specs** at Pass 5 and is cited by them (`swimlane-<seam>-leg-NN`).
- [ ] Each plan inherits the relevant `docs/adrs/*` decisions and **contradicts none** of them.
- [ ] The downstream lane names the **exact upstream interface** it consumes (the published tables/columns/fields) and never reaches below it.
- [ ] Open questions the ADRs do not cover are surfaced with an owner and a blocks-build flag — not answered inside the plan.
- [ ] **Plan altitude held** — no atomic tasks, no implementation code anywhere.
- [ ] **Steel thread named (H1)** — exactly one lane carries `thread=yes` and exercises every seam end-to-end (build → prove) before the component lanes fatten.
- [ ] **Seam economics on every lane (H2/H3)** — each `lane-meta` carries a real `risk=` and `owner=`; the highest-risk seam is spiked first, not deferred behind pure dependency order.
- [ ] **Seam evolution stated (H4)** — every downstream lane says how its consumed contract may change (additive-safe vs breaking + coexistence window).
- [ ] **No unbroken cycles (H5)** — any genuine two-way dependency is broken by a named technique (dependency inversion / async boundary / shared kernel) and recorded as a blocks-build open question, never smeared into a fuzzy boundary.

`new-plan.sh --check` enforces the machine-checkable subset (lane-meta values, the single steel-thread lane, downstream seam-evolution, legs present + named + **contiguous** `leg-01..leg-0N`, and the altitude guards) and ends every surface in a stable token — **`CHECK_PLAN=OK|FAIL|EMPTY|USAGE_ERROR`** (agents are first-class users; the Pass 3 `cvg` subcommand gates on this, never on prose). The rest is the human read above: a green `--check` proves the legs **exist, are named, and are ordered** — it does *not* prove they are well-*cut*. Whether a leg is genuinely independently-finishable and passes the fold test is Pass 4's judgment, not a grep's. When these hold, hand off to Pass 4.

## Examples

**Example 1 — a common two-lane cut (illustrative, for a data pipeline with a serving layer).**
User says *"decompose this — the ADRs are written."* → From the in-session understanding + `docs/adrs/`, you identify the seam above the fixed upstream inputs and cut two lanes: Component A · Transform and Component B · Serve, with the published-output contract as the interface between them. → You write `swimlanes/<transform-lane>.plan` (the staged transformation layers, each layer's responsibility, a test strategy, build order gated on the frozen acceptance questions) and `swimlanes/<serve-lane>.plan` (a shared query core plus each transport/interface, the exact published columns each endpoint/tool consumes, read-only/contract-only isolation). → Result: two skimmable plans, each tracing to its ADRs, seam named, no implementation code — ready for adversarial review.

**Example 2 — resisting altitude drift.**
User says *"split it into plans and write the dedup query while you're at it."* → You produce the plans, and in the relevant lane you write that step's *responsibility* ("dedup duplicate records by business signature, quarantine the rest") but **not** the query body. → You tell the user the query is Pass 5 (`task-spec`) work and the plan stays at altitude so Pass 4 can attack the plan before any code exists.

**Example 3 — a false seam.**
User proposes three lanes where two of them are just two transports (say, an HTTP API and a tool interface) over the same logic. → You note they share one query core and differ only in protocol framing — that is one lane (serve) with two transports, not two lanes. → You fold them into a single serve plan as components B2/B3 over a shared B1, and record the split-later condition (only if one transport needs logic the other doesn't). Two lanes, not three.

**Example 4 — legs inside a lane.**
The transform lane's plan reads: `leg-01` ingest + pin raw sources read-only; `leg-02` conform to silver — dedup, types, UTC grain; `leg-03` publish gold — serving-ready tables shaped to the frozen questions. Each leg: one responsibility, one proving-test cluster, independently finishable in order. → At Pass 4 the adversary attacks leg by leg and objects by leg ID (*"leg-02 assumes a dedup key the ADRs don't name — FIXED in swimlane-transform-leg-02"*). → At Pass 5, `swimlane-transform-leg-03` yields three task-specs (one per published table) — 1:N, with every task citing the leg. A drafter who writes `leg-04: the conform query` has left plan altitude — the query is a task, not a leg.

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| A plan contains a query body or a handler body | Altitude leak into Pass 5 territory | Delete the code; replace with the component's *responsibility* in prose. Push the code to `task-spec` (Pass 5). |
| A plan asserts a join/grain/metric/rule the ADRs don't back | Re-deciding instead of inheriting | Remove the assertion; cite the ADR instead. If no ADR covers it, log it as an open question (owner + blocks flag), don't invent it. |
| The understanding "feels gone" / plans read like guesses | Session boundary crossed since Pass 2 | Stop. Re-run Pass 2 (`tech-req-to-adrs`) in this session to reload the understanding and confirm the ADRs; then decompose. |
| Three-plus lanes and the extra one feels thin | Forced quota, not a real seam | Test each seam by naming its interface. If you can't name a hard interface, fold the lane back in. |
| Downstream plan reaches below the seam (into an upstream lane's internals) | The interface wasn't pinned | Make the plan name the exact published tables/columns/fields it consumes; any missing field becomes a "new output request" upstream, never a deeper read. |
| ADRs missing under `docs/adrs/` | Pass 2 didn't record, or ran in another session | Do not proceed on memory. Ensure Pass 2 wrote the ADRs; plans inherit files, not recollection. |
| Two lanes genuinely co-depend (the one-way seam test fails) | A real cycle, not just a bad cut | Break it (H5): dependency inversion (both depend on an extracted shared contract) / async boundary (sync cycle → two one-way flows) / promoted shared kernel. Record the technique as a blocks-build open question; never smear the boundary. |
| `--check` says "no steel-thread lane" | The set is all horizontal component lanes; nothing is demonstrable end-to-end | Mark the thin vertical path `thread=yes` (H1 walking skeleton). If no lane exercises every seam end-to-end, the decomposition is layered — add or designate the steel thread before fattening components. |
| `--check` flags "lane-meta missing thread/risk/owner" | A lane left the seam-economics placeholders unfilled | Fill real values: `thread=yes|no`, `risk=low|med|high`, `owner=<stream>` (H1/H2/H3). The unfilled `<yes|no>` placeholder does not count. |
| A leg needs more than one context window to build | The leg is too big | Split it: one leg = one build-order step + one proving-test cluster. Bigger is two legs. |
| Every leg in a lane maps to exactly one task-spec | The leg level is redundant there | Fold: legs are not a quota. If leg == task everywhere, keep the pieces and drop the extra naming layer for that lane. |
| A leg carries an `eval:` or a query body | Altitude leak at leg level | The leg keeps the *responsibility* and *what the eval must assert* in prose; the runnable eval is born at Pass 5 inside the task-spec. |

## Notes

- **Why this order.** Seams first (Step 1), then plan the contents (Step 2), then ground against the ADRs (Step 3). Planning contents before naming the seam enshrines a boundary you haven't justified; grounding before planning has nothing to check.
- **The seam is a contract, not a suggestion.** The published-output interface is owned by the upstream lane and consumed by the downstream lane. Naming it here is what lets Pass 4 attack it and Pass 5 build both lanes against a frozen shape.
- **"Seam" here ≠ Feathers' seam (H6).** Michael Feathers' *seam* (Working Effectively with Legacy Code) is a place you can alter behavior *for testing* without editing there. Converge repurposes the word for a **decomposition boundary** — a nameable interface with a one-way dependency — closer to a module interface or bounded context. Same word, deliberately different construct; don't expect the testability meaning.
- **Why "leg" and not "stage".** In a relay race each swimmer runs one leg of the lane — the metaphor keeps the swimlane vocabulary coherent: a big lane subdivides into sequential stretches that hand the baton forward. "Stage" was rejected: it collides with staging area, deploy stage, and dbt staging.
- **Plans are attacked, not shipped.** Pass 3 output is deliberately un-hardened. It is *supposed* to have soft spots that Pass 4's adversary finds. Do not over-polish or pre-empt objections into the plan; that hides the seams the review needs to test.

## Handoff

→ **`sketch-plans-adversarial-review`** (Pass 4, CONSENSUS). It consumes the `swimlanes/*.plan` files produced here and attacks them **one at a time, leg by leg** — hunting unjustified seams, missing dependencies, plans that contradict an ADR, legs that fail the independence or fold tests, and any altitude leak into task or code detail — sharpens them in place (the diff is the record, objections cite leg IDs), and — at **the barrier** — the owner signs off before the work crosses to task-driven decomposition (Pass 5, `task-spec`, which cuts tasks per leg, 1:N).

*Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches what this pass just produced — every component, the decision it encodes, what breaks downstream without it — before the descent continues.
