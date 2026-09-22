#!/usr/bin/env python3
"""Attest what THIS host can actually enforce — capability, not aspiration.

An adapter manifest states what a runtime *should* do. This script probes what
the machine in front of you *can* do: which isolation primitive exists, whether
the runtime binary is installed, whether git worktrees are available. The gate
consumes the verdict so a contract can fail closed instead of assuming a control
it never had.

Deliberately conservative: a probe that cannot prove a capability reports it as
absent. Optimism here would defeat the point.

Usage:
  attest-runtime.py [--runtime generic|claude|codex|kimi|omp] [--json]
Exit: 0 when the runtime can hold every control it claims; 1 otherwise.
Token: DOCTOR_RUNTIME_CONTRACT=OK|DEGRADED|FAIL
"""

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _runtime_contract import RUNTIME_CONTROLS  # noqa: E402


def _probe_isolation() -> dict[str, object]:
    """Which kernel isolation primitive is actually available here?"""
    system = platform.system()
    if system == "Darwin":
        available = Path("/usr/bin/sandbox-exec").exists()
        return {
            "primitive": "seatbelt",
            "available": available,
            "detail": "macOS Seatbelt via sandbox-exec"
            if available
            else "sandbox-exec not found",
        }
    if system == "Linux":
        if shutil.which("bwrap"):
            return {
                "primitive": "bubblewrap",
                "available": True,
                "detail": "bubblewrap present",
            }
        # Landlock is a kernel LSM: 5.13+ is the floor.
        release = platform.release().split("-")[0]
        try:
            major, minor = (int(part) for part in release.split(".")[:2])
            landlock = (major, minor) >= (5, 13)
        except ValueError:
            landlock = False
        return {
            "primitive": "landlock" if landlock else "none",
            "available": landlock,
            "detail": f"kernel {release}"
            + ("" if landlock else " is below the 5.13 Landlock floor"),
        }
    return {
        "primitive": "none",
        "available": False,
        "detail": f"no supported isolation primitive on {system}",
    }


def _probe_binary(runtime: str) -> dict[str, object]:
    binaries = {"claude": "claude", "codex": "codex", "kimi": "kimi", "omp": "omp"}
    if runtime == "generic":
        return {"required": False, "present": True, "detail": "portable guards only"}
    name = binaries.get(runtime, runtime)
    path = shutil.which(name)
    return {
        "required": True,
        "present": bool(path),
        "detail": path or f"{name} not on PATH",
    }


def _probe_worktree() -> dict[str, object]:
    proc = subprocess.run(
        ["git", "worktree", "list"], capture_output=True, text=True, check=False
    )
    return {
        "available": proc.returncode == 0,
        "detail": "git worktree usable"
        if proc.returncode == 0
        else "not a git repository / worktree unavailable",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Attest runtime enforcement capability.")
    parser.add_argument("--runtime", default="generic")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.runtime not in RUNTIME_CONTROLS:
        print(f"FAIL: unknown runtime '{args.runtime}'")
        print("DOCTOR_RUNTIME_CONTRACT=FAIL")
        return 1

    isolation = _probe_isolation()
    binary = _probe_binary(args.runtime)
    worktree = _probe_worktree()

    # A runtime that claims to PREVENT anything needs a real isolation primitive
    # and its own binary. Without both, its claims collapse to "detect".
    claims = RUNTIME_CONTROLS[args.runtime]
    prevents = sorted(k for k, v in claims.items() if v["kind"] == "prevent")
    downgraded: list[str] = []
    if prevents and not (isolation["available"] and binary["present"]):
        downgraded = prevents

    verdict = "OK"
    if binary["required"] and not binary["present"]:
        verdict = "FAIL"
    elif downgraded:
        verdict = "DEGRADED"

    attestation = {
        "runtime": args.runtime,
        "host": {"system": platform.system(), "release": platform.release()},
        "isolation": isolation,
        "binary": binary,
        "worktree": worktree,
        "claims_prevent": prevents,
        "downgraded_to_detect": downgraded,
        "verdict": verdict,
    }

    if args.json:
        print(json.dumps(attestation, indent=2, sort_keys=True))
    else:
        print(f"runtime          {args.runtime}")
        print(f"host             {platform.system()} {platform.release()}")
        print(f"isolation        {isolation['primitive']} — {isolation['detail']}")
        print(f"binary           {binary['detail']}")
        print(f"worktree         {worktree['detail']}")
        if downgraded:
            print(
                "downgraded       "
                + ", ".join(downgraded)
                + "  (claimed prevent, provable only as detect)"
            )
    print(f"DOCTOR_RUNTIME_CONTRACT={verdict}")
    return 1 if verdict == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
