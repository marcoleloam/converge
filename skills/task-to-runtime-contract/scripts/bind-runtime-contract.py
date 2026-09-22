#!/usr/bin/env python3
"""Bind one signed Task-Spec to a thin, hash-bound execution profile."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from _runtime_contract import (
    ContractError,
    SCHEMA,
    SUPPORTED_RUNTIMES,
    VERSION,
    build_authority,
    cited_adrs,
    do_not_touch,
    evidence_entry,
    infer_primary_runtime,
    parse_frontmatter,
    parse_worker,
    relpath,
    render_task_brief,
    required_controls,
    resolve_adapter,
    resolve_inside_repo,
    resolve_repo,
    run_signoff_gate,
    sha256_file,
    task_paths,
    validate_topology,
    weakest_link,
)


CAPABILITIES = {
    "single": ["diagnose", "implement", "verify"],
    "single-explorer": ["discover", "diagnose", "implement", "verify"],
    "implementer-verifier": ["diagnose", "implement", "verify"],
    "parallel": ["discover", "diagnose", "implement", "verify", "integrate"],
}


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Create and gate a Pass 6 runtime contract for one signed Task-Spec."
    )
    value.add_argument("--task", required=True)
    value.add_argument("--repo")
    value.add_argument("--tool-home")
    value.add_argument("--out")
    value.add_argument(
        "--topology",
        default="single",
        choices=["single", "single-explorer", "implementer-verifier", "parallel"],
    )
    value.add_argument("--justification", default="")
    value.add_argument("--worker", action="append", default=[])
    value.add_argument("--context", action="append", default=[])
    value.add_argument("--knowledge", action="append", default=[])
    value.add_argument(
        "--doc",
        action="append",
        default=[],
        metavar="URL=CACHE_PATH",
        help="Pin an external document to a repository-local cached copy.",
    )
    value.add_argument("--adapter", action="append", default=[])
    value.add_argument("--supervised", action="store_true")
    value.add_argument("--dry-run", action="store_true")
    value.add_argument(
        "--runtime",
        default=None,
        help="runtime that must honor the contract (default: infer a supported execution_backend/agent, else generic)",
    )
    value.add_argument(
        "--require",
        action="append",
        default=[],
        metavar="CAPABILITY",
        help="a capability whose enforcement is mandatory; unenforced => gate FAILS closed",
    )
    value.add_argument(
        "--accept-unenforced",
        action="append",
        default=[],
        metavar="CAPABILITY",
        help="explicitly waive a required capability the runtime cannot enforce (audited)",
    )
    return value


def adapter_payload(adapter: str, profile_path: str) -> dict:
    native = {
        "generic": {
            "prewrite": "runner passes every candidate path to candidate_guard_command",
            "supports_prewrite_prevention": False,
        },
        "claude": {
            "prewrite": "generated PreToolUse settings fragment guards Edit/Write/NotebookEdit when installed",
            "supports_prewrite_prevention": False,
            "prewrite_prevention_status": "integration-required; Bash writes remain postflight-detected",
        },
        "codex": {
            "prewrite": "workspace sandbox bounds writes to the workspace, not to Task-Spec paths",
            "supports_prewrite_prevention": False,
            "prewrite_prevention_status": "workspace-only; task scope is postflight-detected",
        },
        "kimi": {
            "prewrite": "permission mode or runtime hook when available",
            "supports_prewrite_prevention": False,
        },
        "omp": {
            "prewrite": "permission mode or runtime hook when available",
            "supports_prewrite_prevention": False,
        },
    }[adapter]
    scripts = "skills/task-to-runtime-contract/scripts"
    quoted = json.dumps(profile_path)
    tool_guard = (
        f"CVG_EXECUTION_PROFILE={quoted} python3 {scripts}/guard-tool-input.py"
    )
    payload = {
        "schema": "cvg.runtime-adapter.v1",
        "adapter": adapter,
        "execution_profile": profile_path,
        "native_control": native,
        "candidate_guard_command": (
            f"python3 {scripts}/check-path-policy.py --profile {quoted} --candidate \"$CVG_CANDIDATE_PATH\""
        ),
        "tool_input_guard_command": tool_guard,
        "postflight_command": (
            f"python3 {scripts}/check-path-policy.py --profile {quoted} --base \"$CVG_BASE_REF\""
        ),
        "settlement_policy": "postflight_command is mandatory before PR or success receipt",
    }
    if adapter == "claude":
        payload["claude_settings_fragment"] = {
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Edit|Write|NotebookEdit",
                        "hooks": [
                            {
                                "type": "command",
                                "command": tool_guard,
                            }
                        ],
                    }
                ]
            }
        }
    return payload


def main() -> int:
    args = parser().parse_args()
    try:
        repo = resolve_repo(args.repo)
        tool_home = resolve_repo(args.tool_home) if args.tool_home else Path(__file__).resolve().parents[3]
        task = resolve_inside_repo(args.task, repo)
        frontmatter, body = parse_frontmatter(task)
        task_id = str(frontmatter.get("id") or task.stem)
        if task.stem != task_id:
            raise ContractError(
                f"Task-Spec id does not match filename: id={task_id}, file={task.stem}"
            )
        tier, _ = run_signoff_gate(task, repo, tool_home, args.supervised)
        allowed = task_paths(frontmatter)
        inferred_runtime, inferred_source = infer_primary_runtime(frontmatter)
        runtime_source = "operator_override"
        if args.runtime is None:
            args.runtime = inferred_runtime
            runtime_source = inferred_source
        if not allowed:
            raise ContractError("Task-Spec declares no touches_paths or creates_paths")

        workers = [parse_worker(value) for value in args.worker]
        justification = args.justification.strip()
        if args.topology == "single" and not justification:
            justification = (
                "Single-agent default; no static topology escalation trigger was selected."
            )
        topology_errors = validate_topology(
            args.topology, justification, workers, allowed
        )
        if topology_errors:
            raise ContractError("; ".join(topology_errors))

        required_files = []
        seen: set[str] = set()
        for path in cited_adrs(body, repo):
            entry = evidence_entry(path, repo, "adr")
            if entry["path"] not in seen:
                required_files.append(entry)
                seen.add(entry["path"])
        for value in args.context:
            path = resolve_inside_repo(value, repo)
            entry = evidence_entry(path, repo, "context")
            if entry["path"] not in seen:
                required_files.append(entry)
                seen.add(entry["path"])

        approved_knowledge = []
        for value in args.knowledge:
            path = resolve_inside_repo(value, repo)
            approved_knowledge.append(evidence_entry(path, repo, "project-knowledge"))

        external_docs = []
        for value in args.doc:
            if "=" not in value:
                raise ContractError("--doc must use URL=CACHE_PATH")
            url, cache_value = value.rsplit("=", 1)
            if not url.startswith(("https://", "http://")):
                raise ContractError(f"external document URL is invalid: {url}")
            cache = resolve_inside_repo(cache_value, repo)
            external_docs.append(
                {
                    "url": url,
                    "cache_path": relpath(cache, repo),
                    "sha256": sha256_file(cache),
                }
            )

        adapters = args.adapter or ["generic"] + sorted(SUPPORTED_RUNTIMES)
        adapters = list(dict.fromkeys(adapters))
        invalid = sorted(set(adapters) - ({"generic"} | SUPPORTED_RUNTIMES))
        if invalid:
            raise ContractError(f"unsupported adapter(s): {', '.join(invalid)}")

        output = (
            resolve_inside_repo(args.out, repo, must_exist=False)
            if args.out
            else repo / "cvg/execution" / task_id / "execution-profile.yaml"
        )
        profile_rel = relpath(output, repo)
        profile_dir = output.parent
        adapter_entries = [
            {
                "runtime": adapter,
                "path": relpath(profile_dir / "adapters" / f"{adapter}.json", repo),
            }
            for adapter in adapters
        ]
        network = "deny"
        requires = frontmatter.get("requires")
        if isinstance(requires, dict) and requires.get("network"):
            network = str(requires["network"])

        # The capability envelope: the Task-Spec's declared scope compiled into
        # epoch-bound authority that CLOSES when the task settles.
        spec_sha = sha256_file(task)
        forbidden = do_not_touch(body)
        authority = build_authority(
            task_id=task_id,
            spec_sha256=spec_sha,
            allowed=allowed,
            forbidden=forbidden,
            network=network,
            external_writes="deny",
        )
        needed = required_controls(args.require)
        denied_caps = [
            str(g["capability"]) for g in authority["grants"] if not g.get("granted")
        ]
        # Resolver manifests — per runtime, what is PREVENTED vs only DETECTED vs
        # ignored. An ignored required control makes the adapter fail closed.
        for entry in adapter_entries:
            entry["resolution"] = resolve_adapter(entry["runtime"], needed, denied_caps)
        resolutions = [entry["resolution"] for entry in adapter_entries]
        if args.runtime not in {e["runtime"] for e in adapter_entries}:
            raise ContractError(
                f"--runtime {args.runtime} has no emitted adapter "
                f"(emitted: {', '.join(sorted(e['runtime'] for e in adapter_entries))})"
            )
        waivers = sorted({str(w).strip() for w in args.accept_unenforced if str(w).strip()})

        profile = {
            "schema": SCHEMA,
            "task": {
                "id": task_id,
                "spec_ref": {"path": relpath(task, repo), "sha256": spec_sha},
                "authorization": {
                    "signed_off": True,
                    "trust_tier": tier,
                    "requires_tier1": not args.supervised,
                },
            },
            "canonical_sources": {
                "write_scope": "task_spec.touches_paths + task_spec.creates_paths",
                "forbidden_scope": "task_spec.section.Do-Not-Touch",
                "evaluations": "task_spec.Success_Criteria + task_spec.Exit_Check",
                "budgets": "task_spec.budget_iterations + task_spec.budget_tokens",
                "routing": "task_spec.execution_backend + task_spec.agent",
            },
            "context": {
                "required_files": required_files,
                "approved_project_knowledge": approved_knowledge,
                "external_docs": external_docs,
            },
            "topology": {
                "mode": args.topology,
                "justification": justification,
                "capabilities": CAPABILITIES[args.topology],
                "workers": workers
                if args.topology == "parallel"
                else [
                    {
                        "name": "primary",
                        "permission_class": "task-scoped-write",
                        "ownership_source": "task_spec",
                    }
                ],
            },
            "policy": {
                "network": network,
                "external_writes": "deny",
                "approval_required_for": [
                    "external_writes",
                    "network_policy_expansion",
                    "scope_expansion",
                ],
                "runtime_escalation": {
                    "signals": [
                        "two_identical_eval_failures",
                        "unexpected_dependency",
                        "context_pressure",
                    ],
                    "action": "pause_and_rebind_or_request_approval",
                },
            },
            "authority": authority,
            "enforcement": {
                "path_policy_source": "task_spec",
                "candidate_guard": "skills/task-to-runtime-contract/scripts/check-path-policy.py",
                "tool_input_guard": "skills/task-to-runtime-contract/scripts/guard-tool-input.py",
                "receipt_writer": "skills/task-to-runtime-contract/scripts/write-execution-receipt.py",
                "portable_postflight_required": True,
                "required_controls": needed,
                "primary_runtime": args.runtime,
                "runtime_selection": {
                    "source": runtime_source,
                    "inferred_runtime": inferred_runtime,
                    "inferred_source": inferred_source,
                },
                # 7B — the model-facing brief. Recorded so the gate can prove it
                # exists and stays in step with this epoch.
                "task_brief": relpath(profile_dir / "AGENTS.task.md", repo),
                # The honest headline: the strongest claim the WEAKEST required
                # control supports on the PRIMARY runtime.
                "assurance": weakest_link(
                    [e["resolution"] for e in adapter_entries if e["runtime"] == args.runtime]
                ),
                "unenforced_waivers": waivers,
                "adapters": adapter_entries,
            },
            "knowledge": {
                "candidate_output": f"cvg/knowledge/candidates/{task_id}.md",
                "promotion": "owner_or_designated_reviewer",
            },
            "receipt": {"path": f"cvg/receipts/{task_id}.json"},
            "generated": {
                "by": "task-to-runtime-contract",
                "version": VERSION,
                "format": "JSON subset of YAML 1.2",
            },
        }

        rendered = json.dumps(profile, indent=2, sort_keys=True) + "\n"
        if args.dry_run:
            print(rendered, end="")
            print("CHECK_RUNTIME_CONTRACT=DRY_RUN")
            return 0

        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
        # 7B — the task brief. Points at the project router when one exists;
        # never copies project doctrine in (auto-generated bulk measurably hurts).
        router = next(
            (r for r in ("AGENTS.md", "CLAUDE.md") if (repo / r).is_file()), None
        )
        (output.parent / "AGENTS.task.md").write_text(
            render_task_brief(
                task_id=task_id,
                profile=profile,
                body=body,
                allowed=allowed,
                forbidden=forbidden,
                spec_rel=relpath(task, repo),
                profile_rel=profile_rel,
                router_ref=router,
            ),
            encoding="utf-8",
        )
        # 7C — the terrain pack, one per SWIMLANE.
        #
        # The brief above holds identifiers by design, and that is right for a
        # thing that sits beside a sealed contract. But it left the executor to
        # rediscover the seam shape, the ADR decisions and the vocabulary on
        # every attempt — 66 turns and $7.91 on the first real run, re-paid in
        # full each retry because context is deliberately fresh per attempt.
        #
        # Best-effort on purpose: a pack is derived and unsealed, carries no
        # authority, and cannot widen scope. A bind that FAILED because terrain
        # could not be assembled would be a bind blocked by a convenience.
        try:
            pack_script = Path(__file__).with_name("context-pack.py")
            if pack_script.exists():
                proc = subprocess.run(
                    [sys.executable, str(pack_script), "--task", relpath(task, repo),
                     "--repo", str(repo)],
                    cwd=repo, text=True, capture_output=True, check=False,
                )
                for line in proc.stdout.splitlines():
                    if line.startswith("Terrain pack:") or line.startswith("CONTEXT_PACK="):
                        print(line)
        except Exception as exc:  # noqa: BLE001 — never let terrain assembly fail a bind
            # Report it. A silent `pass` here hid a NameError in this very block
            # during development: bind kept printing PASS while quietly producing
            # no pack, and the only symptom was a missing file nobody was looking
            # for. Best-effort must still be audible.
            print(f"note: terrain pack not assembled ({type(exc).__name__}: {exc})")

        adapter_dir = output.parent / "adapters"
        adapter_dir.mkdir(parents=True, exist_ok=True)
        for adapter in adapters:
            payload = adapter_payload(adapter, profile_rel)
            (adapter_dir / f"{adapter}.json").write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        print(f"Runtime contract written: {profile_rel}")

        checker = Path(__file__).with_name("check-runtime-contract.py")
        command = [
            sys.executable,
            str(checker),
            "--profile",
            str(output),
            "--repo",
            str(repo),
            "--tool-home",
            str(tool_home),
        ]
        if args.supervised:
            command.append("--supervised")
        # `import subprocess` used to sit HERE, function-local. Python then treats
        # the name as local for the whole function, so the module-level import is
        # shadowed and any EARLIER use in this same function raises
        # UnboundLocalError. That is exactly what happened when the terrain-pack
        # call was added above: bind printed PASS and silently produced no pack.
        return subprocess.run(command, cwd=repo, check=False).returncode
    except ContractError as exc:
        print(f"FAIL: {exc}")
        print("CHECK_RUNTIME_CONTRACT=FAIL")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
