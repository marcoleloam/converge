# Installation

Converge 0.2.1 accepts Task-Spec **3.8.x or 3.9.x** for every install. Seamwise **0.2.x**
is required only for `cvg decompose` and `cvg compose`. Document memory needs
Node.js >=22.17 and npm; the npm door and Cockpit also require Node.

The installer writes the native `converge` entry and eleven method skills. It
never copies a Task-Spec or Seamwise implementation into the consumer.

## Requirements

- Git
- Bash 3.2 or newer
- Python 3
- Task-Spec 3.8.0 (`0e6180cfc3009bd4ef9cf7ab050b463e10d4af91`)
- Seamwise 0.2.0 (`5a398169c3fefcb65eb1a47c0cb4f967dfdc0515`) for compose
- Node.js >=22.17 and npm for document memory (Node is also needed for npm / Cockpit)

Task-Spec 3.9.x is accepted. `cvg` passes the physical workspace and backlog
paths, so `rebuild-state` keeps `path:` repo-relative instead of embedding a
home directory when `/tmp` and the Git toplevel disagree.

## Install in dependency order

```bash
git clone --branch v3.8.0 https://github.com/luanmorenommaciel/task-spec.git
bash task-spec/install.sh --global --copy
taskspec demo

python3 -m pip install \
  "git+https://github.com/luanmorenommaciel/seamwise.git@v0.2.0"

git clone --branch v0.2.0 https://github.com/luanmorenommaciel/converge.git
bash converge/install.sh --target /absolute/path/to/your-project --copy
```

Other Converge doors:

```bash
npm install -g github:luanmorenommaciel/converge
cvg-install
```

```bash
CVG_REF=v0.2.0 bash -c "$(curl -fsSL \
  https://raw.githubusercontent.com/luanmorenommaciel/converge/main/install.sh)"
```

`install.sh` fails if `taskspec` is missing or outside 3.8.x–3.9.x. Copy mode pins
coordinator, contracts, templates, skills, and the internal memory module with
its lockfile and license into the consumer. It does not vendor the engines or
copy `node_modules`.

## Pin the binaries you intend

```bash
export CVG_TASKSPEC_BIN=/absolute/path/to/task-spec/bin/taskspec
export CVG_SEAMWISE_BIN=/absolute/path/to/seamwise/bin/seamwise
```

Without the overrides, `cvg` resolves `taskspec` and `seamwise` from `PATH`.
A nested `cvg` call that forgets the override can pick a different engine on
`PATH` — prefer the absolute `CVG_*_BIN` form.

## Set up project memory

Native memory and `/skill:converge` are unreleased additions in this checkout.
Install the current source checkout rather than the older release tag above:

```bash
bash /path/to/this-checkout/install.sh --target /absolute/path/to/project --copy
cd /absolute/path/to/project
cvg setup memory
cvg memory status
```

`setup memory` explicitly installs the locked module dependencies, initializes
a vault, or migrates an existing darkfactory binding. An existing native binding
is refreshed, never rebound. `--vault /absolute/path` selects a new vault only
when no binding exists; a different bound path is rejected.

Migration keeps the same external vault and project identity, backs up legacy
metadata under `.cvg/memory/migration-backup/`, and preserves notes and historical
records. `cvg memory migrate` is also available when dependencies are already
installed. Binding, source manifest, and index are local under `.cvg/memory/`.
Plain `cvg setup` and `cvg memory status` are read-only and never install
dependencies. Memory does not require a signing key or authorize execution.

## What got installed

| Harness | Skill destination |
|---|---|
| Codex / Kimi | `.agents/skills/<skill>/` |
| Claude Code | `.claude/skills/<skill>/` |
| Grok Build | `.grok/skills/<skill>/` |

The native entry plus eleven method skills. No `skills/task-spec/`. No Seamwise sources.

For local development of this repository, `make bootstrap` clones the pinned
engine commits under gitignored `.engines/`, prepares `.venv`, and installs the
locked memory dependencies. That is a test pairing, not a shipped engine.
