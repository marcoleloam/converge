---
name: task-specs-to-issues
description: Converge Pass 6 (Register) — optional, like Capture (Pass 0). Register a backlog of signed-off Task-Specs (tasks/T-*.md) as tracker issues — one issue per task-spec, with blocked-by links carrying the dependency graph — so the execution loop reads a board instead of repo files. The tracker is a pluggable backend behind a six-verb adapter (preflight · upsert · link · list-ready · list-issues · write-result), selected by --tracker github|linear|jira (default linear), never baked into the name. After each upsert it stamps a tracker_ref backlink back into the spec (the issue-side marker stays the idempotency key). Use when the user says register the tasks, push tasks to Linear, push tasks to GitHub issues, task-specs to issues, or bridge the backlog onto a tracker. Skip it to keep the queue repo-local in tasks/. Not for authoring tasks (that is Pass 5 task-spec) and not for running them (that is Pass 8 task-loop).
metadata:
  version: "0.2.1"
---

# task-specs-to-issues — Pass 6 · Register (opt-in)

The one-way bridge that projects repo-local Task-Specs onto a tracker board the execution loop can read. It creates exactly one issue per `signed_off` task-spec and encodes each `depends_on` edge as a `blocked-by` link, so the board carries both the work and its dependency graph. The tracker is a pluggable backend selected by `--tracker {github|linear|jira}` (default `linear`); the skill never bakes a tracker into its name.

- **Converge Pass:** 6 of 8 — Register. **Optional**, like Capture (Pass 0): run it when you want a shared, visible board; skip it to keep the queue repo-local in `tasks/`. The Loop (Pass 8) reads either.
- **Altitude:** projects sideways, lowers nothing. Pass 5 (`task-spec`) already set the altitude (atomic, eval-bearing tasks); this pass shadows them onto a durable surface.
- **Gate:** the 1:1 mapping holds and the graph is faithful — `count(issues) == count(signed_off specs)`, every `depends_on` edge is one `blocked-by` link, no orphans, no cycles.

## Important

- **Register ONLY `signed_off: true` specs.** An un-gated spec on the board would shadow work that is not safe to delegate. Skip and report any spec with `signed_off: false`.
- **The projection is one-way for the WORK: task-spec → issue.** The board never edits the spec's work back. If the board and `tasks/*` ever disagree on what the work IS, the spec wins and the board is re-registered. The spec is the floor, exactly as Postgres is the floor below `raw.*` in this repo. (The one write back into a spec is a *receipt*, not work — see the next bullet.)
- **Idempotent by design.** Re-running must not create duplicate issues. Every adapter keys on the spec `id` (an external ident / title-tag / label), finds an existing issue first, and updates it instead of creating a second.
- **The receipt is stamped back, but the marker is the key.** After a successful upsert, register writes `tracker_ref: <tracker>:<issue>` into the spec's frontmatter — a convenience backlink so a human or agent can jump spec→issue. This is the ONLY write this skill makes to a spec, and it touches frontmatter *metadata* only: a signed-off spec's HMAC covers `id + body digest + signed_off*`, so the seal survives the stamp. Critically, the **issue-side marker — not `tracker_ref` — is the idempotency key**, so resolution still works when the receipt is `(none)` (e.g. a CI run that must not write to the repo). Disable with `--no-stamp-refs`. (SOTA-grounded: workplans #62's `tracked_in` contract, sdlc-bridge / spec-kit frontmatter write-back.)
- **The eval travels onto the board.** Copy the spec's Exit Check (or Success Criteria) into the issue body verbatim — it is the close condition, and only a green eval may move an issue to done. That single rule is why the board never lies.
- **Only the loop writes result state.** Registration only ever creates/updates the shadow. Pass 8 (`task-loop --issue N`) writes result — failure-as-comment on a red eval, a linked PR on a green one. The Manager/fan-out that picks WHICH ready issue to run, and when, is future CI/CD (GitHub Actions), not an in-session skill.

## Instructions

### Step 1 — Collect the signed-off backlog

Read `tasks/T-*.md`. For each spec, parse the frontmatter fields the bridge needs:

| Field | Use |
|-------|-----|
| `id` | the idempotency key — becomes the issue's external ident / title tag |
| `title` | issue title |
| `signed_off` | gate — register only when `true` |
| `depends_on` | the dependency edges → `blocked-by` links (a YAML inline list, e.g. `[T-a, T-b]`) |
| `severity`, `priority`, `effort` | labels / metadata on the issue |

Build a table of `{id, title, signed_off, depends_on[]}`. Drop every spec where `signed_off != true` and list what you dropped. Refuse the whole run if the remaining set contains a `depends_on` cycle (a registration failure, not a board state) — run the bundled `scripts/register.sh --dry-run` which detects cycles before any write.

### Step 2 — Bind the tracker adapter

Pick the backend from `--tracker {github|linear|jira}` (default `linear`; a no-network `fake` backend backs the offline test suite). Each adapter is the same **six-verb** contract behind one CLI (`preflight · upsert · link · list-ready · list-issues · write-result`); the loop itself needs only two of them:

- **read ready** — `adapter list-ready` → issues with no open `blocked-by` (what the loop pulls).
- **write result** — `adapter write-result --issue N --status {pass|fail} ...` (what the loop writes; not used during registration).

Registration additionally uses the adapter's `upsert` and `link` verbs, and the parity gate (`verify-registration.sh`) uses the read-only `list-issues` verb. Confirm the backend is reachable before writing: `scripts/adapters/<tracker>.sh preflight` (checks `gh auth status` for github, `LINEAR_API_KEY` for linear, etc.). If preflight fails, STOP and report the exact remediation — do not half-register a board.

### Step 3 — MIRROR: one spec → one issue (idempotent upsert)

Walk the signed-off specs in build order and `upsert` exactly one issue per spec via the adapter. The issue is the spec's **state shadow**:

- title = spec `title`
- body = the spec goal + `touches_paths` + the runnable Exit Check verbatim
- external key = spec `id` (github: `<!-- task-spec: T-... -->` marker + label; linear: title tag / external id; jira: a label + summary tag)

Upsert semantics: look up by the `id` key first; update if found, create if not. A spec with no issue is invisible to the loop; an issue with no spec is a lie. Never fan-out (1 spec ≠ 2 issues) and never merge (2 specs ≠ 1 issue).

After each upsert the driver stamps the returned issue ref back into the spec as `tracker_ref: <tracker>:<issue>` (the **receipt**), unless `--no-stamp-refs`. The receipt is a backlink for humans and agents, never the key — the next run still resolves by the issue-side marker, so a spec with `tracker_ref: (none)` registers exactly the same way.

**Native-field enrichment (Linear).** Beyond the shadow, register seeds a Linear issue's *own* fields from signal the spec already carries — assignee (from `execution_backend`/`agent` via [`.cvg/identity`](references/identity.md), seed-once), workflow state (root → `Todo`, blocked → `Backlog`, seed-once), subscribers (directly from `signed_off_by`, union-merged) — and honors an optional in-frontmatter [`projection:` block](references/projection-block.md) (cycle/parent/sla, plus project/milestone when structure projection is opted in via `cvg setup projection --enable`). It is **tracker-neutral and fail-soft**: github/jira/fake accept-and-discard every field, an unresolved value is omitted, and a plain `cvg register` with no identity and no block is byte-identical to the base projection.

### Step 4 — LINK: `depends_on` → `blocked-by`

For each spec, read its `depends_on` and set a `blocked-by` link from its issue to each dependency's issue (resolve dependency `id` → issue number via the same `id` key). The graph that lived in the repo now lives on the board, so the future Manager can compute "ready" (no open blockers) without reading `tasks/`. Mirror the build-order edges exactly — in this repo: `bronze-views` → `silver-conform` → {`gold-marts`, `gold-freshness`} → `gold-atomic-publish` → `api-fastapi` → `mcp-tools`. No extra links, no missing links.

### Step 5 — GATE: verify the mapping is faithful

Run `scripts/verify-registration.sh --tracker <tracker>`. It confirms, and you must confirm before leaving this pass:

- [ ] **1:1 mapping** — `count(issues) == count(signed_off specs)`; every spec ↔ exactly one issue and back.
- [ ] **Board mirrors the specs** — titles/bodies match; each issue carries the spec's Exit Check as its close condition.
- [ ] **blocked-by encodes `depends_on`** — every edge is one link; no extra, none missing, no cycles.
- [ ] **No un-gated registration** — only `signed_off` specs are on the board; un-stamped specs were skipped and reported.
- [ ] **Adapter contract live** — `adapter list-ready` returns the root(s) (specs with no open blocker) and only a green eval marks done.

When these hold, the board IS the backlog the loop reads — repo files and board agree, edge for edge. Report: issues created vs updated, links set, specs skipped (un-gated), and the ready set.

**The ready set is the frontier.** Because `blocked-by` is the tracker's
*native* dependency relationship, the board renders the frontier — open,
unblocked issues — visually in the tracker's own UI: a human sees what is
takeable without reading `tasks/` or the map. Every green-eval PR that closes
an issue advances the frontier automatically; that visual edge-of-the-known is
what the future Manager dispatches against, and it exists only if Step 4
mirrored the edges exactly.

## Examples

**Example 1 — "register the tasks on Linear"**
User says: *"register the tasks"* (no tracker named → default `linear`).
Actions: read `tasks/T-*.md` → 7 specs, 1 is `signed_off: true` (`bronze-views`), 6 are `false`. Preflight `LINEAR_API_KEY`. Upsert one Linear issue for `bronze-views`, no blockers (its `depends_on` is empty). Verify 1:1. 
Result: *"Registered 1 issue (bronze-views); skipped 6 un-gated specs: silver-conform, gold-marts, … Run the gate (safe-to-delegate) on those, then re-register."*

**Example 2 — "push all tasks to GitHub issues"**
User says: *"push tasks to GitHub issues --tracker github"*, and all 7 specs are now `signed_off`.
Actions: preflight `gh auth status`. Upsert 7 issues (each carries a `<!-- task-spec: T-... -->` marker + `task-spec` label). Link `silver-conform` blocked-by `bronze-views`; `gold-marts`/`gold-freshness` blocked-by `silver-conform`; `gold-atomic-publish` blocked-by both golds; `api-fastapi` blocked-by the three gold specs; `mcp-tools` blocked-by `api-fastapi`. 
Result: *"7 issues (created 7, updated 0), 9 blocked-by links, ready set = [bronze-views]. Board == backlog, edge for edge."*

**Example 3 — re-run (idempotency)**
User re-runs after editing one spec's title.
Actions: adapter finds each existing issue by `id` key and updates in place; the edited title is patched, no duplicates created. 
Result: *"7 issues (created 0, updated 1), links unchanged."*

## Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| `preflight failed: gh not authenticated` | No GitHub token in session | `gh auth login` (or set `GH_TOKEN`); re-run. Never half-register. |
| `preflight failed: LINEAR_API_KEY unset` | Linear adapter has no key | `export LINEAR_API_KEY=lin_api_...` (and `LINEAR_TEAM_ID`); re-run. |
| `refusing to register: dependency cycle A → B → A` | A `depends_on` loop in `tasks/*` | Fix the specs upstream (Pass 5). A cycle is a spec bug, not a board state. |
| `spec skipped: signed_off=false` | Un-gated spec | Run `safe-to-delegate.sh --stamp` on it (Pass 5 gate) first, then re-register. Expected for a partly-built backlog. |
| Duplicate issues appear on re-run | Adapter created instead of upserting | The `id` key marker/label was stripped from the issue. Restore it (github: the HTML comment marker; linear: the external id) so lookup matches. |
| `blocked-by target not found for T-x` | A dependency `id` isn't registered | Its spec is un-gated/skipped. Either sign it off and register, or the edge is stale — fix `depends_on`. |
| `verify: count mismatch (issues 8 != specs 7)` | An orphan issue or a double-registered spec | Re-run `register.sh` (idempotent) to converge; `verify-registration.sh --prune` flags orphans. |

## Handoff

The board this skill registers is the exact surface the execution loop reads.
Before dispatch, **`task-to-runtime-contract`** (Pass 7 · Bind) binds the linked
signed Task-Spec to its current evidence and guards, and emits the multi-engine
harness. A human or the Manager (future CI/CD, not a numbered pass)
then passes one ready issue to **`task-loop --issue N`** (Pass 8): it verifies
that execution profile, runs the eval to GREEN, checks the final diff against
the Task-Spec path policy, and opens one PR. Only the loop writes result state.

*Optional debrief:* **`pass-to-lesson`** (`cvg lesson`) teaches what this pass just produced — every component, the decision it encodes, what breaks downstream without it — before the descent continues.

## References

- `references/adapter-contract.md` — the six-verb adapter contract (`preflight · upsert · link · list-ready · list-issues · write-result`), the stdout/stderr discipline, the backend status table, and the ~40-line recipe for adding a new tracker.
- `references/dependency-graph.md` — how `depends_on` (YAML inline list) maps to `blocked-by`, cycle detection, and the repo's canonical build-order graph.
- `references/idempotency-keys.md` — how each tracker carries the spec `id` (github HTML marker + label, linear external id, jira label) so re-runs upsert instead of duplicate.
- `references/projection-block.md` — the optional per-spec `projection:` frontmatter block (assignee/state/subscribers + cycle/parent/sla/project/milestone): its HMAC-safety, the derived-vs-seed-once ownership split, and how structural fields gate behind `cvg setup projection`.
- `references/identity.md` — `.cvg/identity`, the local choices-not-credentials lookup that routes `execution_backend`/`agent` → a tracker identity for assignee seeding (keys, `agent → backend → default` precedence, fail-soft).
- `references/agents-api-scaffold.md` — the Linear Agents API (T4) scaffold + promotion runbook: the OAuth `actor=app` prerequisite, the four seams into code that already exists, and why it ships as a deliberately-inert scaffold.
```
