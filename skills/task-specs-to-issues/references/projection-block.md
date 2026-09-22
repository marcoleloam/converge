# The `projection:` block — per-spec tracker enrichment

`register.sh` projects a signed-off spec onto a tracker as **one issue**. Beyond
the title, body, labels, estimate and due date it derives from the envelope, a
spec may carry an optional **`projection:` block** in its frontmatter that seeds
a tracker's *native* fields — assignee, workflow state, subscribers, cycle,
parent, SLA — and places the issue into a project/milestone.

The block is **tracker-neutral**. The Linear adapter consumes it; `github.sh` /
`jira.sh` / `fake.sh` **accept-and-discard** every field, so a spec that projects
richly onto Linear still registers unchanged on a GitHub or Jira board — the
enrichment simply degrades to nothing. This is the portability guarantee.

## Shape

The block lives in the frontmatter and its keys are **indented**:

```yaml
---
id: T-20260723-auth-revamp
signed_off: true
depends_on: [T-20260723-auth-schema]
execution_backend: claude          # → assignee (via identity)
agent: python-developer            # → assignee (more specific; wins over backend)
signed_off_by: luan@owshq.com      # → subscribers
projection:
  project: "Auth Revamp"           # structural — honored only when projection is enabled
  milestone: Transform             # structural — the phase within the project
  cycle: "Cycle 7"                 # non-structural — placed every register
  parent: T-20260723-auth-schema   # non-structural — a SPEC id, resolved to its issue
  sla: standard                    # non-structural — paid-plan feature; fail-soft
  # template / use_default_template — accepted, but NOT yet applied on Linear (deferred)
---
```

Read it with `tsi_projection FILE KEY` / `tsi_projection_keys FILE` (see
`scripts/_parse.sh`). Both stay strictly inside the block: they arm on a column-0
`projection:` line, read only its indented children, and disarm at the next
column-0 line — so a body key or a sibling top-level field is never mistaken for
a projection value. Dequoting/decommenting mirrors `tsi_field` exactly.

## Why indented, and why frontmatter-only (HMAC safety)

The Tier-1 sign-off HMAC seals `id + body_digest + signed_off*`, where
`body_digest` is the sha256 of everything **after** the closing `---`. So:

1. The block is **frontmatter** → it stays *outside* `body_digest`. You can add
   or edit a `projection:` block on an already-signed spec without breaking the
   seal — enrichment is not part of what was signed.
2. Its keys are **indented** → none of them sits at column 0, so none can shadow
   the envelope anchors the seal reads (`^id:`, `^signed_off:`, `^signed_off_by:`,
   `^signed_off_at:`, all `grep -m1`). The board reads the block the same way the
   seal skips it, so the two never disagree.

## Fields, and who owns each

Every field is **optional** and **fail-soft**: an unresolved value is omitted and
the registration proceeds — a cosmetic projection field must never break a write.
Ownership follows the same derived-vs-seed-once split as labels/priority:

| field | source | ownership | Linear native field |
|-------|--------|-----------|---------------------|
| assignee | `execution_backend` / `agent` → [identity](./identity.md) | **seed-once** (create only) | `assigneeId` |
| state | DAG position — root → `Todo`, blocked → `Backlog` | **seed-once** (create only) | `stateId` |
| subscribers | `signed_off_by` (comma/space separated) | **union-merged** (never drops a human) | `subscriberIds` |
| `projection.cycle` | the block | re-synced | `cycleId` (name / number / uuid) |
| `projection.parent` | the block (a SPEC id) | re-synced, depth-guarded | `parentId` (+ `subIssueSortOrder`) |
| `projection.sla` | the block | re-synced | `slaType` |
| `projection.project` | the block, else config | **structural — gated** | `projectId` |
| `projection.milestone` | the block | **structural — gated** | `projectMilestoneId` |

`assignee`/`state` are **seed-once**: the adapter applies them on `issueCreate`
only, so a re-register never re-assigns or re-opens an issue the loop has since
moved — the board owns them after create. `subscribers` **union-merge**: the
adapter reads the issue's current subscribers and adds to them, so a human who
subscribed on the board is never dropped.

### The two hard rules

- **Parent is two hops.** The factory tree is macro (intent + brainstorm) →
  swimlane → task. A swimlane may be a sub-issue of the macro and still parent
  a task. A task may not parent another issue. `_ln_parent_depth_ok` refuses
  that third hop. A not-yet-registered parent is a fail-soft skip, not an error:
  register upserts in build order, so a declared parent is normally already on
  the board by the time its child is projected.
- **Structural fields are gated.** `project` and `milestone` *create* tracker
  structure, so they are honored **only when structure projection is enabled**
  (`cvg setup projection --enable`). With it off (the default), a plain
  `cvg register` never creates a Project or Milestone and is byte-identical to a
  run with no block at all — the non-structural fields (cycle/parent/sla) are
  still honored. See [structure projection](#structure-projection-t3) below.

## Structure projection (T3)

When enabled, register runs a **Step-0 pre-pass** before the upsert loop that
ensures the run's structure top-down, **idempotently by name** (a re-run resolves
the same objects and never duplicates — Linear caches the mapping in
`.cvg/projection.lock`; the fake adapter derives a deterministic id from the
name):

```
Initiative  →  Project  →  phase Milestones
(optional)     (required)   (Capture, Transform, Serve by default)
```

The run-wide project (from `.cvg/config`, written by `cvg setup projection`) is
the default placement for every issue in the run; a per-spec `projection.project`
overrides it, and `projection.milestone` picks the phase within whichever project
applies. After the issues are written, register posts **one append-only health
note** to the project — a breadcrumb that this signed-off batch was projected.

Enable it with:

```
cvg setup projection --enable --project "Auth Revamp" --initiative "Q3 Delivery"
```

Off by default. GitHub/Jira degrade the structure verbs to no-ops, so enabling
projection never breaks a non-Linear board.

## Deferred: `template`

`template` / `use_default_template` are **accepted everywhere for forward-compat
but not yet applied on Linear** — a `templateId` must be set at `issueCreate`
time, which needs a name→id resolver this tier does not ship. The Linear adapter
emits a one-line `note:` when a template field is present so a spec author knows
it was a no-op rather than silently lost.
