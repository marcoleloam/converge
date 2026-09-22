#!/usr/bin/env python3
"""Tier-2 verification — grade the work with an engine that did not do the work.

WHY THIS EXISTS
The task's own evals are authored by the same intelligence that implements
against them, then that intelligence grades itself. Code graders catch mechanical
wrongness; they do not catch a lookup table that satisfies the assertion, or an
implementation that skirts the spec's intent while passing its letter. The field
measures LLM-generated code carrying vulnerabilities at 9.8-42.1%, with surviving
AI-introduced defects in production past 110,000 — self-grading is not enough.

The defense borrows train/test separation from ML:
  * tier 1 — the sealed eval the worker CAN see (`Exit Check`).
  * tier 2 — a HOLDOUT set the worker cannot see, plus a different-FAMILY judge
    that reads only the diff, the spec's intent, and the holdout — never the
    worker's transcript — and is prompted to REFUTE.
  * tier 3 — a human, scaled by blast radius.

FAILS CLOSED. A missing, malformed, or timed-out verdict is never a pass. When no
independent engine exists the verdict is UNAVAILABLE, which is allowed for small
blast radius and blocks for large — with `--accept-unverified` as the single
audited exit.

Usage:
  verify-work.py --task <spec> [--judge codex|kimi|claude] [--base REF]
                 [--accept-unverified] [--repo DIR] [--json]
Token: CHECK_VERIFY=UPHELD|REFUTED|UNAVAILABLE|ERROR
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _runtime_contract import (  # noqa: E402
    ContractError,
    parse_frontmatter,
    resolve_inside_repo,
    resolve_repo,
    section,
    task_paths,
)

# Family matters more than vendor: a model refutes its own family's blind spots
# poorly, which is the same cross-family invariant Pass 4 enforces on plans.
FAMILY = {"claude": "anthropic", "codex": "openai", "kimi": "moonshot", "gemini": "google"}

# Paths whose blast radius makes independent verification mandatory.
SENSITIVE = (
    "auth", "login", "session", "token", "secret", "credential", "password",
    "payment", "billing", "invoice", "charge", "migration", "schema",
)


def blast_radius(paths: list[str], effort: str) -> str:
    """high when the change can hurt in ways an eval will not notice."""
    if any(any(word in p.lower() for word in SENSITIVE) for p in paths):
        return "high"
    if str(effort).upper() in {"L", "XL", "XXL"}:
        return "high"
    if len(paths) > 5:
        return "high"
    return "low"


def holdout_evals(body: str) -> str:
    """The `## Holdout` block — assertions the worker never sees."""
    return section(body, "Holdout")


def worker_family(frontmatter: dict) -> str:
    backend = str(frontmatter.get("execution_backend") or "").lower()
    return FAMILY.get(backend, "")


def pick_judge(requested: str | None, avoid_family: str) -> tuple[str, str]:
    """Choose an installed engine, preferring a DIFFERENT family. -> (engine, strength)"""
    installed = [e for e in ("codex", "kimi", "claude", "gemini") if shutil.which(e)]
    # Multi-provider harnesses (e.g. OMP) do not identify the worker's model
    # family. A different CLI is not proof of independent model lineage.
    if not avoid_family:
        if requested:
            return (requested, "unknown") if shutil.which(requested) else ("", "none")
        return (installed[0], "unknown") if installed else ("", "none")
    if requested:
        if not shutil.which(requested):
            return "", "none"
        strength = "independent" if FAMILY.get(requested) != avoid_family else "same-family"
        return requested, strength
    for engine in installed:
        if FAMILY.get(engine) != avoid_family:
            return engine, "independent"
    if installed:
        return installed[0], "same-family"
    return "", "none"


def work_diff(repo: Path, base: str | None) -> str:
    """Everything this run produced, whether it has been committed or not.

    `git diff <base>` alone was wrong for the position this check now occupies.
    Tier 2 runs BEFORE settlement — deliberately, since the whole point is to
    refuse to settle unverified work — and at that moment the work is still
    uncommitted. Worse, a `creates_paths` task's entire deliverable is UNTRACKED,
    and `git diff` does not mention untracked files at all. So on the first real
    green run the judge was handed an empty diff, reported ERROR, and the kernel
    (correctly, since it fails closed) blocked a task whose evals had all passed.
    The verifier was written for the post-hoc `cvg verify` case where the commit
    already existed; wiring it in front of settlement exposed the assumption.

    Three sources, unioned, mirroring check-path-policy.py's diff_paths():
      * <base>..worktree — committed and uncommitted changes to tracked files
      * HEAD..worktree   — in case base is absent or already equals HEAD
      * each untracked file, rendered against /dev/null so the judge sees the
        new code as a real unified diff rather than a filename
    """
    chunks: list[str] = []
    tracked = [["git", "diff", base], ["git", "diff", "HEAD"]] if base else [["git", "diff", "HEAD"]]
    for cmd in tracked:
        proc = subprocess.run(cmd, cwd=repo, text=True, capture_output=True, check=False)
        if proc.returncode == 0 and proc.stdout.strip():
            chunks.append(proc.stdout.rstrip())

    others = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=repo, text=True, capture_output=True, check=False,
    )
    for name in sorted(set(line.strip() for line in others.stdout.splitlines() if line.strip())):
        # Framework bookkeeping is not the task's work and must not be judged as
        # it — the same exemption the path policy makes, for the same reason.
        if name.startswith("cvg/loop/") or name == "cvg/STATE.md":
            continue
        shown = subprocess.run(
            ["git", "diff", "--no-index", "--", "/dev/null", name],
            cwd=repo, text=True, capture_output=True, check=False,
        )
        # --no-index exits 1 when the files differ, which is the normal case here.
        if shown.stdout.strip():
            chunks.append(shown.stdout.rstrip())

    # De-duplicate: `git diff <base>` and `git diff HEAD` overlap whenever base
    # IS HEAD, and handing the judge the same hunk twice invites it to read one
    # change as two.
    seen: set[str] = set()
    unique = []
    for chunk in chunks:
        if chunk not in seen:
            seen.add(chunk)
            unique.append(chunk)
    return "\n".join(unique).strip()


def build_prompt(task_id: str, intent: str, holdout: str, diff: str) -> str:
    """The judge sees the diff, the intent, and the holdout — never the transcript."""
    return f"""You are an adversarial verifier. Your default position is REFUTED.

You are reviewing a change for task {task_id}. You did NOT write this code and you
must not assume it is correct. Do not be agreeable.

STATED INTENT (what the spec says must become true):
{intent}

HOLDOUT CRITERIA (the implementer never saw these):
{holdout or "(none supplied)"}

THE DIFF:
{diff}

Decide whether the diff genuinely satisfies the stated intent AND would satisfy
the holdout criteria. Refute if you find any of:
  - hardcoded values, lookup tables, or special-cases that satisfy an assertion
    without implementing the behaviour
  - the letter of the eval met while the intent is skirted
  - error paths, edge cases, or failure modes the intent implies but the code ignores
  - changes outside what the intent requires

Reply with ONLY this JSON and nothing else:
{{"verdict": "UPHELD" | "REFUTED",
  "confidence": "high" | "medium" | "low",
  "findings": ["one concrete, checkable finding per entry"],
  "reasoning": "two sentences at most"}}
"""


def run_judge(engine: str, prompt: str, timeout: int) -> tuple[bool, str]:
    """Dispatch headless + read-only. Any failure is a failure — never a pass."""
    commands = {
        "codex": ["codex", "exec", "--skip-git-repo-check", prompt],
        "claude": ["claude", "-p", prompt],
        "kimi": ["kimi", "-p", prompt],
        "gemini": ["gemini", "-p", prompt],
    }
    cmd = commands.get(engine)
    if not cmd:
        return False, f"no dispatch recipe for engine: {engine}"
    try:
        # Vendor CLIs may inspect stdin or spawn helpers. Close stdin explicitly
        # and own a fresh process group so a timeout kills the whole dispatch,
        # not only its parent while a grandchild keeps stdout/stderr pipes open.
        proc = subprocess.Popen(
            cmd,
            text=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    proc.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    # A helper that deliberately escaped the process group can
                    # still own an inherited pipe. Close our read ends rather
                    # than letting an untrusted descendant erase the timeout.
                    if proc.stdout:
                        proc.stdout.close()
                    if proc.stderr:
                        proc.stderr.close()
                    try:
                        proc.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        pass
            return False, f"judge timed out after {timeout}s"
    except subprocess.TimeoutExpired:
        # Defensive only: the inner handler above owns normal timeouts.
        return False, f"judge timed out after {timeout}s"
    except OSError as exc:
        return False, f"judge could not start: {exc}"
    if proc.returncode != 0 and not stdout.strip():
        return False, f"judge exited {proc.returncode}: {stderr.strip()[:300]}"
    return True, stdout


def extract_verdict(raw: str) -> dict | None:
    """Real engines wrap JSON in prose; scan for the richest decodable object."""
    decoder = json.JSONDecoder()
    best = None
    for idx, ch in enumerate(raw):
        if ch != "{":
            continue
        try:
            obj, _ = decoder.raw_decode(raw[idx:])
        except ValueError:
            continue
        if isinstance(obj, dict) and "verdict" in obj:
            if best is None or len(obj) > len(best):
                best = obj
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description="Tier-2 adversarial verification of the work.")
    ap.add_argument("--task", required=True)
    ap.add_argument("--repo")
    ap.add_argument("--judge")
    ap.add_argument("--base", default="HEAD")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--accept-unverified", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    result: dict = {"schema": "cvg.verification.v1"}
    try:
        repo = resolve_repo(args.repo)
        task = resolve_inside_repo(args.task, repo)
        frontmatter, body = parse_frontmatter(task)
        task_id = str(frontmatter.get("id") or task.stem)
        paths = task_paths(frontmatter)
        radius = blast_radius(paths, str(frontmatter.get("effort", "")))
        holdout = holdout_evals(body)
        intent = section(body, "Behavior") or section(body, "Goal")

        result.update({"task": task_id, "blast_radius": radius,
                       "holdout_present": bool(holdout)})

        diff = work_diff(repo, args.base)
        if not diff:
            result.update({"verdict": "ERROR", "reason": "no diff to verify"})
            raise ContractError("there is no change to verify (empty diff)")

        judge, strength = pick_judge(args.judge, worker_family(frontmatter))
        result.update({"judge": judge or None, "independence": strength})

        if not judge:
            # No engine at all. Small change: allowed, recorded. Large: blocked.
            if radius == "low" or args.accept_unverified:
                result["verdict"] = "UNAVAILABLE"
                if args.accept_unverified:
                    result["waived"] = True
                print("No verifier engine is installed — tier-2 verification did not run.")
                if radius == "high":
                    print("WAIVED: high blast radius accepted without independent verification.")
                else:
                    print("Blast radius is low, so this is permitted and recorded.")
                print("CHECK_VERIFY=UNAVAILABLE")
                if args.json:
                    print(json.dumps(result, indent=2, sort_keys=True))
                return 0
            result["verdict"] = "ERROR"
            print("FAIL: no verifier engine installed and blast radius is HIGH.")
            print("  install a second engine (codex|kimi|claude), reduce the blast")
            print("  radius, or re-run with --accept-unverified to accept the risk.")
            print("CHECK_VERIFY=ERROR")
            if args.json:
                print(json.dumps(result, indent=2, sort_keys=True))
            return 1

        ok, raw = run_judge(judge, build_prompt(task_id, intent, holdout, diff), args.timeout)
        if not ok:
            result.update({"verdict": "ERROR", "reason": raw})
            print(f"FAIL: verification did not complete — {raw}")
            print("A verdict that cannot be obtained is never a pass.")
            print("CHECK_VERIFY=ERROR")
            if args.json:
                print(json.dumps(result, indent=2, sort_keys=True))
            return 1

        verdict = extract_verdict(raw)
        if not verdict or verdict.get("verdict") not in {"UPHELD", "REFUTED"}:
            result.update({"verdict": "ERROR", "reason": "judge returned no usable verdict"})
            print("FAIL: the judge returned no parseable verdict — failing closed.")
            print("CHECK_VERIFY=ERROR")
            if args.json:
                print(json.dumps(result, indent=2, sort_keys=True))
            return 1

        result.update({
            "verdict": verdict["verdict"],
            "confidence": verdict.get("confidence"),
            "findings": verdict.get("findings", []),
            "reasoning": verdict.get("reasoning", ""),
        })
        print(f"judge        {judge} ({strength})")
        print(f"blast radius {radius} · holdout {'present' if holdout else 'absent'}")
        for finding in result["findings"][:8]:
            print(f"  - {finding}")
        if result["reasoning"]:
            print(f"reasoning    {result['reasoning']}")
        if strength == "same-family":
            print("NOTE: judge shares the worker's model family — weaker independence.")
        if strength == "unknown":
            print("NOTE: worker model family is unknown — cross-family independence is not proven.")
        print(f"CHECK_VERIFY={result['verdict']}")
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["verdict"] == "UPHELD" else 1

    except ContractError as exc:
        print(f"FAIL: {exc}")
        print("CHECK_VERIFY=ERROR")
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
