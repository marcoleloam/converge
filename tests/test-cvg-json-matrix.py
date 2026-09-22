#!/usr/bin/env python3
"""Exercise every declared CLI form through the universal JSON boundary.

Mutations use the real global dry-run interception. Read-only calls execute in a
fresh, intentionally incomplete Git repository, so contract failures are also
serialized and their process status must match the envelope exactly.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import traceback

import jsonschema

ROOT = pathlib.Path(__file__).resolve().parents[1]
CVG = ROOT / "bin" / "cvg"
MATRIX_PATH = ROOT / "contracts" / "cli-command-matrix.json"
RESULT_SCHEMA_PATH = ROOT / "contracts" / "converge-cli-result-v1.schema.json"
ANSI = "\x1b["


def digest_tree(root: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        # Git may refresh the index stat cache during a read-only status query.
        # Hash repository semantics explicitly below instead of volatile .git
        # implementation bytes.
        if relative == ".git" or relative.startswith(".git/"):
            continue
        if path.is_symlink():
            digest.update(
                b"L\0" + relative.encode() + b"\0" + os.readlink(path).encode()
            )
        elif path.is_file():
            digest.update(b"F\0" + relative.encode() + b"\0" + path.read_bytes())
    logical_git_state = (
        ("HEAD", ["git", "-C", str(root), "rev-parse", "--verify", "HEAD"]),
        (
            "INDEX",
            [
                "git",
                "-C",
                str(root),
                "diff",
                "--cached",
                "--binary",
                "--no-ext-diff",
            ],
        ),
        (
            "CONFIG",
            ["git", "-C", str(root), "config", "--local", "--null", "--list"],
        ),
    )
    for label, command in logical_git_state:
        completed = subprocess.run(command, capture_output=True, check=True)
        digest.update(b"G\0" + label.encode() + b"\0" + completed.stdout)
    return digest.hexdigest()


def invoke(
    workspace: pathlib.Path,
    arguments: list[str],
    *,
    flags_first: bool,
    dry_run: bool,
    require_success: bool = False,
    environment: dict[str, str] | None = None,
) -> tuple[dict[str, object], int]:
    flags = ["--json", *(["--dry-run"] if dry_run else [])]
    command = [
        str(CVG),
        *(flags if flags_first else []),
        *arguments,
        *([] if flags_first else flags),
    ]
    completed = subprocess.run(
        command,
        cwd=workspace,
        env={
            **os.environ,
            "CVG_HOME": str(ROOT),
            "CVG_PROJECT_ROOT": str(workspace),
            "CVG_TASKSPEC_BIN": os.environ.get("CVG_TASKSPEC_BIN", "taskspec"),
            "CVG_SEAMWISE_BIN": os.environ.get("CVG_SEAMWISE_BIN", "seamwise"),
            "NO_COLOR": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            **(environment or {}),
        },
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert completed.stderr == "", f"JSON call leaked stderr: {completed.stderr!r}"
    assert ANSI not in completed.stdout, "JSON stdout contains ANSI"
    try:
        envelope = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(
            f"stdout is not exactly one JSON document: {completed.stdout!r}"
        ) from error
    jsonschema.validate(envelope, RESULT_SCHEMA)
    assert envelope["exit_code"] == completed.returncode
    assert envelope["ok"] is (completed.returncode == 0)
    assert envelope["dry_run"] is dry_run
    if dry_run:
        assert envelope["changed"] is False
    if require_success:
        assert completed.returncode == 0, envelope
    return envelope, completed.returncode


def usage_probe(name: str) -> list[str]:
    if name.startswith("compose "):
        subcommand = name.split()[1]
        return ["compose", subcommand, "--matrix-invalid"]
    if name.startswith("tasks plan"):
        return ["tasks", "plan", "--matrix-invalid"]
    if name.startswith("tasks new"):
        return ["tasks", "new"]
    if name.startswith("tasks validate --no-state"):
        return ["tasks", "validate", "--no-state"]
    if name.startswith("tasks validate"):
        return ["tasks", "validate"]
    if name.startswith("tasks gate --stamp"):
        return ["tasks", "gate", "--stamp"]
    if name.startswith("tasks gate"):
        return ["tasks", "gate"]
    if name.startswith("tasks accept"):
        return ["tasks", "accept"]
    if name.startswith("tasks dod"):
        return ["tasks", "dod"]
    if name.startswith("tasks metrics"):
        return ["tasks", "metrics", "--matrix-invalid"]
    if name.startswith("tasks rebuild-state"):
        return ["tasks", "rebuild-state", "--matrix-invalid"]
    if name.startswith("review "):
        return ["review", "--matrix-invalid"]
    if name.startswith("bind --check"):
        return ["bind", "--check", "--matrix-invalid"]
    if name.startswith("bind "):
        return ["bind", "--matrix-invalid"]
    if name.startswith("loop --gate-only"):
        return ["loop", "--gate-only", "--matrix-invalid"]
    if name.startswith("loop --estimate"):
        return ["loop", "--estimate", "--matrix-invalid"]
    if name.startswith("loop "):
        return ["loop", "--matrix-invalid"]
    if name.startswith("register --check"):
        return ["register", "--check", "--matrix-invalid"]
    if name.startswith("register "):
        return ["register", "--matrix-invalid"]
    if name.startswith("setup memory"):
        return ["setup", "memory", "--matrix-invalid"]
    if name.startswith("setup signing"):
        return ["setup", "signing", "--matrix-invalid"]
    if name.startswith("setup tracker"):
        return ["setup", "tracker", "invalid"]
    if name.startswith("setup key"):
        return ["setup", "key", "invalid"]
    if name.startswith("setup repo"):
        return ["setup", "repo", "--matrix-invalid"]
    if name.startswith("setup harness"):
        return ["setup", "harness", "--matrix-invalid"]
    if name.startswith("setup identity --map"):
        return ["setup", "identity", "--map"]
    if name.startswith("setup identity"):
        return ["setup", "identity", "--matrix-invalid"]
    if name.startswith("setup projection"):
        return ["setup", "projection", "--matrix-invalid"]
    if name.startswith("setup engines"):
        return ["setup", "engines", "--matrix-invalid"]
    if name == "setup":
        return ["setup", "--matrix-invalid"]
    if name.startswith("memory "):
        return ["memory", name.split()[1], "--matrix-invalid"]
    if name.startswith("doctor runtime-contract"):
        return ["doctor", "runtime-contract", "--matrix-invalid"]
    if name.startswith("doctor "):
        return ["doctor", name.split()[1], "--matrix-invalid"]
    if name == "doctor":
        return ["doctor", "--matrix-invalid"]
    if name.startswith("transition "):
        return ["transition"]
    if name.startswith("lesson "):
        return ["lesson", "--matrix-invalid"]
    if name.startswith("eval "):
        return ["eval"]
    return [name.split()[0], "--matrix-invalid"]


MATRIX = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
RESULT_SCHEMA = json.loads(RESULT_SCHEMA_PATH.read_text(encoding="utf-8"))
jsonschema.Draft202012Validator.check_schema(RESULT_SCHEMA)


def main() -> int:
    commands = MATRIX["commands"]
    assert MATRIX["contract"] == "ConvergeCLICommandMatrix/v1"
    assert MATRIX["command_count"] == len(commands)
    seen: set[str] = set()
    calls = 0
    contract_failures = 0
    failed_forms: list[str] = []
    usage_exit_anomalies: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cvg-json-matrix.") as temporary:
        parent = pathlib.Path(temporary)
        for number, row in enumerate(commands, 1):
            name = row["name"]
            assert name not in seen, f"duplicate command form: {name}"
            seen.add(name)
            workspace = parent / f"case-{number:02d}"
            workspace.mkdir()
            workspace = workspace.resolve()
            subprocess.run(["git", "init", "--quiet", str(workspace)], check=True)
            subprocess.run(
                ["git", "-C", str(workspace), "config", "user.name", "JSON Matrix"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(workspace),
                    "config",
                    "user.email",
                    "matrix@example.invalid",
                ],
                check=True,
            )
            (workspace / "README.md").write_text(
                "# JSON matrix fixture\n", encoding="utf-8"
            )
            (workspace / "cvg" / "tasks").mkdir(parents=True)
            (workspace / ".cvg").mkdir()
            (workspace / "cvg" / "tasks" / "T-20260602-golden.md").write_bytes(
                (ROOT / "tests" / "fixtures" / "T-20260602-golden.md").read_bytes()
            )
            (workspace / ".cvg" / "gate.yaml").write_bytes(
                (
                    ROOT
                    / "skills"
                    / "task-to-runtime-contract"
                    / "templates"
                    / "gate.yaml"
                ).read_bytes()
            )
            subprocess.run(["git", "-C", str(workspace), "add", "-A"], check=True)
            subprocess.run(
                ["git", "-C", str(workspace), "commit", "--quiet", "-m", "fixture"],
                check=True,
            )

            arguments = shlex.split(row["example"])
            assert arguments and arguments.pop(0) == "cvg"
            arguments = [
                item for item in arguments if item not in {"--json", "--dry-run"}
            ]
            arguments = [
                item.replace("tasks/T-...md", "cvg/tasks/T-20260602-golden.md")
                .replace("T-...md", "cvg/tasks/T-20260602-golden.md")
                .replace("T-...", "T-20260602-golden")
                for item in arguments
            ]
            before = digest_tree(workspace)
            first, first_rc = invoke(
                workspace,
                arguments,
                flags_first=True,
                dry_run=True,
                require_success=bool(row["mutating"]),
            )
            middle = digest_tree(workspace)
            second, second_rc = invoke(
                workspace,
                arguments,
                flags_first=False,
                dry_run=True,
                require_success=bool(row["mutating"]),
            )
            after = digest_tree(workspace)
            assert before == middle == after, (
                f"read-only/dry-run state changed for {name}"
            )
            assert (first["token"], first["verdict"], first_rc) == (
                second["token"],
                second["verdict"],
                second_rc,
            ), f"global flag position changed semantics for {name}"
            if first_rc != 0:
                contract_failures += 1
                failed_forms.append(name)
            calls += 2

            usage_before = digest_tree(workspace)
            usage, usage_rc = invoke(
                workspace,
                usage_probe(name),
                flags_first=(number % 2 == 0),
                dry_run=False,
            )
            usage_after = digest_tree(workspace)
            assert usage_before == usage_after, (
                f"usage failure changed state for {name}"
            )
            assert usage_rc != 0 and usage["error"] is not None, name
            if usage_rc == 2:
                assert usage["error"]["code"] == "USAGE_ERROR", name
            else:
                usage_exit_anomalies.append(f"{name}:{usage_rc}")
            calls += 1

            if name != "help" and not name.startswith("memory") and not name.startswith(
                "setup memory"
            ):
                missing_engine = {"CVG_TASKSPEC_BIN": "/definitely/missing/taskspec"}
                if name.startswith(
                    ("compose prepare", "compose review", "compose status")
                ) or name.startswith("decompose "):
                    missing_engine = {
                        "CVG_SEAMWISE_BIN": "/definitely/missing/seamwise"
                    }
                contract_before = digest_tree(workspace)
                contract, contract_rc = invoke(
                    workspace,
                    arguments,
                    flags_first=(number % 2 == 1),
                    dry_run=False,
                    environment=missing_engine,
                )
                contract_after = digest_tree(workspace)
                assert contract_before == contract_after, (
                    f"engine failure changed state for {name}"
                )
                assert contract_rc != 0 and contract["error"] is not None, name
                calls += 1

    print(
        f"JSON_MATRIX=PASS forms={len(seen)} calls={calls} usage_failures={len(seen)} "
        f"dependency_contract_failures={len(seen) - 1} "
        f"serialized_contract_failures={contract_failures}"
    )
    if failed_forms:
        print("JSON_MATRIX_CONTRACT_FAILURE_FORMS=" + " | ".join(failed_forms))
    if usage_exit_anomalies:
        print("JSON_MATRIX_USAGE_EXIT_ANOMALIES=" + " | ".join(usage_exit_anomalies))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.TimeoutExpired) as error:
        traceback.print_exc()
        print(f"JSON_MATRIX=FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
