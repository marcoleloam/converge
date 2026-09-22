# Five-minute reviewer route

This route separates an installed-product check from source and retained
evidence. It is for reviewers who want to falsify the claims rather than trust
a badge.

## 1. Prove the engines resolve

```bash
taskspec version
seamwise --version
cvg version
cvg doctor host
```

`taskspec version` must be 3.8.x or 3.9.x. `seamwise --version` must be 0.2.x.
`cvg doctor host` reports the coordinator, not the engines' internal suites.

## 2. Prove compose is read-only until you ask

```bash
cvg compose status
cvg --json compose status
```

Status never mutates. A workspace without a prepared plan is
`COMPOSE=BLOCKED`. A missing or incompatible binary is
`COMPOSE=ENGINE_UNAVAILABLE`. Branch on `token`, not prose.

## 3. Run the local repository gate

From a Converge checkout with the pinned pairing:

```bash
make bootstrap
make check
```

`make check` is `check-core`, `check-json`, `check-docs`, `check-composed`, and
`check-package`. A hosted job that starts zero steps is not equivalent
evidence.

`tests/test-package.sh` asserts the npm pack contains eleven Converge skills
and **does not** contain `skills/task-spec/` or a Seamwise implementation.

## 4. Read the retained live-executor evidence

```bash
ls evidence/releases/v0.2.0/live-codex/
```

That directory is a composed Codex settlement of
`T-20260815-health-status`. The settlement transcript records
`tier 2: off`. It proves the coordinator path against the published engine
commits. It does **not** prove a live cross-family UPHELD/REFUTED pair in
this tree.

Directories under `evidence/` whose names begin with `invalidated-` are audit
history, not release proof.

## 5. Recalculate what you actually saw

| Evidence class | What it proves | What it does not prove |
|---|---|---|
| `cvg version` + `doctor host` | The coordinator is installed | That engines are compatible |
| `compose status` | Current compose state, read-only | That a human should accept the plan |
| `make check` | Hermetic suites passed on this checkout | Hosted CI or a stranger's install |
| `evidence/releases/v0.2.0/live-codex/` | One composed leaf settled with Codex, tier 2 off | Hidden holdouts or fleet dispatch |
| Composition receipt | Engine versions, source commit, digests, `dispatch_authorized: false` | That any leaf was authorized |

See [trust](../trust/index.md) before treating a green loop as independent
verification.
