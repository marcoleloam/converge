---
name: task-to-runtime-contract
description: Bind one signed Converge Task-Spec to an enforceable, task-scoped runtime contract, and emit the task brief the worker reads. Use for Pass 7 · Bind (7A contract + 7B brief), after Pass 6 Register (opt-in) and before task-loop executes the issue, when the executor needs a hash-bound evidence slice, explicit topology, portable path guards, vendor adapter manifests, a task-scoped brief, pinned documentation, and a deterministic CHECK_RUNTIME_CONTRACT verdict. Replaces the legacy standing-agent-fleet harness workflow; do not use to author Task-Specs, select work across tasks, or execute the task.
metadata:
  version: "0.2.1"
---

# task-to-runtime-contract — Pass 7 · Bind (7A contract + 7B brief)

Turn one signed Task-Spec into the smallest enforceable runtime contract needed
to execute it. The Task-Spec remains canonical; the execution profile records
only derived evidence, net-new topology decisions, hashes, and enforcement
artifacts.

## Boundary

- **Pass 5 (`task-spec`) owns** behavior, evaluations, write scope, budgets,
  backend hints, and sign-off.
- **Pass 6 (`task-specs-to-issues`, opt-in) owns** the 1:1 projection of signed
  specs onto tracker issues and the dependency links between them.
- **Pass 7 (this skill) owns** evidence binding, initial intra-task topology,
  pinned context, enforcement adapters, the emitted harness, and readiness.
- **The Manager owns** task selection and concurrency across tasks. It is a
  future CI/CD concern (e.g. GitHub Actions), **not a numbered pass and not an
  in-session skill** — tracked on the project roadmap.
- **Pass 8 (`task-loop`) owns** one assigned task, its bounded RED/GREEN loop,
  and one PR or blocked report.

Never copy Task-Spec fields into a second competing contract. Point back to
their canonical field names and bind the source file by SHA-256.

## Workflow

### 1. Resolve and verify the task

Require one runnable leaf Task-Spec. Run the existing sign-off gate. Tier 1 is
the default; use `--supervised` only when a human will remain in the execution
loop.

```bash
cvg bind --task tasks/T-YYYYMMDD-example.md
```

Stop on an unsigned task, invalid eval, decomposition node, or failed signature.

### 2. Select the initial topology

Default to `single`. Escalate only for a static reason visible before runtime:

- `single-explorer`: broad read-only discovery would pollute implementation
  context.
- `implementer-verifier`: independent verification is required by risk or
  acceptance policy.
- `parallel`: at least two disjoint write partitions exist.

Every non-single topology requires a concrete justification. Parallel mode also
requires explicit, non-overlapping worker ownership declarations. See
[`references/topology-and-permissions.md`](references/topology-and-permissions.md).

### 3. Bind only the evidence required for this task

The binder automatically includes cited ADR paths. Add project knowledge or
external documentation only when the task needs it:

```bash
cvg bind \
  --task tasks/T-YYYYMMDD-example.md \
  --knowledge cvg/knowledge/failures/postgres-locking.md \
  --doc https://example.dev/v1/reference=cvg/knowledge/references/example-v1.md
```

External documentation must have a local cached copy. The profile records its
URL and content hash so offline and version-pinned execution remain possible.

### 4. Generate and gate

The command writes:

```text
cvg/execution/<task-id>/
├── execution-profile.yaml
└── adapters/
    ├── generic.json
    ├── claude.json
    ├── codex.json
    └── kimi.json
```

`execution-profile.yaml` uses the JSON subset of YAML 1.2 so every consumer can
parse it with a standard JSON parser. Run the gate again at any time:

```bash
cvg bind --check --task tasks/T-YYYYMMDD-example.md
```

The final line is exactly:

```text
CHECK_RUNTIME_CONTRACT=PASS
```

or:

```text
CHECK_RUNTIME_CONTRACT=FAIL
```

### 4b. Choose the runtime that must actually hold the contract

The profile carries a **capability envelope**: authority granted against one
signed revision (`epoch = <task-id>@<spec-sha12>`), scoped to the Task-Spec's own
paths, and **revoked on settle, block, budget exhaustion, or epoch change**. That
closure is what prevents *lingering authority* — session-scoped permissions that
outlive the task that justified them.

Each adapter then declares, per capability, whether the runtime **prevents** the
violation (kernel or pre-tool hook), only **detects** it (portable postflight), or
**cannot honor it** at all. `fs.write` is always required; add more with
`--require`:

```bash
cvg bind --task tasks/T-x.md --runtime codex  --require net.egress   # PASS — seccomp blocks egress
cvg bind --task tasks/T-x.md --runtime generic --require net.egress  # FAIL — nothing enforces it
```

A required control the runtime cannot enforce **fails the gate closed**. Proceed
anyway only in the open:

```bash
cvg bind ... --require net.egress --accept-unenforced net.egress
# WAIVED: 'net.egress' is required but unenforced on 'generic'
```

The waiver is written into the profile and `assurance` drops to `unenforced`.
Attest what this host can genuinely do before trusting a claim:

```bash
cvg doctor runtime-contract --runtime codex   # → DOCTOR_RUNTIME_CONTRACT=OK|DEGRADED|FAIL
```

Full model: [`references/capability-envelope.md`](references/capability-envelope.md).

### 4c. Emit the task brief (7B)

7A is what the RUNTIME enforces. **7B is what the MODEL reads** —
`cvg/execution/<task-id>/AGENTS.task.md`, written by the same bind:

- the spec path, the contract path, the **epoch**
- the exact paths it may write, and the fences it must never cross
- the Exit Check — *done is this command exiting zero, not your judgement*
- boundaries (network/external writes) and the enforcement strength
- a pointer to the project router — **never a copy of it**

It carries **identifiers, not content**. Auto-generated context measurably lowers
task success (~3%) while raising cost (>20%), and every token here competes with
the work, so the brief states only what a worker cannot infer and lets it fetch
the rest just-in-time. The gate rejects a brief that has drifted from the epoch.

The project's durable doctrine lives in ONE router (`AGENTS.md`, ~50 lines),
scaffolded once by `cvg setup harness` and owned by a human — cvg never writes
doctrine.

### 5. Enforce during execution

Before writes, vendor hooks may pass a candidate path to:

```bash
python3 skills/task-to-runtime-contract/scripts/check-path-policy.py \
  --profile cvg/execution/<task-id>/execution-profile.yaml \
  --candidate path/to/file
```

Before settlement, always run the same guard against the git diff:

```bash
python3 skills/task-to-runtime-contract/scripts/check-path-policy.py \
  --profile cvg/execution/<task-id>/execution-profile.yaml \
  --base origin/main
```

The portable settlement gate is mandatory even when a vendor supplies a
stronger pre-tool hook or sandbox.

### 6. Accrete earned knowledge

Pass 8 writes a structured execution receipt through
`write-execution-receipt.py`. A receipt may then produce a proposed knowledge
candidate:

```bash
python3 skills/task-to-runtime-contract/scripts/propose-knowledge-candidate.py \
  --profile cvg/execution/<task-id>/execution-profile.yaml \
  --receipt cvg/receipts/<task-id>.json \
  --kind failure \
  --summary "The stable, project-specific lesson" \
  --evidence "The exact receipt-backed observation"
```

Candidates remain under `cvg/knowledge/candidates/`. They never become
canonical without owner or reviewer promotion. `pass-to-lesson` remains the
human teaching projection, not the machine-knowledge writer.

## Gate checklist

- The Task-Spec is a signed runnable leaf and its current hash matches.
- Required ADRs, approved knowledge, and cached external docs exist and match
  their recorded hashes.
- A non-single topology has a substantive static justification.
- Parallel write ownership is explicit, in scope, and disjoint.
- Portable guards and all declared adapter manifests exist.
- Generated artifacts contain no unresolved placeholders.
- The capability envelope is epoch-bound to the current spec hash, its `fs.write`
  grant equals the Task-Spec's declared scope, and closure is mandatory.
- Every required control is at least detectably enforced by the primary
  runtime, or explicitly waived — and the declared `assurance` matches what the
  resolver proves. A profile never upgrades `detect` to `prevent` merely because
  the vendor has an optional hook or workspace-wide sandbox.
- The 7B task brief exists and carries the current epoch.
- `bind --check` performs **zero repository writes** and runs no project code.
- The final machine token is `CHECK_RUNTIME_CONTRACT=PASS`.

## References

- [`references/verification.md`](references/verification.md) — tier-2 adversarial
  verification, holdout evals, and what happens with no second engine.
- [`references/capability-envelope.md`](references/capability-envelope.md) —
  epoch-bound authority, closure, prevent-vs-detect, and the fail-closed
  resolver manifest.
- [`references/runtime-contract.md`](references/runtime-contract.md) — profile
  schema, freshness, and evidence rules.
- [`references/topology-and-permissions.md`](references/topology-and-permissions.md)
  — topology choices, capability classes, and enforcement.
- [`references/vendor-adapters.md`](references/vendor-adapters.md) — portable
  core versus Claude, Codex, and Kimi adapter responsibilities.
- [`references/knowledge-accretion.md`](references/knowledge-accretion.md) —
  candidate and promotion boundary.
