#!/usr/bin/env python3
"""Thin coordinator for the independently released Seamwise and Task-Spec CLIs.

This module deliberately imports neither engine.  JSON over subprocess boundaries
is the public integration contract; every artifact is re-hashed before Converge
persists its own composition receipt.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, NoReturn

COMPOSITION_RECEIPT = "ConvergeCompositionReceipt/v1"
SOURCE_BINDING = "ConvergeCompositionSource/v1"
SEAMWISE_RESULT = "SeamwiseCLIResult/v1"
SEAMWISE_CAPABILITIES = "SeamwiseCapabilities/v1"
TASKSPEC_RESULT = "TaskSpecCLIResult/v1"
TASK_PLAN = "TaskPlan/v1"
TASK_PLAN_LINEAGE = "SeamwiseTaskPlanLineage/v1"
TASK_MATERIALIZATION = "TaskMaterializationReceipt/v1"


class ComposeError(RuntimeError):
    """A fail-closed composition error with a stable process status."""

    def __init__(self, message: str, *, exit_code: int = 1, engine: bool = False):
        super().__init__(message)
        self.exit_code = exit_code
        self.engine = engine


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise ComposeError(message, exit_code=2)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ComposeError(f"cannot read valid JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ComposeError(f"expected one JSON object at {path}")
    return value


def safe_path(root: pathlib.Path, relative: str, *, must_exist: bool = True) -> pathlib.Path:
    candidate = pathlib.Path(relative)
    path = (candidate if candidate.is_absolute() else root / candidate).resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise ComposeError(f"path escapes the project workspace: {relative}") from exc
    cursor = root
    for part in path.relative_to(root).parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ComposeError(f"refusing symlinked composition path: {cursor}")
    if must_exist and (not path.is_file() or path.is_symlink()):
        raise ComposeError(f"required composition file is missing or unsafe: {path}")
    return path


def atomic_json(root: pathlib.Path, relative: str, value: dict[str, Any]) -> pathlib.Path:
    path = safe_path(root, relative, must_exist=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    safe_path(root, str(path.parent.relative_to(root)), must_exist=False)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(canonical_json(value))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return path


def resolve_binary(explicit: str | None, fallback: str, label: str) -> str:
    candidate = explicit or shutil.which(fallback)
    if not candidate:
        raise ComposeError(f"{label} engine is unavailable; install it or set the explicit binary override", exit_code=3, engine=True)
    resolved = shutil.which(candidate) if os.sep not in candidate else candidate
    path = pathlib.Path(resolved or candidate).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ComposeError(f"{label} engine is not executable at {path}", exit_code=3, engine=True)
    return str(path)


def run_json(command: list[str], *, cwd: pathlib.Path, env: dict[str, str] | None = None) -> tuple[dict[str, Any], int]:
    try:
        completed = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise ComposeError(f"engine invocation failed: {exc}", exit_code=3, engine=True) from exc
    raw = completed.stdout.strip()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        detail = completed.stderr.strip() or raw or "no output"
        raise ComposeError(f"engine did not emit one JSON document: {detail}", exit_code=3, engine=True) from exc
    if not isinstance(value, dict):
        raise ComposeError("engine JSON result is not an object", exit_code=3, engine=True)
    declared = value.get("exit_code")
    if not isinstance(declared, int) or declared != completed.returncode:
        raise ComposeError(
            f"engine exit mismatch: process={completed.returncode} envelope={declared!r}",
            exit_code=3,
            engine=True,
        )
    return value, completed.returncode


def version_tuple(value: str) -> tuple[int, int, int]:
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", value)
    if not match:
        raise ComposeError(f"engine returned an invalid semantic version: {value!r}", exit_code=3, engine=True)
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


class Coordinator:
    def __init__(self, root: pathlib.Path, cvg_version: str, seamwise: str, taskspec: str):
        self.root = root.resolve()
        self.cvg_version = cvg_version
        self.seamwise_override = seamwise or os.environ.get("CVG_SEAMWISE_BIN", "")
        self.taskspec_override = taskspec or os.environ.get("CVG_TASKSPEC_BIN", "")
        self.seamwise = ""
        self.taskspec = ""
        self.backlog = self.root / "cvg" / "tasks"
        self.acceptance = self.root / "cvg" / ".taskspec" / "acceptance"
        self.receipt_root = self.root / "cvg" / "receipts" / "composition"
        self.source_binding_path = self.receipt_root / "source.json"
        self.materialization_path = self.receipt_root / "taskspec-materialization-receipt.json"
        self.composition_path = self.receipt_root / "composition-receipt.json"
        self.seamwise_version = ""
        self.taskspec_version = ""

    def _seamwise(self, *args: str) -> tuple[dict[str, Any], int]:
        self._require_seamwise()
        value, rc = run_json(
            [self.seamwise, "--workspace", str(self.root), "--json", *args], cwd=self.root
        )
        if value.get("contract") != SEAMWISE_RESULT:
            raise ComposeError("Seamwise does not support SeamwiseCLIResult/v1", exit_code=3, engine=True)
        if value.get("engine_version") != self.seamwise_version and self.seamwise_version:
            raise ComposeError("Seamwise version changed during composition", exit_code=3, engine=True)
        return value, rc

    def _taskspec(self, *args: str) -> tuple[dict[str, Any], int]:
        self._require_taskspec()
        environment = os.environ.copy()
        environment.update(
            {
                "TASKSPEC_WORKSPACE_ROOT": str(self.root.resolve()),
                "TASKSPEC_BACKLOG_DIR": str(self.backlog.resolve()),
                "TASKSPEC_ACCEPTANCE_DIR": str(self.acceptance.resolve()),
                "NO_COLOR": "1",
            }
        )
        value, rc = run_json([self.taskspec, "--json", *args], cwd=self.root, env=environment)
        if value.get("contract") != TASKSPEC_RESULT:
            raise ComposeError("Task-Spec does not support TaskSpecCLIResult/v1", exit_code=3, engine=True)
        if value.get("engine_version") != self.taskspec_version and self.taskspec_version:
            raise ComposeError("Task-Spec version changed during composition", exit_code=3, engine=True)
        return value, rc

    def _require_seamwise(self) -> None:
        if self.seamwise:
            return
        self.seamwise = resolve_binary(self.seamwise_override, "seamwise", "Seamwise")
        capabilities, rc = run_json(
            [self.seamwise, "--workspace", str(self.root), "--json", "capabilities"], cwd=self.root
        )
        data = capabilities.get("data")
        if rc != 0 or capabilities.get("contract") != SEAMWISE_RESULT or not isinstance(data, dict):
            raise ComposeError("Seamwise capability negotiation failed", exit_code=3, engine=True)
        contracts = data.get("contracts")
        required = {
            "cli_result": SEAMWISE_RESULT,
            "task_plan": TASK_PLAN,
            "task_plan_lineage": TASK_PLAN_LINEAGE,
        }
        if data.get("contract") != SEAMWISE_CAPABILITIES or data.get("engine_major") != 0:
            raise ComposeError("incompatible Seamwise engine major or capabilities contract", exit_code=3, engine=True)
        if not isinstance(contracts, dict) or any(contracts.get(key) != value for key, value in required.items()):
            raise ComposeError("Seamwise is missing a required composed-flow contract", exit_code=3, engine=True)
        if data.get("materializes_tasks") is not False or data.get("dispatch_authority") is not False:
            raise ComposeError("Seamwise capabilities claim forbidden Task-Spec authority", exit_code=3, engine=True)
        self.seamwise_version = str(data.get("engine_version", ""))
        parsed = version_tuple(self.seamwise_version)
        if parsed < (0, 2, 0) or parsed >= (0, 3, 0):
            raise ComposeError("Converge compose requires Seamwise >=0.2.0 and <0.3.0", exit_code=3, engine=True)

    def _require_taskspec(self) -> None:
        if self.taskspec:
            return
        self.taskspec = resolve_binary(self.taskspec_override, "taskspec", "Task-Spec")
        version, rc = run_json([self.taskspec, "--json", "version"], cwd=self.root)
        self.taskspec_version = str(version.get("engine_version", ""))
        if rc != 0 or version.get("contract") != TASKSPEC_RESULT:
            raise ComposeError("Task-Spec version negotiation failed", exit_code=3, engine=True)
        parsed = version_tuple(self.taskspec_version)
        if parsed < (3, 8, 0) or parsed >= (3, 10, 0):
            raise ComposeError("Converge compose requires Task-Spec 3.8.x or 3.9.x", exit_code=3, engine=True)

    def _status(self) -> dict[str, Any]:
        value, rc = self._seamwise("status")
        if rc != 0 or value.get("token") not in {"STATUS=READY", "STATUS=BLOCKED"}:
            raise ComposeError("Seamwise status could not verify the workspace")
        data = value.get("data")
        if not isinstance(data, dict):
            raise ComposeError("Seamwise status omitted its state data")
        issues = data.get("issues")
        if issues:
            first = issues[0] if isinstance(issues, list) else issues
            raise ComposeError(f"Seamwise workspace integrity is blocked: {first}")
        return data

    def _record_source(self, source: pathlib.Path) -> bool:
        source = source.expanduser().resolve()
        if not source.is_file() or source.is_symlink():
            raise ComposeError(f"source recipe is missing or unsafe: {source}", exit_code=2)
        try:
            relative = source.relative_to(self.root).as_posix()
        except ValueError:
            relative = str(source)
        head = subprocess.run(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"], capture_output=True, text=True, check=False
        ).stdout.strip()
        value = {
            "contract": SOURCE_BINDING,
            "path": relative,
            "sha256": sha256_file(source),
            "observed_commit": head or None,
        }
        before = self.source_binding_path.read_bytes() if self.source_binding_path.is_file() else None
        atomic_json(self.root, str(self.source_binding_path.relative_to(self.root)), value)
        return before != self.source_binding_path.read_bytes()

    def prepare(self, source: pathlib.Path) -> tuple[str, str, bool]:
        state = self._status()
        if state.get("reviewed") or state.get("delivery_plan"):
            binding = load_json(self.source_binding_path)
            bound_path = pathlib.Path(str(binding.get("path", "")))
            if not bound_path.is_absolute():
                bound_path = self.root / bound_path
            if (source.expanduser().resolve() != bound_path.resolve()
                    or sha256_file(source.expanduser().resolve()) != binding.get("sha256")):
                raise ComposeError("source recipe changed; existing decomposition cannot be reused for another demand")
        if state.get("reviewed"):
            return "COMPOSE=PREVIEW_READY", "cvg compose preview", False
        if state.get("delivery_plan"):
            return "COMPOSE=NEEDS_REVIEW", 'cvg compose review --reviewer <name> --reason "<reason>"', False
        source_changed = self._record_source(source)
        value, rc = self._seamwise("prepare", "--source", str(source.expanduser().resolve()))
        if value.get("token") != "DELIVERY_PLAN=NEEDS_REVIEW" or rc != 2:
            raise ComposeError(f"Seamwise prepare did not stop at review: {value.get('token')}")
        forbidden = {self.root / "seamwise" / "task-plan.json", self.root / "seamwise" / "task-plan-lineage.json"}
        if any(path.exists() for path in forbidden):
            raise ComposeError("prepare crossed the explicit review boundary")
        return "COMPOSE=NEEDS_REVIEW", 'cvg compose review --reviewer <name> --reason "<reason>"', source_changed

    def review(self, reviewer: str, reason: str) -> tuple[str, str, bool]:
        value, rc = self._seamwise("review", "--accept", "--reviewer", reviewer, "--reason", reason)
        if rc != 0 or value.get("token") != "DELIVERY_PLAN=READY":
            raise ComposeError(f"Seamwise review was not accepted: {value.get('token')}")
        if (self.root / "seamwise" / "task-plan.json").exists():
            raise ComposeError("review compiled a TaskPlan; the authority boundary was crossed")
        return "COMPOSE=PREVIEW_READY", "cvg compose preview", True

    def _plan_bundle(self) -> tuple[pathlib.Path, pathlib.Path, dict[str, Any]]:
        plan_path = safe_path(self.root, "seamwise/task-plan.json")
        lineage_path = safe_path(self.root, "seamwise/task-plan-lineage.json")
        plan = load_json(plan_path)
        lineage = load_json(lineage_path)
        if plan.get("api_version") != "taskspec.dev/v1" or plan.get("kind") != "TaskPlan" or plan.get("approved") is not True:
            raise ComposeError("Seamwise TaskPlan is not an approved TaskPlan/v1")
        if lineage.get("contract") != TASK_PLAN_LINEAGE:
            raise ComposeError("Seamwise lineage contract is incompatible")
        return plan_path, lineage_path, lineage

    def _validate_plan(self, plan_path: pathlib.Path, lineage: dict[str, Any]) -> dict[str, Any]:
        result, rc = self._taskspec("plan", "--manifest", str(plan_path))
        data = result.get("data")
        if rc != 0 or result.get("ok") is not True or not isinstance(data, dict):
            raise ComposeError("Task-Spec rejected the reviewed TaskPlan")
        digest = data.get("digest")
        lineage_plan = lineage.get("task_plan")
        if (
            data.get("contract") != TASK_PLAN
            or data.get("approved") is not True
            or data.get("valid") is not True
            or not isinstance(digest, str)
            or not isinstance(lineage_plan, dict)
            or lineage_plan.get("contract") != TASK_PLAN
            or lineage_plan.get("digest") != digest
        ):
            raise ComposeError("TaskPlan validation and Seamwise lineage digests disagree")
        return data

    def preview(self) -> tuple[str, str, bool]:
        value, rc = self._seamwise("compile")
        if rc != 0 or value.get("token") != "TASK_GRAPH=READY":
            raise ComposeError(f"Seamwise compile is blocked: {value.get('token')}")
        expected = {
            str((self.root / "seamwise" / "task-plan.json").resolve()),
            str((self.root / "seamwise" / "task-plan-lineage.json").resolve()),
        }
        if set(value.get("artifacts", [])) != expected:
            raise ComposeError("Seamwise compile emitted something other than TaskPlan plus lineage")
        plan_path, _, lineage = self._plan_bundle()
        self._validate_plan(plan_path, lineage)
        return "COMPOSE=PREVIEW_READY", "cvg compose materialize", True

    def _git_source(self) -> dict[str, Any]:
        binding = load_json(safe_path(self.root, str(self.source_binding_path.relative_to(self.root))))
        if binding.get("contract") != SOURCE_BINDING:
            raise ComposeError("composition source binding is incompatible; rerun prepare in a clean workspace")
        raw_path = str(binding.get("path", ""))
        source = safe_path(self.root, raw_path)
        relative = source.relative_to(self.root).as_posix()
        if sha256_file(source) != binding.get("sha256"):
            raise ComposeError("source recipe changed after prepare")
        tracked = subprocess.run(
            ["git", "-C", str(self.root), "ls-files", "--error-unmatch", "--", relative],
            capture_output=True,
            text=True,
            check=False,
        )
        if tracked.returncode != 0:
            raise ComposeError("source recipe must be tracked before materialization")
        commit = subprocess.run(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"], capture_output=True, text=True, check=False
        )
        if commit.returncode != 0 or not commit.stdout.strip():
            raise ComposeError("materialization requires an immutable Git source commit")
        commit_id = commit.stdout.strip()
        blob = subprocess.run(
            ["git", "-C", str(self.root), "show", f"{commit_id}:{relative}"], capture_output=True, check=False
        )
        if blob.returncode != 0 or sha256_bytes(blob.stdout) != binding.get("sha256"):
            raise ComposeError("the source recipe bytes are not present in the current immutable commit")
        return {"commit": commit_id, "path": relative, "sha256": binding["sha256"]}

    def _validate_materialization(
        self,
        receipt: dict[str, Any],
        plan_data: dict[str, Any],
        plan: dict[str, Any],
        *,
        allow_taskspec_lifecycle: bool = False,
    ) -> list[dict[str, str]]:
        input_data = receipt.get("input")
        tasks = receipt.get("tasks")
        if (
            receipt.get("contract") != TASK_MATERIALIZATION
            or receipt.get("engine_version") != self.taskspec_version
            or receipt.get("dispatch_authorized") is not False
            or receipt.get("materialized") is not True
            or not isinstance(input_data, dict)
            or input_data.get("contract") != TASK_PLAN
            or input_data.get("digest") != plan_data.get("digest")
            or input_data.get("approved") is not True
            or not isinstance(tasks, list)
            or not tasks
        ):
            raise ComposeError("Task-Spec materialization receipt violates TaskMaterializationReceipt/v1")
        output_dir = pathlib.Path(str(receipt.get("output_dir", ""))).resolve()
        if output_dir != self.backlog.resolve():
            raise ComposeError("Task-Spec materialized outside the configured Converge backlog")
        expected_ids = {str(unit.get("id")) for unit in plan.get("units", []) if isinstance(unit, dict)}
        observed: list[dict[str, str]] = []
        for item in tasks:
            if not isinstance(item, dict):
                raise ComposeError("Task-Spec receipt contains a malformed task record")
            task_id = str(item.get("task_id", ""))
            task_path = safe_path(self.root, str(item.get("path", "")))
            try:
                task_path.relative_to(self.backlog.resolve())
            except ValueError as exc:
                raise ComposeError(f"materialized task escaped the backlog: {task_path}") from exc
            materialized_digest = str(item.get("sha256", ""))
            current_digest = sha256_file(task_path)
            if current_digest != materialized_digest:
                if not allow_taskspec_lifecycle:
                    raise ComposeError(f"materialized task hash mismatch: {task_id}")
                task_text = task_path.read_text(encoding="utf-8")
                if not re.search(r"(?m)^signed_off:\s*true\s*$", task_text):
                    raise ComposeError(f"unsigned materialized task bytes changed: {task_id}")
                validation, validation_rc = self._taskspec(
                    "validate", "--no-state", str(task_path)
                )
                if validation_rc != 0 or validation.get("ok") is not True:
                    raise ComposeError(
                        f"Task-Spec rejected the authorized lifecycle state for {task_id}"
                    )
            observed.append(
                {
                    "task_id": task_id,
                    "path": task_path.relative_to(self.root).as_posix(),
                    "sha256": materialized_digest,
                }
            )
        if {item["task_id"] for item in observed} != expected_ids or len(observed) != len(expected_ids):
            raise ComposeError("Task-Spec receipt task set differs from the reviewed TaskPlan")
        return sorted(observed, key=lambda item: item["task_id"])

    def _build_composition_receipt(
        self,
        source: dict[str, Any],
        lineage_path: pathlib.Path,
        lineage: dict[str, Any],
        plan_data: dict[str, Any],
        materialization_path: pathlib.Path,
        tasks: list[dict[str, str]],
    ) -> dict[str, Any]:
        review_path = safe_path(self.root, "seamwise/reviews/delivery-plan-review.json")
        review = load_json(review_path)
        task_plan_path = safe_path(self.root, "seamwise/task-plan.json")
        if lineage.get("review", {}).get("sha256") != sha256_file(review_path):
            raise ComposeError("Seamwise review digest does not match lineage")
        return {
            "contract": COMPOSITION_RECEIPT,
            "schema_version": 1,
            "versions": {
                "converge": self.cvg_version,
                "seamwise": self.seamwise_version,
                "task_spec": self.taskspec_version,
            },
            "source": source,
            "seamwise": {
                "review": {
                    "path": review_path.relative_to(self.root).as_posix(),
                    "sha256": sha256_file(review_path),
                    "plan_sha256": review.get("plan_sha256"),
                    "reviewer": review.get("reviewer"),
                },
                "lineage": {
                    "path": lineage_path.relative_to(self.root).as_posix(),
                    "sha256": sha256_file(lineage_path),
                },
                "task_plan": {
                    "path": task_plan_path.relative_to(self.root).as_posix(),
                    "digest": plan_data["digest"],
                },
            },
            "task_spec": {
                "materialization_receipt": {
                    "path": materialization_path.relative_to(self.root).as_posix(),
                    "sha256": sha256_file(materialization_path),
                }
            },
            "tasks": tasks,
            "dispatch_authorized": False,
        }

    def _verify_composition_receipt(self) -> dict[str, Any]:
        self._require_seamwise()
        self._require_taskspec()
        receipt = load_json(safe_path(self.root, str(self.composition_path.relative_to(self.root))))
        if receipt.get("contract") != COMPOSITION_RECEIPT or receipt.get("dispatch_authorized") is not False:
            raise ComposeError("composition receipt contract or dispatch authority is invalid")
        versions = receipt.get("versions")
        if versions != {
            "converge": self.cvg_version,
            "seamwise": self.seamwise_version,
            "task_spec": self.taskspec_version,
        }:
            raise ComposeError("composition receipt engine versions are stale")
        source = receipt.get("source")
        if not isinstance(source, dict):
            raise ComposeError("composition receipt source binding is missing")
        source_relative = str(source.get("path", ""))
        source_path = safe_path(self.root, source_relative)
        if sha256_file(source_path) != source.get("sha256"):
            raise ComposeError("composition source no longer matches its receipt")
        source_commit = source.get("commit")
        if not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
            raise ComposeError("composition receipt immutable source commit is invalid")
        committed_source = subprocess.run(
            ["git", "-C", str(self.root), "show", f"{source_commit}:{source_relative}"],
            capture_output=True,
            check=False,
        )
        if committed_source.returncode != 0 or sha256_bytes(committed_source.stdout) != source.get("sha256"):
            raise ComposeError("composition source is not bound to the recorded immutable commit")
        seamwise = receipt.get("seamwise")
        task_spec = receipt.get("task_spec")
        if not isinstance(seamwise, dict) or not isinstance(task_spec, dict):
            raise ComposeError("composition receipt engine bindings are missing")
        for key in ("review", "lineage"):
            binding = seamwise.get(key)
            if not isinstance(binding, dict):
                raise ComposeError(f"composition receipt is missing Seamwise {key}")
            path = safe_path(self.root, str(binding.get("path", "")))
            if sha256_file(path) != binding.get("sha256"):
                raise ComposeError(f"composition receipt has stale Seamwise {key}")
        plan_binding = seamwise.get("task_plan")
        if not isinstance(plan_binding, dict):
            raise ComposeError("composition receipt is missing its TaskPlan binding")
        plan_path, _, lineage = self._plan_bundle()
        plan_data = self._validate_plan(plan_path, lineage)
        if plan_binding.get("digest") != plan_data.get("digest"):
            raise ComposeError("composition receipt has a stale TaskPlan digest")
        material_binding = task_spec.get("materialization_receipt")
        if not isinstance(material_binding, dict):
            raise ComposeError("composition receipt is missing Task-Spec materialization evidence")
        material_path = safe_path(self.root, str(material_binding.get("path", "")))
        if sha256_file(material_path) != material_binding.get("sha256"):
            raise ComposeError("Task-Spec materialization receipt digest is stale")
        material = load_json(material_path)
        plan = load_json(plan_path)
        observed = self._validate_materialization(
            material, plan_data, plan, allow_taskspec_lifecycle=True
        )
        if receipt.get("tasks") != observed:
            raise ComposeError("composition receipt task set or hashes are stale")
        return receipt

    def _next_materialized_action(self, receipt: dict[str, Any]) -> str:
        tasks = receipt.get("tasks")
        if not isinstance(tasks, list):
            raise ComposeError("composition receipt task inventory is invalid")
        for task in tasks:
            if not isinstance(task, dict):
                continue
            task_id = str(task.get("task_id", ""))
            relative = str(task.get("path", ""))
            path = safe_path(self.root, relative)
            body = path.read_text(encoding="utf-8")
            if not re.search(r"(?m)^signed_off:\s*true\s*$", body):
                return f"taskspec gate --stamp {relative}"
            if re.search(r"(?m)^accepted:\s*true\s*$", body):
                continue
            profile = self.root / "cvg" / "execution" / task_id / "execution-profile.yaml"
            if not profile.is_file():
                return f"cvg bind --task {relative}"
            return f"cvg loop --issue {task_id}"
        return "all composed tasks are independently accepted"

    def materialize(self) -> tuple[str, str, bool]:
        if self.composition_path.is_file():
            receipt = self._verify_composition_receipt()
            return "COMPOSE=MATERIALIZED", self._next_materialized_action(receipt), False
        state = self._status()
        if not state.get("reviewed") or not state.get("task_plan") or not state.get("task_plan_lineage"):
            raise ComposeError("reviewed TaskPlan and lineage are required; run cvg compose preview")
        source = self._git_source()
        plan_path, lineage_path, lineage = self._plan_bundle()
        plan = load_json(plan_path)
        plan_data = self._validate_plan(plan_path, lineage)
        result, rc = self._taskspec("batch", "--plan", str(plan_path))
        material = result.get("data")
        if rc != 0 or result.get("ok") is not True or not isinstance(material, dict):
            raise ComposeError("Task-Spec materialization failed closed")
        tasks = self._validate_materialization(material, plan_data, plan)
        material_path = atomic_json(
            self.root, str(self.materialization_path.relative_to(self.root)), material
        )
        composition = self._build_composition_receipt(
            source, lineage_path, lineage, plan_data, material_path, tasks
        )
        atomic_json(self.root, str(self.composition_path.relative_to(self.root)), composition)
        self._verify_composition_receipt()
        return "COMPOSE=MATERIALIZED", "taskspec gate --stamp <task-spec>", True

    def status(self) -> tuple[str, str, bool]:
        state = self._status()
        if self.composition_path.exists():
            receipt = self._verify_composition_receipt()
            return "COMPOSE=MATERIALIZED", self._next_materialized_action(receipt), False
        if not state.get("delivery_plan"):
            return "COMPOSE=BLOCKED", "cvg compose prepare --source <recipe>", False
        if not state.get("reviewed"):
            return "COMPOSE=NEEDS_REVIEW", 'cvg compose review --reviewer <name> --reason "<reason>"', False
        if not state.get("task_plan") or not state.get("task_plan_lineage"):
            return "COMPOSE=PREVIEW_READY", "cvg compose preview", False
        return "COMPOSE=PREVIEW_READY", "cvg compose materialize", False


def parser() -> Parser:
    value = Parser(prog="cvg compose", add_help=False)
    value.add_argument("--project-root", required=True, type=pathlib.Path)
    value.add_argument("--cvg-version", required=True)
    value.add_argument("--seamwise-bin", default="")
    value.add_argument("--taskspec-bin", default="")
    subparsers = value.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare", add_help=False)
    prepare.add_argument("--source", required=True, type=pathlib.Path)
    review = subparsers.add_parser("review", add_help=False)
    review.add_argument("--reviewer", required=True)
    review.add_argument("--reason", required=True)
    subparsers.add_parser("preview", add_help=False)
    subparsers.add_parser("materialize", add_help=False)
    subparsers.add_parser("status", add_help=False)
    return value


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parser().parse_args(argv)
        coordinator = Coordinator(
            arguments.project_root,
            arguments.cvg_version,
            arguments.seamwise_bin,
            arguments.taskspec_bin,
        )
        if arguments.command == "prepare":
            token, next_action, changed = coordinator.prepare(arguments.source)
        elif arguments.command == "review":
            token, next_action, changed = coordinator.review(arguments.reviewer, arguments.reason)
        elif arguments.command == "preview":
            token, next_action, changed = coordinator.preview()
        elif arguments.command == "materialize":
            token, next_action, changed = coordinator.materialize()
        else:
            token, next_action, changed = coordinator.status()
        print(f"NEXT={next_action}")
        print(f"CHANGED={'true' if changed else 'false'}")
        print(token)
        return 0
    except ComposeError as exc:
        print(f"cvg compose: {exc}", file=sys.stderr)
        print("CHANGED=false")
        token = "COMPOSE=ENGINE_UNAVAILABLE" if exc.engine else "COMPOSE=BLOCKED"
        print(token)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
