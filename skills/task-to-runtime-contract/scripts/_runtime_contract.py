#!/usr/bin/env python3
"""Shared dependency-free helpers for Pass 6 runtime-contract scripts."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Iterable

SCHEMA = "cvg.execution-profile.v1"
VERSION = "1.0.0"
TOPOLOGIES = {"single", "single-explorer", "implementer-verifier", "parallel"}
PERMISSIONS = {"read-only", "scoped-write"}
SUPPORTED_RUNTIMES = frozenset({"claude", "codex", "kimi", "omp"})


class ContractError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relpath(path: Path, repo: Path) -> str:
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError as exc:
        raise ContractError(f"path is outside repository: {path}") from exc


def resolve_repo(value: str | None) -> Path:
    if value:
        repo = Path(value).expanduser().resolve()
    else:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            capture_output=True,
            check=False,
        )
        repo = Path(proc.stdout.strip() or os.getcwd()).resolve()
    if not repo.is_dir():
        raise ContractError(f"repository does not exist: {repo}")
    return repo


def resolve_inside_repo(value: str, repo: Path, must_exist: bool = True) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    relpath(path, repo)
    if must_exist and not path.exists():
        raise ContractError(f"required path does not exist: {path}")
    return path


def _scalar(value: str) -> Any:
    value = value.strip()
    if value in {"", "null", "~"}:
        return None
    if value == "[]":
        return []
    if value == "{}":
        return {}
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [_scalar(part) for part in inner.split(",")]
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def parse_frontmatter(path: Path) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ContractError(f"Task-Spec has no opening frontmatter delimiter: {path}")
    try:
        end = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as exc:
        raise ContractError(f"Task-Spec has no closing frontmatter delimiter: {path}") from exc

    data: dict[str, Any] = {}
    current: str | None = None
    nested_list: str | None = None
    for raw in lines[1:end]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        top = re.match(r"^([A-Za-z0-9_-]+):(?:[ \t]*(.*))?$", raw)
        if top:
            current = top.group(1)
            nested_list = None
            value = (top.group(2) or "").split("  #", 1)[0].rstrip()
            data[current] = _scalar(value) if value else {}
            continue
        nested_item = re.match(r"^[ \t]{4,}-[ \t]+(.+?)\s*$", raw)
        if nested_item and current and nested_list:
            if not isinstance(data.get(current), dict):
                data[current] = {}
            if not isinstance(data[current].get(nested_list), list):
                data[current][nested_list] = []
            data[current][nested_list].append(_scalar(nested_item.group(1)))
            continue
        item = re.match(r"^[ \t]{2}-[ \t]+(.+?)\s*$", raw)
        if item and current:
            if not isinstance(data.get(current), list):
                data[current] = []
            data[current].append(_scalar(item.group(1)))
            continue
        nested = re.match(r"^[ \t]+([A-Za-z0-9_-]+):[ \t]*(.*?)\s*$", raw)
        if nested and current:
            if not isinstance(data.get(current), dict):
                data[current] = {}
            nested_list = nested.group(1)
            nested_value = nested.group(2).split("  #", 1)[0].rstrip()
            data[current][nested_list] = _scalar(nested_value) if nested_value else []
    body = "\n".join(lines[end + 1 :]) + ("\n" if text.endswith("\n") else "")
    return data, body


def infer_primary_runtime(frontmatter: dict[str, Any]) -> tuple[str, str]:
    """Resolve the bundled runtime selected by a Task-Spec.

    `execution_backend` is canonical and `agent` is the compatibility fallback.
    Open-string engines without a bundled adapter resolve to the portable
    generic contract rather than being represented as natively supported.
    """
    for field in ("execution_backend", "agent"):
        value = str(frontmatter.get(field) or "").strip().lower()
        if value in SUPPORTED_RUNTIMES:
            return value, f"task_spec.{field}"
    return "generic", "fallback.generic"


def task_paths(frontmatter: dict[str, Any]) -> list[str]:
    values: list[str] = []
    for key in ("touches_paths", "creates_paths"):
        raw = frontmatter.get(key, [])
        if isinstance(raw, list):
            values.extend(str(item).strip() for item in raw if str(item).strip())
    return sorted(set(values))


def do_not_touch(body: str) -> list[str]:
    match = re.search(
        r"^## Do-Not-Touch[ \t]*\n(.*?)(?=^## |\Z)",
        body,
        flags=re.MULTILINE | re.DOTALL,
    )
    if not match:
        return []
    paths = []
    for line in match.group(1).splitlines():
        item = re.match(r"^[ \t]*-[ \t]+(.+?)\s*$", line)
        if not item:
            continue
        value = item.group(1).strip()
        if value.lower().startswith("(none"):
            continue
        # Entries are written for humans, so the path is usually a backticked
        # token followed by prose:  `_control` schema (the chaos ledger — ADR…).
        # Take the FIRST backticked span when there is one; stripping backticks
        # off the whole line instead fuses the path with its explanation and
        # produces a deny rule that matches nothing.
        quoted = re.match(r"^`([^`]+)`", value)
        if quoted:
            value = quoted.group(1).strip()
        else:
            # No backticks: cut at the first prose separator (em dash or ` - `).
            value = re.split(r"\s+—\s+|\s+-\s+", value, 1)[0].strip().strip("`")
            value = value.rstrip(".,;")
        if value:
            paths.append(value)
    return sorted(set(paths))


def strip_dot_slash(value: str) -> str:
    """Remove a leading './' — and ONLY that.

    `"".lstrip("./")` removes every leading '.' and '/' character, so ".env"
    became "env" and ".github/workflows/x" became "github/workflows/x". Every
    dotfile path was therefore compared under the wrong name, which quietly
    exempted exactly the files most worth guarding.
    """
    while value.startswith("./"):
        value = value[2:]
    return value


def path_matches(candidate: str, rule: str) -> bool:
    candidate = strip_dot_slash(candidate)
    rule = strip_dot_slash(rule.strip())
    if not candidate or not rule:
        return False
    if any(ch in rule for ch in "*?["):
        return fnmatch.fnmatchcase(candidate, rule)
    base = rule.rstrip("/")
    return candidate == base or candidate.startswith(base + "/")


def path_allowed(candidate: str, allowed: Iterable[str], forbidden: Iterable[str]) -> bool:
    if any(path_matches(candidate, rule) for rule in forbidden):
        return False
    return any(path_matches(candidate, rule) for rule in allowed)


def cited_adrs(body: str, repo: Path) -> list[Path]:
    pattern = r"(?<![A-Za-z0-9_.-])((?:cvg/)?docs/adrs/[A-Za-z0-9_./-]+\.md)"
    found = []
    for value in re.findall(pattern, body):
        path = resolve_inside_repo(value, repo, must_exist=True)
        if path not in found:
            found.append(path)
    return found


def evidence_entry(path: Path, repo: Path, kind: str) -> dict[str, str]:
    return {"kind": kind, "path": relpath(path, repo), "sha256": sha256_file(path)}


def load_profile(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"profile is not valid JSON-subset YAML: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError("execution profile must be an object")
    return value


def profile_task_path(profile: dict[str, Any], repo: Path) -> Path:
    try:
        value = profile["task"]["spec_ref"]["path"]
    except (KeyError, TypeError) as exc:
        raise ContractError("profile is missing task.spec_ref.path") from exc
    expected = resolve_inside_repo(str(value), repo, must_exist=False)
    if expected.is_file():
        return expected
    # A successful transition moves `tasks/T-*.md` to `tasks/done/T-*.md`.
    # That lifecycle move does not alter the signed bytes or invalidate the
    # execution evidence. Resolve only this one canonical relocation; never scan
    # broadly or accept an arbitrary same-named file elsewhere.
    if expected.parent.name == "tasks":
        landed = expected.parent / "done" / expected.name
        if landed.is_file():
            return landed
    raise ContractError(f"required task spec does not exist: {expected}")


def verify_signoff_pure(task: Path, repo: Path, tool_home: Path) -> tuple[int, str]:
    """Read-only sign-off verification — WP2.

    `run_signoff_gate` shells out to safe-to-delegate.sh, which EXECUTES the
    task's evals and can touch repository state (the spec state index). That is
    correct for stamping, but wrong for a command documented as read-only: a
    verifier that runs untrusted project code is not a verifier, it is an
    execution path. This recomputes the HMAC directly instead — no eval
    execution, no writes, no project commands.

    Returns (tier, note): 1 = envelope v2 verified, 2 = structural or legacy-v1,
    3 = mismatch. Never raises for an unsigned spec; the caller decides.
    """
    del tool_home  # Task-Spec is a separately installed engine, not a Converge subtree.
    engine = os.environ.get("CVG_TASKSPEC_BIN") or os.environ.get("TASKSPEC_BIN", "taskspec")
    try:
        proc = subprocess.run(
            [engine, "--json", "status", str(task)],
            cwd=repo,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        return 3, f"Task-Spec engine unavailable ({exc})"
    try:
        envelope = json.loads(proc.stdout)
        authorization = (envelope.get("data") or {}).get("authorization") or {}
        tier = int(authorization.get("tier", 3))
        verification = str(authorization.get("verification", "unknown"))
    except (TypeError, ValueError, json.JSONDecodeError):
        return 3, "Task-Spec status returned an invalid machine envelope"
    return tier, f"Task-Spec authorization {verification}"


def run_signoff_gate(
    task: Path, repo: Path, tool_home: Path, supervised: bool
) -> tuple[int, str]:
    del tool_home
    engine = os.environ.get("CVG_TASKSPEC_BIN") or os.environ.get("TASKSPEC_BIN", "taskspec")
    command = [engine, "gate"]
    if not supervised:
        command.append("--require-tier1")
    command.append(str(task))
    try:
        proc = subprocess.run(command, cwd=repo, text=True, capture_output=True, check=False)
    except OSError as exc:
        raise ContractError(f"Task-Spec engine unavailable: {exc}") from exc
    output = (proc.stdout + "\n" + proc.stderr).strip()
    if proc.returncode != 0:
        tail = "\n".join(output.splitlines()[-12:])
        raise ContractError(f"Task-Spec is not execution-ready:\n{tail}")
    tier_match = re.findall(r"^TIER=([123])$", output, flags=re.MULTILINE)
    if not tier_match:
        raise ContractError("sign-off gate returned no trust tier; task is not signed")
    tier = int(tier_match[-1])
    if tier == 3:
        raise ContractError("Task-Spec signature is invalid (Tier 3)")
    return tier, output


def parse_worker(value: str) -> dict[str, Any]:
    parts = value.split(":", 2)
    if len(parts) != 3:
        raise ContractError(
            f"worker must be name:read-only|scoped-write:path[,path]: {value}"
        )
    name, permission, raw_paths = (part.strip() for part in parts)
    if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
        raise ContractError(f"invalid worker name: {name}")
    if permission not in PERMISSIONS:
        raise ContractError(f"invalid worker permission class: {permission}")
    ownership = [item.strip() for item in raw_paths.split(",") if item.strip()]
    if permission == "read-only" and ownership:
        raise ContractError(f"read-only worker '{name}' cannot own writable paths")
    if permission == "scoped-write" and not ownership:
        raise ContractError(f"scoped-write worker '{name}' needs ownership paths")
    return {"name": name, "permission_class": permission, "owns_paths": ownership}


def validate_topology(
    mode: str,
    justification: str,
    workers: list[dict[str, Any]],
    allowed: list[str],
) -> list[str]:
    errors: list[str] = []
    if mode not in TOPOLOGIES:
        return [f"unsupported topology: {mode}"]
    if mode != "single":
        generic = {"use multiple agents", "parallel is faster", "independent work"}
        if len(justification.strip()) < 24 or justification.strip().lower() in generic:
            errors.append("non-single topology requires a substantive static justification")
    if mode == "parallel":
        writers = [w for w in workers if w.get("permission_class") == "scoped-write"]
        if len(writers) < 2:
            errors.append("parallel topology requires at least two scoped-write workers")
        seen: list[tuple[str, str]] = []
        for worker in writers:
            for owned in worker.get("owns_paths", []):
                if not any(path_matches(owned, rule) or path_matches(rule, owned) for rule in allowed):
                    errors.append(
                        f"worker {worker.get('name')} owns path outside Task-Spec scope: {owned}"
                    )
                for other_name, other_path in seen:
                    if (
                        path_matches(owned, other_path)
                        or path_matches(other_path, owned)
                        or owned == other_path
                    ):
                        errors.append(
                            f"parallel ownership overlaps: {other_name}:{other_path} and "
                            f"{worker.get('name')}:{owned}"
                        )
                seen.append((str(worker.get("name")), str(owned)))
    elif workers:
        errors.append("explicit --worker partitions are only valid with parallel topology")
    return errors


# ===========================================================================
# The capability envelope — task-scoped authority with explicit CLOSURE.
# ===========================================================================
# Runtime CLIs grant permissions for a SESSION. A session outlives the task, so
# authority granted for one unit of work lingers over the next — the "lingering
# authority" failure. Bind answers it by making authority an EPOCH: capabilities
# are granted against one signed spec revision, scoped to that spec's own paths,
# and revoked the moment the task settles. Re-binding mints a new epoch; a stale
# epoch is not a warning, it is a closed door.
CAPABILITY_IDS = (
    "fs.read",       # read the evidence slice + repo
    "fs.write",      # write inside the Task-Spec's declared scope
    "proc.exec",     # run commands (evals, builds)
    "net.egress",    # reach the network
    "vcs.commit",    # write git history
    "vcs.push",      # publish outside the machine
    "tracker.write", # mutate the board
)

# How strongly a control is held. The distinction is load-bearing: a kernel or
# pre-tool hook PREVENTS the action; a portable postflight only DETECTS it after
# the fact. Application-layer filtering is exactly what prompt injection targets,
# so `detect` is evidence, never a boundary — and `unenforced` fails closed.
ENFORCEMENT_KINDS = ("prevent", "detect", "unenforced")

CLOSURE_EVENTS = ("settle", "block", "budget_exhausted", "epoch_change")


def authority_epoch(task_id: str, spec_sha256: str) -> str:
    """One authority epoch = one task at one signed revision."""
    return f"{task_id}@{spec_sha256[:12]}"


def build_authority(
    task_id: str,
    spec_sha256: str,
    allowed: list[str],
    forbidden: list[str],
    network: str,
    external_writes: str = "deny",
) -> dict[str, Any]:
    """Compile the Task-Spec's declared scope into a closed capability envelope."""
    net_granted = str(network).lower() not in {"", "deny", "none", "false", "no"}
    ext_granted = str(external_writes).lower() not in {"", "deny", "none", "false", "no"}
    grants = [
        {"capability": "fs.read", "granted": True, "scope": ["<repo>"], "phase": "all"},
        {"capability": "fs.write", "granted": True, "scope": allowed, "deny_scope": forbidden, "phase": "implement"},
        {"capability": "proc.exec", "granted": True, "scope": ["task_spec.evaluations"], "phase": "verify"},
        {"capability": "net.egress", "granted": net_granted, "scope": [], "phase": "all" if net_granted else "none"},
        {"capability": "vcs.commit", "granted": True, "scope": allowed, "phase": "settle"},
        {"capability": "vcs.push", "granted": ext_granted, "scope": [], "phase": "settle" if ext_granted else "none"},
        {"capability": "tracker.write", "granted": ext_granted, "scope": [], "phase": "settle" if ext_granted else "none"},
    ]
    return {
        "model": "task-scoped-capability-envelope",
        "epoch": authority_epoch(task_id, spec_sha256),
        "grants": grants,
        "closure": {
            "revoke_on": list(CLOSURE_EVENTS),
            "revocation_is_mandatory": True,
            "lingering_authority": "denied",
            "note": (
                "Authority is bound to this epoch. When the task settles, blocks, "
                "exhausts its budget, or the spec hash changes, every grant above is "
                "revoked. A new epoch requires a fresh bind."
            ),
        },
    }


def required_controls(extra: Iterable[str] | None = None) -> list[str]:
    """Controls that MUST be held for the envelope to mean anything.

    `fs.write` is always required: the write scope is the core promise of the
    contract, and the portable postflight guard means every runtime can at least
    DETECT a violation. Denied capabilities (network, push, tracker) are always
    *reported* per adapter, but they only become gate-failing when the operator
    demands them with `--require`, because not every task needs the network
    provably severed — and a gate that always fails teaches people to bypass it.
    """
    required = {"fs.write"}
    for item in extra or ():
        value = str(item).strip()
        if value:
            if value not in CAPABILITY_IDS:
                raise ContractError(
                    f"unknown capability in --require: {value} "
                    f"(known: {', '.join(CAPABILITY_IDS)})"
                )
            required.add(value)
    return sorted(required)


# ===========================================================================
# The resolver manifest — what each runtime ACTUALLY enforces.
# ===========================================================================
# An adapter that merely *describes* a control proves nothing. Every adapter must
# declare, per capability, whether it PREVENTS, only DETECTS, or cannot honor the
# control at all — and the gate fails closed when a required control is
# unenforced. No adapter may weaken a portable guarantee silently.
RUNTIME_CONTROLS: dict[str, dict[str, dict[str, str]]] = {
    "generic": {
        "fs.write": {"kind": "detect", "mechanism": "portable postflight diff guard (check-path-policy.py)"},
        "proc.exec": {"kind": "unenforced", "mechanism": "none"},
        "net.egress": {"kind": "unenforced", "mechanism": "none"},
        "vcs.push": {"kind": "detect", "mechanism": "settlement policy check before push"},
        "tracker.write": {"kind": "detect", "mechanism": "settlement policy check"},
    },
    "claude": {
        "fs.write": {"kind": "detect", "mechanism": "portable whole-repo postflight; emitted PreToolUse fragment prevents Edit/Write/NotebookEdit only when a dispatcher installs it, while Bash remains broader"},
        "proc.exec": {"kind": "prevent", "mechanism": "permissions.deny Bash(...) + sandbox (Seatbelt/bubblewrap)"},
        "net.egress": {"kind": "prevent", "mechanism": "sandbox deniedDomains + WebFetch deny rules"},
        "vcs.push": {"kind": "detect", "mechanism": "Bash(git push:*) deny rule; still verified at settlement"},
        "tracker.write": {"kind": "detect", "mechanism": "settlement policy check"},
    },
    "codex": {
        "fs.write": {"kind": "detect", "mechanism": "workspace sandbox prevents writes outside writable roots; Task-Spec subpaths are enforced by the portable whole-repo postflight"},
        "proc.exec": {"kind": "prevent", "mechanism": "seccomp-bpf syscall filter"},
        "net.egress": {"kind": "prevent", "mechanism": "seccomp blocks network syscalls unless allowlisted"},
        "vcs.push": {"kind": "prevent", "mechanism": "network denied by sandbox unless explicitly allowed"},
        "tracker.write": {"kind": "prevent", "mechanism": "network denied by sandbox unless explicitly allowed"},
    },
    "kimi": {
        "fs.write": {"kind": "detect", "mechanism": "portable postflight diff guard"},
        "proc.exec": {"kind": "unenforced", "mechanism": "none"},
        "net.egress": {"kind": "unenforced", "mechanism": "none"},
        "vcs.push": {"kind": "detect", "mechanism": "settlement policy check"},
        "tracker.write": {"kind": "detect", "mechanism": "settlement policy check"},
    },
    "omp": {
        "fs.write": {"kind": "detect", "mechanism": "portable postflight diff guard"},
        "proc.exec": {"kind": "unenforced", "mechanism": "none"},
        "net.egress": {"kind": "unenforced", "mechanism": "none"},
        "vcs.push": {"kind": "detect", "mechanism": "settlement policy check"},
        "tracker.write": {"kind": "detect", "mechanism": "settlement policy check"},
    },
}


def resolve_adapter(
    runtime: str, required: list[str], report: Iterable[str] | None = None
) -> dict[str, Any]:
    """Build the resolver manifest: handled / mapped-weaker / ignored, per control.

    Mirrors the AgentManifest resolver contract — a runtime must state which
    directives it handled, which it mapped to weaker behavior, and which it
    ignored, so the gate can refuse to pretend. `report` adds capabilities that
    are disclosed but do not fail the gate.
    """
    table = RUNTIME_CONTROLS.get(runtime, {})
    controls: dict[str, Any] = {}
    unenforced: list[str] = []
    detect_only: list[str] = []
    gate_relevant = set(required)
    for capability in sorted(gate_relevant | set(report or ())):
        entry = table.get(capability)
        kind = entry["kind"] if entry else "unenforced"
        mechanism = entry["mechanism"] if entry else "none"
        if kind == "prevent":
            status = "handled"
        elif kind == "detect":
            status = "mapped"
            if capability in gate_relevant:
                detect_only.append(capability)
        else:
            status = "ignored"
            if capability in gate_relevant:
                unenforced.append(capability)
        controls[capability] = {
            "status": status,
            "enforcement_kind": kind,
            "mechanism": mechanism,
            "gate_relevant": capability in gate_relevant,
        }
    return {
        "runtime": runtime,
        "controls": controls,
        "detect_only": sorted(detect_only),
        "unenforced_required": sorted(unenforced),
        "fails_closed": bool(unenforced),
    }


def weakest_link(resolutions: list[dict[str, Any]]) -> str:
    """The honest headline: the strongest claim the WEAKEST required control allows."""
    if any(res.get("unenforced_required") for res in resolutions):
        return "unenforced"
    if any(res.get("detect_only") for res in resolutions):
        return "detect"
    return "prevent"


# ===========================================================================
# 7B — the task brief (AGENTS.task.md)
# ===========================================================================
# 7A is the contract the RUNTIME enforces. 7B is the brief the MODEL reads.
#
# It carries IDENTIFIERS, not content: paths, hashes and one-line pointers the
# worker resolves on demand. That is deliberate. Measured findings that shape it:
#   * auto-generated context files HURT — task success fell ~3% while cost rose
#     >20%, because agents dutifully followed generated bulk and shipped worse
#     patches. So this brief states facts the worker cannot infer (scope, the
#     eval, the fences) and refuses to narrate the codebase.
#   * context rot degrades recall well before the window is full, so every token
#     here competes with the actual work. The brief stays short on purpose.
#   * just-in-time beats pre-loading: hold a path, fetch when needed.
# The project's durable doctrine lives in ONE router file (AGENTS.md) that this
# brief points at — never copied in, so it cannot drift per task.

def section(body: str, heading: str) -> str:
    """Extract one `## Heading` section's text (empty when absent)."""
    match = re.search(
        rf"^## {re.escape(heading)}[ \t]*\n(.*?)(?=^## |\Z)",
        body,
        flags=re.MULTILINE | re.DOTALL,
    )
    return match.group(1).strip() if match else ""


def first_sentences(text: str, limit: int = 2) -> str:
    """First N sentences of a block, whitespace-collapsed — keeps the brief tight."""
    flat = " ".join(line.strip() for line in text.splitlines() if line.strip())
    flat = re.sub(r"\s+", " ", flat)
    parts = re.split(r"(?<=[.!?])\s+", flat)
    return " ".join(parts[:limit]).strip()


def render_task_brief(
    task_id: str,
    profile: dict[str, Any],
    body: str,
    allowed: list[str],
    forbidden: list[str],
    spec_rel: str,
    profile_rel: str,
    router_ref: str | None,
) -> str:
    """Render the task-scoped brief a worker reads before touching anything."""
    authority = profile.get("authority", {})
    enforcement = profile.get("enforcement", {})
    policy = profile.get("policy", {})
    # The spec's Exit Check already ships inside a fenced block; strip that fence
    # so the brief does not nest one code fence inside another (renders broken).
    exit_check = section(body, "Exit Check")
    fenced = re.match(r"^```[a-zA-Z]*\n(.*?)\n?```\s*$", exit_check, flags=re.DOTALL)
    if fenced:
        exit_check = fenced.group(1).strip()
    goal = first_sentences(section(body, "Goal"), 2)

    lines: list[str] = []
    add = lines.append
    add(f"# Task brief — {task_id}")
    add("")
    add(
        "> Generated by Pass 7 · Bind. **The signed Task-Spec is the only "
        "instruction source** — this brief points at it, never replaces it. "
        "It holds identifiers, not content: open what you need, when you need it."
    )
    add("")
    add(f"- **Spec (canonical):** `{spec_rel}`")
    add(f"- **Contract:** `{profile_rel}`")
    add(f"- **Epoch:** `{authority.get('epoch', '')}`")
    if router_ref:
        add(f"- **Project conventions:** `{router_ref}` (read it once; it is the router)")
    add("")
    if goal:
        add("## Goal")
        add("")
        add(goal)
        add("")
    add("## You may write ONLY these paths")
    add("")
    for path in allowed:
        add(f"- `{path}`")
    if forbidden:
        add("")
        add("**Never touch:**")
        add("")
        for path in forbidden:
            add(f"- `{path}`")
    add("")
    add("## Done means")
    add("")
    add(
        "Done is not your judgement — it is this command exiting zero from a "
        "clean checkout:"
    )
    add("")
    add("```bash")
    add(exit_check if exit_check else "(see the spec's Exit Check)")
    add("```")
    add("")
    add("## Boundaries")
    add("")
    add(f"- network: **{policy.get('network', 'deny')}** · external writes: "
        f"**{policy.get('external_writes', 'deny')}**")
    add(f"- enforcement on `{enforcement.get('primary_runtime', 'generic')}`: "
        f"**{enforcement.get('assurance', 'unknown')}** "
        "(`prevent` = blocked before it happens; `detect` = caught at settlement)")
    add(
        "- authority closes on: "
        + ", ".join(authority.get("closure", {}).get("revoke_on", []))
        + " — a new epoch requires a fresh bind"
    )
    add("")
    add("## Before you settle")
    add("")
    add("```bash")
    add(
        f"python3 skills/task-to-runtime-contract/scripts/check-path-policy.py "
        f"--profile {profile_rel} --base \"$CVG_BASE_REF\""
    )
    add("```")
    add("")
    add(
        "If you need something outside this scope, **stop and request a re-bind**. "
        "Widening scope yourself invalidates the seal and the work will be rejected."
    )
    add("")
    return "\n".join(lines)


def unresolved_placeholder(text: str) -> bool:
    patterns = (
        r"\{\{[^}]+\}\}",
        r"<!--\s*TODO\b",
        r"<(?:task-id|path|slug|url|todo)>",
    )
    return any(re.search(pattern, text, flags=re.IGNORECASE) for pattern in patterns)
