#!/usr/bin/env python3
"""Strict checkpoint + exclusive lock for the Pass 8 loop kernel.

state.env is machine memory, not a shell script. The kernel used to `source`
it, which meant a crashed run's checkpoint was an arbitrary command injection
surface, and a half-written file could reset ITER/elapsed on resume. This
helper is the only reader and writer:

  load        parse KEY=VALUE with a closed key set; print the same shape
  save        atomic replace; elapsed/tokens/iterations never decrease
  hold-lock   exclusive flock, held until the parent pid dies
  pid-alive   exit 0 iff the pid exists
  check-bind  TaskHandoff/v3 must name this task, revision and base
  has-worktree
              the stored path is still a worktree of this repository

No scheduler. The kernel still owns dispatch, budgets and landing.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

INT_KEYS = frozenset(
    {
        "ITER",
        "STRIKES",
        "TOKENS_USED",
        "STARTED_AT",
        "ELAPSED_PRIOR",
        "KERNEL_PID",
        "ATTEMPT_PID",
        "BUDGET_SECONDS",
        "CHECKPOINT_AT",
    }
)
HEX_KEYS = frozenset({"LAST_FINGERPRINT", "SPEC_DIGEST", "HANDOFF_DIGEST", "LOOP_BASE_COMMIT"})
TOKEN_KEYS = frozenset(
    {
        "TASK_ID",
        "WT_BRANCH",
        "LOOP_BASE_BRANCH",
        "TERMINAL",
        "ATTEMPT_STATUS",
        "PHASE",
        "TIER2_VERDICT",
    }
)
PATH_KEYS = frozenset({"WORKTREE_DIR", "ATTEMPT_HANDOFF"})
ALLOWED = INT_KEYS | HEX_KEYS | TOKEN_KEYS | PATH_KEYS
MONOTONIC = ("ITER", "TOKENS_USED", "ELAPSED_PRIOR")

TERMINALS = frozenset(
    {
        "SETTLED",
        "LOCAL_SETTLED",
        "NO_OP",
        "BLOCKED",
        "STALLED",
        "EXHAUSTED",
        "CANCELLED",
        "ERROR",
    }
)
ATTEMPT_STATUSES = frozenset({"idle", "running", ""})
PHASES = frozenset({"attempt", "tier2", "settle", "landed", ""})
TIER2_VERDICTS = frozenset({"REFUTED", "UPHELD", "UNAVAILABLE", "NONE", ""})

INT_RE = re.compile(r"^[0-9]+$")
HEX_RE = re.compile(r"^[0-9a-fA-F]+$")
TASK_RE = re.compile(r"^[A-Za-z0-9._:-]+$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]*$")
LINE_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


def fail(message: str, code: int = 1) -> int:
    print(f"CHECKPOINT=INVALID\nerror: {message}", file=sys.stderr)
    return code


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def validate_value(key: str, value: str) -> str | None:
    if "\n" in value or "\r" in value or "\x00" in value:
        return None
    if key in INT_KEYS:
        return value if INT_RE.match(value) else None
    if key in HEX_KEYS:
        if key == "LAST_FINGERPRINT" and value in {"", "nofp"}:
            return value
        if key == "LOOP_BASE_COMMIT" and value == "":
            return value
        if key == "HANDOFF_DIGEST" and value == "":
            return value
        return value if HEX_RE.match(value) else None
    if key == "TASK_ID":
        return value if TASK_RE.match(value) else None
    if key == "TERMINAL":
        return value if value in TERMINALS or value == "" else None
    if key == "ATTEMPT_STATUS":
        return value if value in ATTEMPT_STATUSES else None
    if key == "PHASE":
        return value if value in PHASES else None
    if key == "TIER2_VERDICT":
        return value if value in TIER2_VERDICTS else None
    if key in {"WT_BRANCH", "LOOP_BASE_BRANCH"}:
        return value if BRANCH_RE.match(value) else None
    if key in PATH_KEYS:
        if value == "":
            return value
        if "$" in value or "`" in value or ";" in value or "|" in value:
            return None
        return value if Path(value).is_absolute() else None
    return None


def parse_state(text: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = LINE_RE.match(line)
        if match is None:
            raise ValueError(f"malformed checkpoint line: {raw!r}")
        key, value = match.group(1), match.group(2)
        if key not in ALLOWED:
            continue
        checked = validate_value(key, value)
        if checked is None:
            raise ValueError(f"invalid {key} value")
        parsed[key] = checked
    return parsed


def load_path(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"checkpoint is not a regular file: {path}")
    return parse_state(path.read_text(encoding="utf-8"))


def render(state: dict[str, str]) -> str:
    order = (
        "TASK_ID",
        "SPEC_DIGEST",
        "ITER",
        "STRIKES",
        "TOKENS_USED",
        "STARTED_AT",
        "ELAPSED_PRIOR",
        "LAST_FINGERPRINT",
        "LOOP_BASE_COMMIT",
        "LOOP_BASE_BRANCH",
        "WORKTREE_DIR",
        "WT_BRANCH",
        "ATTEMPT_HANDOFF",
        "HANDOFF_DIGEST",
        "CHECKPOINT_AT",
        "KERNEL_PID",
        "ATTEMPT_PID",
        "ATTEMPT_STATUS",
        "PHASE",
        "TIER2_VERDICT",
        "TERMINAL",
        "BUDGET_SECONDS",
    )
    lines = []
    for key in order:
        if key in state:
            lines.append(f"{key}={state[key]}")
    return "\n".join(lines) + ("\n" if lines else "")


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state.env.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def merge_monotonic(old: dict[str, str], new: dict[str, str]) -> dict[str, str]:
    merged = dict(new)
    for key in MONOTONIC:
        if key not in old or key not in merged:
            continue
        try:
            if int(merged[key]) < int(old[key]):
                merged[key] = old[key]
        except ValueError:
            merged[key] = old[key]
    if old.get("STARTED_AT") and merged.get("STARTED_AT"):
        try:
            if int(merged["STARTED_AT"]) > int(old["STARTED_AT"]) and int(old["STARTED_AT"]) > 0:
                merged["STARTED_AT"] = old["STARTED_AT"]
        except ValueError:
            merged["STARTED_AT"] = old["STARTED_AT"]
    if old.get("TASK_ID") and merged.get("TASK_ID") and old["TASK_ID"] != merged["TASK_ID"]:
        raise ValueError("checkpoint TASK_ID does not match save payload — no cross-task write")
    return merged


def cmd_load(path: Path) -> int:
    try:
        state = load_path(path)
    except (OSError, ValueError) as exc:
        return fail(str(exc))
    sys.stdout.write(render(state))
    return 0


def cmd_save(path: Path, assignments: list[str]) -> int:
    incoming: dict[str, str] = {}
    for item in assignments:
        match = LINE_RE.match(item)
        if match is None:
            return fail(f"malformed --set {item!r}")
        key, value = match.group(1), match.group(2)
        if key not in ALLOWED:
            return fail(f"unknown checkpoint key {key}")
        checked = validate_value(key, value)
        if checked is None:
            return fail(f"invalid {key} value")
        incoming[key] = checked
    old: dict[str, str] = {}
    if path.is_file() and not path.is_symlink():
        try:
            old = load_path(path)
        except (OSError, ValueError):
            old = {}
    try:
        merged = merge_monotonic(old, incoming)
        atomic_write(path, render(merged))
    except (OSError, ValueError) as exc:
        return fail(str(exc))
    print("CHECKPOINT=SAVED")
    return 0


def cmd_hold_lock(lock_path: Path, parent_pid: int) -> int:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        holder = ""
        try:
            holder = os.read(fd, 64).decode("utf-8", "replace").strip().splitlines()[0]
        except (OSError, IndexError):
            holder = ""
        if holder and INT_RE.match(holder):
            print(f"LOCK=BUSY holder={holder}", flush=True)
        else:
            print("LOCK=BUSY", flush=True)
        os.close(fd)
        return 1
    os.ftruncate(fd, 0)
    os.write(fd, f"{parent_pid}\n".encode("ascii"))
    os.fsync(fd)
    print("LOCK=HELD", flush=True)
    try:
        while pid_alive(parent_pid):
            time.sleep(0.25)
    except KeyboardInterrupt:
        pass
    return 0


def cmd_pid_alive(pid: int) -> int:
    return 0 if pid_alive(pid) else 1


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cmd_check_bind(handoff: Path, task_id: str, spec: Path, base: str) -> int:
    if not handoff.is_file() or handoff.is_symlink():
        return fail(f"handoff missing: {handoff}")
    if not spec.is_file():
        return fail(f"spec missing: {spec}")
    try:
        data = json.loads(handoff.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return fail(f"handoff is not JSON: {exc}")
    if not isinstance(data, dict):
        return fail("handoff is not an object")
    if data.get("contract") != "TaskHandoff/v3" or not isinstance(data.get("attempt"), dict) or not data["attempt"].get("id"):
        return fail("handoff has no native attempt identity")
    named = str(data.get("task_id") or "")
    if named != task_id:
        print(
            f"BIND=FAIL reason=task checkpoint is for {named}, this run is {task_id}",
            flush=True,
        )
        return 1
    digest = file_digest(spec)
    stored = str(data.get("spec_digest") or "")
    stored_hex = stored.split(":", 1)[-1]
    if stored_hex != digest:
        print("BIND=FAIL reason=spec revision changed since the handoff was issued", flush=True)
        return 1
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    stored_base = str(source.get("base_commit") or "")
    if not stored_base or (base and stored_base != base):
        print("BIND=FAIL reason=handoff base does not match the checkpoint base", flush=True)
        return 1
    print(f"BIND=OK spec_digest={digest}", flush=True)
    return 0


def cmd_has_worktree(worktree: Path, git_root: Path) -> int:
    import subprocess

    want = os.path.realpath(str(worktree))
    try:
        listed = subprocess.check_output(
            ["git", "-C", str(git_root), "worktree", "list", "--porcelain"],
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        return fail(f"git worktree list failed: {exc}")
    for line in listed.splitlines():
        if line.startswith("worktree "):
            if os.path.realpath(line.split(" ", 1)[1]) == want:
                print("WORKTREE=OK", flush=True)
                return 0
    print("WORKTREE=MISSING", flush=True)
    return 1


def cmd_digest(path: Path) -> int:
    if not path.is_file():
        return fail(f"not a file: {path}")
    print(file_digest(path), end="")
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd")

    load_p = sub.add_parser("load")
    load_p.add_argument("path")

    save_p = sub.add_parser("save")
    save_p.add_argument("path")
    save_p.add_argument("--set", action="append", default=[], dest="sets")

    hold_p = sub.add_parser("hold-lock")
    hold_p.add_argument("--lock", required=True)
    hold_p.add_argument("--pid", required=True, type=int)

    alive_p = sub.add_parser("pid-alive")
    alive_p.add_argument("pid", type=int)

    bind_p = sub.add_parser("check-bind")
    bind_p.add_argument("--handoff", required=True)
    bind_p.add_argument("--task-id", required=True)
    bind_p.add_argument("--spec", required=True)
    bind_p.add_argument("--base", default="")

    wt_p = sub.add_parser("has-worktree")
    wt_p.add_argument("--path", required=True)
    wt_p.add_argument("--git-root", required=True)

    dig_p = sub.add_parser("digest")
    dig_p.add_argument("path")

    args = parser.parse_args()
    if args.cmd == "load":
        return cmd_load(Path(args.path))
    if args.cmd == "save":
        return cmd_save(Path(args.path), args.sets)
    if args.cmd == "hold-lock":
        return cmd_hold_lock(Path(args.lock), args.pid)
    if args.cmd == "pid-alive":
        return cmd_pid_alive(args.pid)
    if args.cmd == "check-bind":
        return cmd_check_bind(Path(args.handoff), args.task_id, Path(args.spec), args.base)
    if args.cmd == "has-worktree":
        return cmd_has_worktree(Path(args.path), Path(args.git_root))
    if args.cmd == "digest":
        return cmd_digest(Path(args.path))
    return fail("unknown checkpoint command", 2)


if __name__ == "__main__":
    raise SystemExit(main())
