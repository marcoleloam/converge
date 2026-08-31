# cvg 0.2.1

`cvg` is the Converge composition coordinator and assurance referee. It
preserves the established command paths, delegates Task-Spec lifecycle
authority to the external Task-Spec 3.8 engine, and delegates reviewed
decomposition to external Seamwise 0.2 for `cvg compose`.

The canonical command list is
[../contracts/cli-command-matrix.json](../contracts/cli-command-matrix.json).
The generated human reference is
[../docs/reference/cli.md](../docs/reference/cli.md).

## Files

| File | Role |
|---|---|
| `cvg` | Bash 3.2-compatible stable router and universal JSON wrapper |
| `_ui.sh` | TTY-only presentation; color never carries meaning |
| `_cvg_compose.py` | Private subprocess coordinator for Seamwise and Task-Spec |
| `cvg-agent-context.py` | Renders agent context from the canonical matrix |
| `cvg-classify-lane.py` | Deterministic FAST, NORMAL, or FULL lane classifier |
| `cvg-snapshot.py` | Read-only WorkspaceSnapshot 3.0 builder |

The private coordinator imports neither external engine. It consumes their
versioned JSON envelopes and re-hashes their artifacts.

## Roots and executable overrides

- `CVG_HOME`: Converge tool package.
- `CVG_PROJECT_ROOT`: consuming project.
- `CVG_TASKSPEC_BIN`: exact Task-Spec executable.
- `CVG_SEAMWISE_BIN`: exact Seamwise executable for compose.
- `TASKSPEC_BACKLOG_DIR`: optional explicit backlog override.

Installed copy mode puts helpers and contracts under the consumer's
`.agents/` tree while putting the stable `cvg` executable on PATH.

## Compose

```bash
cvg compose prepare --source recipe.yaml
cvg compose review --reviewer "owner" --reason "accepted topology"
cvg compose preview
cvg compose materialize
cvg compose status
```

Stable tokens are `COMPOSE=NEEDS_REVIEW`, `COMPOSE=PREVIEW_READY`,
`COMPOSE=MATERIALIZED`, `COMPOSE=BLOCKED`, and
`COMPOSE=ENGINE_UNAVAILABLE`.

Prepare never reviews or compiles. Review never compiles. Preview writes only
the Seamwise TaskPlan and lineage projections, then calls `taskspec plan`.
Materialize calls `taskspec batch`, validates the receipt and task bytes, and
writes `ConvergeCompositionReceipt/v1` with `dispatch_authorized: false`.

## JSON contract

```bash
cvg help --json
cvg --json version
cvg agent-context --json
cvg compose --json status
```

Every public form emits one `ConvergeCLIResult/v1` document under `--json`.
The wrapper preserves the underlying exit code, strips ANSI, and records
`changed` and `dry_run`. Global flags are position-independent.

Without `--json`, wrapped gate output remains byte-compatible. Intrinsic
`cvg agent-context` is a JSON document; adding `--json` places it under
`data.agent_context` like every other command result.

## Failure posture

- Exit 0: command completed, including a read-only status that reports a blocked state.
- Exit 1: artifact or gate contract failed.
- Exit 2: usage error.
- Exit 3: required engine unavailable or incompatible.
- Exit 20-22: dispatch skip, timeout, or engine result error.

A composition receipt becoming stale is an exit-1 block. Reruns never repair a
changed task silently. An interrupted final receipt write is recoverable because
Task-Spec proves unchanged bytes before Converge writes its receipt last.

## Verification

```bash
make check-json
make check-composed
make release-check
```

The release still requires hosted macOS and Linux jobs to execute and pass on
the exact commit.
