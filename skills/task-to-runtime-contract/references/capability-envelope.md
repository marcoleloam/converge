# The capability envelope — task-scoped authority that closes

Bind's central claim is not "the agent was told what it may touch." It is:
**authority is granted against one signed revision, scoped to that revision's own
paths, and revoked the moment the task settles.**

That sentence exists because of a failure the field named in 2026: **lingering
authority**. Coding-agent CLIs grant permissions for a *session*. A session
outlives a task. So write access granted for task A is still held while task B
runs — nobody revoked it, because nothing in the model knows a task ended. Audits
of the major CLIs found no epoch-bound handles and no closure predicates: there is
no way to say *"grant write to `db/migrations/` until this migration finishes,
then take it back."*

Bind is that missing sentence, made machine-checkable.

---

## 1. The epoch

```
epoch = <task-id>@<first 12 hex of the signed spec's sha256>
```

An epoch names **one task at one revision**. Change a byte of the spec and the
epoch changes, which means every grant derived from it is void. The gate does not
warn about a stale epoch — it fails:

```
authority epoch does not match the signed spec revision
(T-x@aaaa != T-x@bbbb) — re-bind to mint a new epoch
```

This is why re-binding is cheap and mandatory: a new epoch is the *only* way to
obtain authority, and obtaining it re-runs every check.

## 2. The grants

Each grant is a capability, whether it is granted, the scope it is granted over,
and the phase it is live in. Scope is never invented — `fs.write` is exactly the
Task-Spec's `touches_paths + creates_paths`, and its `deny_scope` is exactly the
spec's Do-Not-Touch section. Bind derives; the Task-Spec decides.

| capability | default | scope source |
|---|---|---|
| `fs.read` | granted | the repository |
| `fs.write` | granted | `touches_paths + creates_paths`, minus Do-Not-Touch |
| `proc.exec` | granted | the spec's own evaluations |
| `net.egress` | **denied** unless `requires.network` | — |
| `vcs.commit` | granted | the write scope |
| `vcs.push` | **denied** | — |
| `tracker.write` | **denied** | — |

Denied-by-default is deliberate: the loop's job is a green eval and a diff, not
reaching the internet or publishing on its own recognizance.

## 3. The closure

```json
"closure": {
  "revoke_on": ["settle", "block", "budget_exhausted", "epoch_change"],
  "revocation_is_mandatory": true,
  "lingering_authority": "denied"
}
```

Four events end an epoch: the task settles, it blocks, it exhausts its budget, or
its spec changes underneath it. The gate rejects any profile whose closure is
non-mandatory or misses an event — a contract that grants authority without
promising to take it back is not a contract.

---

## 4. Prevent vs detect — the distinction that carries the weight

A control can be held two ways, and conflating them is how "secure" harnesses get
written:

- **prevent** — a kernel primitive or pre-tool hook refuses the action. The
  agent's intent is irrelevant; the syscall does not happen.
- **detect** — a portable postflight guard notices afterwards. This is *evidence*,
  not a boundary. It is real and useful, and it will not stop a determined or
  injected agent mid-flight.

The field's warning is blunt: application-layer filtering is precisely what prompt
injection is built to bypass, so a `detect`-only story collapses exactly when it
is needed. Kernel-enforced rules survive injection because the process *cannot*
make the syscall regardless of what it was told.

Bind therefore never reports a single "secure/insecure" bit. It reports, per
runtime and per capability, which of the two you actually have — and the
profile's `assurance` field is the honest headline: **the weakest required
control on the primary runtime.**

## 5. The resolver manifest

Every adapter declares what it did with each control:

| status | meaning |
|---|---|
| `handled` | the runtime **prevents** it |
| `mapped` | the runtime only **detects** it — weaker than asked |
| `ignored` | the runtime **cannot honor** it at all |

```json
"controls": {
  "fs.write": {
    "status": "mapped",
    "enforcement_kind": "detect",
    "mechanism": "workspace sandbox bounds writable roots; whole-repo postflight enforces Task-Spec subpaths"
  }
}
```

This mirrors the resolver contract emerging in the agent-manifest work: a resolver
must state which directives it handled, which it mapped to weaker behavior, and
which it ignored — so the gate can refuse to pretend.

Current matrix (what each runtime genuinely provides):

| capability | generic | claude | codex | kimi | omp |
|---|---|---|---|---|---|
| `fs.write` | detect | detect | detect | detect | detect |
| `proc.exec` | — | **prevent** | **prevent** | — | — |
| `net.egress` | — | **prevent** | **prevent** | — | — |
| `vcs.push` | detect | detect | **prevent** | detect | detect |

*Claude:* Bind emits a valid PreToolUse settings fragment whose hook returns
`permissionDecision: "deny"` for disallowed Edit/Write/NotebookEdit paths. That
is prevention only after a dispatcher installs the fragment, and Bash remains a
broader write surface, so the profile's guaranteed task-scope assurance stays
**detect**. *Codex:* the workspace sandbox can prevent writes outside its
writable roots, but it does not natively narrow those roots to Task-Spec
subpaths; that finer boundary is also **detect** at postflight. Generic/Kimi/OMP
likewise use the portable postflight. OMP is a `cvg loop` engine adapter, not
TaskMesh; it has no prevent-level FS or network sandbox in this integration, and
there is no OMP judge recipe. `cvg doctor runtime-contract --runtime omp` FAILs
when the `omp` binary is missing. The table reports the guarantee the
generated profile actually wires, not the strongest feature a vendor could
provide in a separately configured environment.

## 6. Fail closed, or waive it in the open

`fs.write` is always required. Anything else becomes required with `--require`:

```bash
cvg bind --task tasks/T-x.md --runtime codex --require net.egress   # PASS: seccomp blocks it
cvg bind --task tasks/T-x.md --runtime generic --require net.egress # FAIL: nothing can enforce it
cvg bind --task tasks/T-x.md --runtime omp --require net.egress     # FAIL: detect-only, like kimi
```

The failure is the feature:

```
runtime 'generic' cannot enforce required control(s): net.egress —
select a runtime that can, drop the requirement, or waive it explicitly
```

Three honest exits, no silent fourth. If you must proceed anyway, the waiver is
recorded in the profile and announced on every check:

```bash
cvg bind ... --require net.egress --accept-unenforced net.egress
# WAIVED: 'net.egress' is required but unenforced on 'generic'
#         — accepted by explicit operator approval
```

`assurance` then drops to `unenforced`, permanently, in the committed artifact.
Accepting risk is allowed; hiding it is not.

## 7. Attesting the host

An adapter says what a runtime *should* do. `cvg doctor runtime-contract` probes
what this machine *can* do — isolation primitive (Seatbelt / Landlock /
bubblewrap), whether the runtime binary exists, whether git worktrees work:

```bash
cvg doctor runtime-contract --runtime codex
# isolation   seatbelt — macOS Seatbelt via sandbox-exec
# binary      /usr/local/bin/codex
# worktree    git worktree usable
# DOCTOR_RUNTIME_CONTRACT=OK
```

Verdicts are `OK`, `DEGRADED` (claims `prevent`, can only prove `detect`), or
`FAIL` (the runtime is not installed). Probes are deliberately conservative: a
capability that cannot be proven is reported absent, because optimism here is the
whole bug.

---

## Why this is the durable part

Isolation primitives are being absorbed by the runtime vendors — Codex sandboxes
by default, Anthropic open-sourced its sandbox runtime, and standalone wrappers
are going dormant. Building another sandbox is building a commodity.

What is *not* commodity is the part above it: **which authority, over which paths,
for which revision, until when, and provably enforced by what.** Bind does not
compete with the sandbox. It is the contract the sandbox executes — and the record
that says, honestly, how strong that execution actually was.
