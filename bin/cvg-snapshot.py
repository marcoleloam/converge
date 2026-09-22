#!/usr/bin/env python3
"""Build the canonical, read-only Converge WorkspaceSnapshot 3.0.

The snapshot is a semantic projection, not an artifact transport:

* canonical files remain the source of truth;
* artifact contents are never emitted;
* every artifact is represented by a path, digest, entity binding, and
  provenance;
* method gates are executed through the local referee CLI, with no network;
* task frontmatter wins over the derived task index;
* optional lifecycle domains degrade to ``unavailable`` with typed issues;
* failures in the method/gate core abort the snapshot instead of guessing.

Only the Python standard library is used so the command remains portable with
the rest of the zero-runtime-dependency CLI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "3.0"
MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
MAX_ARTIFACTS = 4096
MAX_TASKS = 2000
MAX_SIGNALS = 1000
MAX_PROJECT_DOCUMENTS = 1024
MAX_SWIMLANES = 256
MAX_LEGS = 2000
MAX_SECTION_ITEMS = 64
MAX_DECOMPOSITION_PROSE = 1600
MAX_DECOMPOSITION_LIST_ITEM = 1200
CVG_TIMEOUT_SECONDS = 30

PASS_DEFINITIONS = (
    {
        "id": "pass-0",
        "order": 0,
        "label": "Capture",
        "summary": "Canonical problem, boundaries, and owner sign-off.",
        "command": "cvg capture",
        "args": ("capture",),
        "optional": False,
    },
    {
        "id": "pass-1",
        "order": 1,
        "label": "Intent",
        "summary": "Measurable requirements without implementation drift.",
        "command": "cvg intent",
        "args": ("intent",),
        "optional": False,
    },
    {
        "id": "pass-2",
        "order": 2,
        "label": "Structure",
        "summary": "Evidence-backed constraints encoded as architectural terrain.",
        "command": "cvg structure --final",
        "args": ("structure", "--final"),
        "optional": False,
    },
    {
        "id": "pass-3",
        "order": 3,
        "label": "Decompose",
        "summary": "A linked, seam-aware delivery plan across explicit lanes.",
        "command": "Seamwise decomposition evidence",
        "args": ("_observe-decomposition",),
        "optional": False,
    },
    {
        "id": "pass-4",
        "order": 4,
        "label": "Consensus",
        "summary": "Independent adversarial review with recorded owner decisions.",
        "command": "cvg review --check",
        "args": ("review", "--check"),
        "optional": False,
    },
    {
        "id": "pass-5",
        "order": 5,
        "label": "Tasking",
        "summary": "Delegable Task-Specs with bounded write surfaces.",
        "command": "cvg tasks plan",
        "args": (),
        "optional": False,
    },
    {
        "id": "pass-6",
        "order": 6,
        "label": "Register",
        "summary": "Optional tracker projection from the sealed Task-Spec graph.",
        "command": "cvg register --check --tracker <tracker>",
        "args": (),
        "optional": True,
    },
    {
        "id": "pass-7",
        "order": 7,
        "label": "Bind",
        "summary": "Fresh runtime contracts bound to evidence and policy.",
        "command": "cvg bind --check --profile <profile>",
        "args": (),
        "optional": False,
    },
    {
        "id": "pass-8",
        "order": 8,
        "label": "Loop",
        "summary": "Bounded execution settles through runnable evidence.",
        "command": "cvg loop --gate-only --issue <id>",
        "args": (),
        "optional": False,
    },
)

LANE_ORDERS = {
    "FULL": (0, 1, 2, 3, 4, 5, 7, 8),
    "NORMAL": (1, 2, 5, 7, 8),
    "FAST": (5, 7, 8),
}

ACTION_POLICY = {
    0: {"mutation": "non_mutating", "dryRunSupported": True},
    1: {"mutation": "non_mutating", "dryRunSupported": True},
    2: {"mutation": "non_mutating", "dryRunSupported": True},
    3: {"mutation": "non_mutating", "dryRunSupported": True},
    4: {"mutation": "non_mutating", "dryRunSupported": True},
    5: {"mutation": "non_mutating", "dryRunSupported": True},
    6: {"mutation": "non_mutating", "dryRunSupported": True},
    7: {"mutation": "non_mutating", "dryRunSupported": True},
    8: {"mutation": "non_mutating", "dryRunSupported": True},
}

METHOD_EDGES = (
    {"id": "pass-0-pass-1", "source": "pass-0", "target": "pass-1", "kind": "required"},
    {"id": "pass-1-pass-2", "source": "pass-1", "target": "pass-2", "kind": "required"},
    {"id": "pass-2-pass-3", "source": "pass-2", "target": "pass-3", "kind": "required"},
    {"id": "pass-3-pass-4", "source": "pass-3", "target": "pass-4", "kind": "required"},
    {"id": "pass-4-pass-5", "source": "pass-4", "target": "pass-5", "kind": "required"},
    {"id": "pass-5-pass-6", "source": "pass-5", "target": "pass-6", "kind": "optional"},
    {"id": "pass-6-pass-7", "source": "pass-6", "target": "pass-7", "kind": "optional"},
    {"id": "pass-5-pass-7", "source": "pass-5", "target": "pass-7", "kind": "bypass"},
    {"id": "pass-7-pass-8", "source": "pass-7", "target": "pass-8", "kind": "required"},
)

STATUS_KEYS = ("ready", "in_progress", "blocked", "done", "parked")
SEVERITY_ORDER = {"blocking": 0, "error": 1, "warning": 2, "info": 3}


class SnapshotError(RuntimeError):
    """A core snapshot failure for which no authoritative projection exists."""


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def stable_id(prefix: str, *parts: object, length: int = 20) -> str:
    material = "\0".join(str(part) for part in parts)
    return f"{prefix}_{sha256_bytes(material.encode('utf-8'))[:length]}"


def canonical_digest_value(value: Any) -> Any:
    """Remove observation-time fields recursively before hashing."""
    if isinstance(value, list):
        normalized = [canonical_digest_value(item) for item in value]
        if all(isinstance(item, dict) and "id" in item for item in normalized):
            return sorted(normalized, key=lambda item: str(item["id"]))
        if all(isinstance(item, (str, int, float, bool)) or item is None for item in normalized):
            return sorted(
                normalized,
                key=lambda item: json.dumps(item, ensure_ascii=False, sort_keys=True),
            )
        return normalized
    if isinstance(value, dict):
        return {
            key: canonical_digest_value(value[key])
            for key in sorted(value)
            if key not in {"snapshotId", "observedAt"}
        }
    return value


def compute_snapshot_id(snapshot: dict[str, Any]) -> str:
    canonical = json.dumps(
        canonical_digest_value(snapshot),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return f"ws3_{sha256_bytes(canonical)[:32]}"


def within(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def clean_scalar(value: str) -> Any:
    stripped = value.strip()
    if not stripped:
        return ""
    if (
        len(stripped) >= 2
        and stripped[0] == stripped[-1]
        and stripped[0] in {"'", '"'}
    ):
        return stripped[1:-1]
    lowered = stripped.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"
    if lowered in {"null", "none", "~"}:
        return None
    if re.fullmatch(r"-?[0-9]+", stripped):
        try:
            return int(stripped)
        except ValueError:
            pass
    if stripped.startswith("[") and stripped.endswith("]"):
        body = stripped[1:-1].strip()
        if not body:
            return []
        return [clean_scalar(item) for item in body.split(",")]
    return stripped


def clip_text(value: object, limit: int = 320) -> str:
    compact = " ".join(str(value).split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1].rstrip() + "…"


def parse_frontmatter(text: str) -> dict[str, Any]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError("missing YAML frontmatter")
    try:
        end = next(index for index in range(1, len(lines)) if lines[index].strip() == "---")
    except StopIteration as exc:
        raise ValueError("unterminated YAML frontmatter") from exc

    result: dict[str, Any] = {}
    current_list: str | None = None
    for raw in lines[1:end]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.startswith((" ", "\t")):
            if current_list and raw.strip().startswith("- "):
                result.setdefault(current_list, []).append(clean_scalar(raw.strip()[2:]))
            continue
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:\s*(.*))?$", raw)
        if not match:
            continue
        key, value = match.group(1), match.group(2) or ""
        if value.strip() == "":
            result[key] = []
            current_list = key
        else:
            result[key] = clean_scalar(value)
            current_list = None
    return result


def parse_env_state(text: str) -> dict[str, str]:
    allowed = {
        "ITER",
        "STRIKES",
        "TOKENS_USED",
        "STARTED_AT",
        "ELAPSED_PRIOR",
        "LAST_FINGERPRINT",
    }
    state: dict[str, str] = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([A-Z_][A-Z0-9_]*)=(.*)", line)
        if match and match.group(1) in allowed:
            state[match.group(1)] = match.group(2).strip().strip("'\"")
    return state


class IssueCollector:
    def __init__(self) -> None:
        self._items: list[dict[str, Any]] = []
        self._seen: set[str] = set()

    def add(
        self,
        *,
        code: str,
        severity: str,
        domain: str,
        message: str,
        entity: dict[str, str] | None = None,
        remediation: str | None = None,
        artifact_ids: Iterable[str] = (),
    ) -> str:
        issue_id = stable_id(
            "issue",
            code,
            domain,
            entity.get("kind") if entity else "",
            entity.get("id") if entity else "",
            message,
        )
        if issue_id in self._seen:
            return issue_id
        self._seen.add(issue_id)
        item: dict[str, Any] = {
            "id": issue_id,
            "code": code,
            "severity": severity,
            "domain": domain,
            "message": message,
            "artifactIds": sorted(set(artifact_ids)),
        }
        if entity:
            item["entity"] = entity
        if remediation:
            item["remediation"] = remediation
        self._items.append(item)
        return issue_id

    def values(self) -> list[dict[str, Any]]:
        return sorted(
            self._items,
            key=lambda item: (
                SEVERITY_ORDER.get(item["severity"], 99),
                item["domain"],
                item["code"],
                item["id"],
            ),
        )

    def drop_entity_kinds(self, kinds: set[str]) -> None:
        for item in self._items:
            entity = item.get("entity")
            if isinstance(entity, dict) and entity.get("kind") in kinds:
                item.pop("entity", None)


class ArtifactCollector:
    def __init__(self, root: Path, observed_at: str, issues: IssueCollector) -> None:
        self.root = root.resolve()
        self.observed_at = observed_at
        self.issues = issues
        self._items: dict[str, dict[str, Any]] = {}

    def relative(self, path: Path) -> str:
        resolved_parent = path.parent.resolve()
        if not within(self.root, resolved_parent):
            raise ValueError("path escapes the project root")
        return (resolved_parent / path.name).relative_to(self.root).as_posix()

    def add(
        self,
        path: Path,
        *,
        label: str,
        kind: str,
        entity: dict[str, str] | None = None,
        truth_class: str = "canonical",
    ) -> str | None:
        try:
            relative = self.relative(path)
        except (OSError, ValueError):
            self.issues.add(
                code="ARTIFACT_OUTSIDE_PROJECT",
                severity="error",
                domain="project",
                message=f"Artifact path is outside the project root: {path}",
                remediation="Move canonical evidence inside the project workspace.",
            )
            return None
        if path.is_symlink():
            self.issues.add(
                code="ARTIFACT_SYMLINK_IGNORED",
                severity="warning",
                domain="project",
                message=f"Symlinked artifact was ignored: {relative}",
                remediation="Use a regular file inside the project workspace.",
            )
            return None
        try:
            stat = path.stat()
        except OSError as exc:
            self.issues.add(
                code="ARTIFACT_UNREADABLE",
                severity="error",
                domain="project",
                message=f"Artifact cannot be read: {relative} ({exc})",
            )
            return None
        if not path.is_file():
            return None
        if stat.st_size > MAX_ARTIFACT_BYTES:
            self.issues.add(
                code="ARTIFACT_TOO_LARGE",
                severity="warning",
                domain="project",
                message=f"Artifact exceeds the snapshot digest limit: {relative}",
                remediation=f"Keep canonical evidence below {MAX_ARTIFACT_BYTES} bytes.",
            )
            return None
        if len(self._items) >= MAX_ARTIFACTS:
            raise SnapshotError(f"artifact limit exceeded ({MAX_ARTIFACTS})")
        try:
            digest = sha256_bytes(path.read_bytes())
        except OSError as exc:
            self.issues.add(
                code="ARTIFACT_UNREADABLE",
                severity="error",
                domain="project",
                message=f"Artifact cannot be hashed: {relative} ({exc})",
            )
            return None
        artifact_id = stable_id("artifact", relative)
        item: dict[str, Any] = {
            "id": artifact_id,
            "label": label,
            "path": relative,
            "kind": kind,
            "sha256": digest,
            "provenance": {
                "sourceKind": "file",
                "sourceRef": relative,
                "observedAt": self.observed_at,
                "truthClass": truth_class,
            },
        }
        if entity:
            item["entity"] = entity
        self._items[artifact_id] = item
        return artifact_id

    def values(self) -> list[dict[str, Any]]:
        return sorted(self._items.values(), key=lambda item: (item["path"], item["id"]))

    def drop_entity_kinds(self, kinds: set[str]) -> None:
        for item in self._items.values():
            entity = item.get("entity")
            if isinstance(entity, dict) and entity.get("kind") in kinds:
                item.pop("entity", None)


def read_text(path: Path) -> str:
    if path.is_symlink():
        raise ValueError("symlinked files are not parsed")
    size = path.stat().st_size
    if size > MAX_TEXT_BYTES:
        raise ValueError(f"file exceeds {MAX_TEXT_BYTES} byte parse limit")
    return path.read_text(encoding="utf-8", errors="strict")


def resolve_lane(root: Path) -> str:
    """Resolve the machine-local lane choice without executing configuration."""
    config = root / ".cvg" / "config"
    if not config.exists():
        return "FULL"
    if config.is_symlink() or not config.is_file():
        raise SnapshotError("`.cvg/config` must be a regular, non-symlink file")
    try:
        if config.stat().st_size > 65536:
            raise SnapshotError("`.cvg/config` exceeds the 65536-byte safety limit")
        text = config.read_text(encoding="utf-8", errors="strict")
    except (OSError, UnicodeError) as exc:
        raise SnapshotError(f"cannot read `.cvg/config`: {exc}") from exc

    configured: list[tuple[int, str]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        match = re.fullmatch(r"(?:LANE|lane)=(.*)", line)
        if not match:
            continue
        value = match.group(1)
        if value not in LANE_ORDERS:
            raise SnapshotError(
                f"invalid lane in `.cvg/config` line {line_number}: "
                "expected FULL, NORMAL, or FAST"
            )
        configured.append((line_number, value))

    if not configured:
        return "FULL"
    distinct = {value for _, value in configured}
    if len(distinct) != 1:
        lines = ", ".join(str(line_number) for line_number, _ in configured)
        raise SnapshotError(
            f"conflicting lane choices in `.cvg/config` lines {lines}"
        )
    return configured[0][1]


def iter_regular_files(root: Path, pattern: str = "*") -> list[Path]:
    if not root.is_dir() or root.is_symlink():
        return []
    files: list[Path] = []
    for current, directories, names in os.walk(root, followlinks=False):
        current_path = Path(current)
        directories[:] = sorted(
            name
            for name in directories
            if not (current_path / name).is_symlink()
        )
        for name in sorted(names):
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                continue
            if path.match(pattern):
                files.append(path)
    return files


def iter_bounded_documents(
    root: Path,
    *,
    suffixes: set[str],
    limit: int,
) -> tuple[list[Path], bool]:
    """Return a deterministic, symlink-safe document inventory with a hard cap."""
    if not root.is_dir() or root.is_symlink():
        return [], False
    files: list[Path] = []
    for current, directories, names in os.walk(root, followlinks=False):
        current_path = Path(current)
        directories[:] = sorted(
            name
            for name in directories
            if not (current_path / name).is_symlink()
        )
        for name in sorted(names):
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                continue
            if path.suffix.lower() not in suffixes:
                continue
            if len(files) >= limit:
                return files, True
            files.append(path)
    return files, False


DECOMPOSITION_TREE_PARTS = (
    ("cvg", "swimlanes"),
    ("cvg", "sketch"),
    ("swimlanes",),
    ("sketch",),
)


def lane_prd_paths(tree: Path) -> list[Path]:
    """Find immediate lane PRDs using the same content-first rule as `cvg`."""
    if not tree.is_dir() or tree.is_symlink():
        return []
    paths: list[Path] = []
    try:
        directories = sorted(
            (
                child
                for child in tree.iterdir()
                if child.is_dir() and not child.is_symlink() and not child.name.startswith(".")
            ),
            key=lambda item: item.name,
        )
    except OSError:
        return []
    for directory in directories:
        canonical = directory / "_lane.md"
        if canonical.is_file() or canonical.is_symlink():
            paths.append(canonical)
        for legacy in sorted(directory.glob("*.plan.md"), key=lambda item: item.name):
            if legacy.is_file() or legacy.is_symlink():
                paths.append(legacy)
    return paths


def discover_decomposition_tree(
    root: Path,
    issues: IssueCollector,
) -> dict[str, Any]:
    candidates = [root.joinpath(*parts) for parts in DECOMPOSITION_TREE_PARTS]
    populated = [path for path in candidates if lane_prd_paths(path)]
    if len(populated) > 1:
        relative = [path.relative_to(root).as_posix() for path in populated]
        issues.add(
            code="DECOMPOSITION_TREE_AMBIGUOUS",
            severity="error",
            domain="decomposition",
            message=(
                "Multiple non-empty swimlane trees were observed: "
                + ", ".join(relative)
            ),
            remediation="Keep one canonical swimlane tree or pass an explicit tree to the Pass 3 tools.",
        )
        return {
            "availability": "unavailable",
            "root": None,
            "roots": populated,
        }
    if populated:
        return {
            "availability": "available",
            "root": populated[0],
            "roots": populated,
        }
    existing = [path for path in candidates if path.is_dir() and not path.is_symlink()]
    return {
        "availability": "empty",
        "root": existing[0] if existing else None,
        "roots": [],
    }


def strip_inline_markdown(value: str, limit: int = 320) -> str:
    text = re.sub(r"!\[([^]]*)\]\([^)]+\)", r"\1", value)
    text = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", text)
    text = text.replace("**", "").replace("__", "").replace("~~", "").replace("`", "")
    text = re.sub(r"^\s*>\s?", "", text)
    return clip_text(text, limit)


def markdown_sections(text: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            if current is not None:
                sections[current].append(line)
            continue
        if not fenced:
            heading = re.match(r"^##\s+(.+?)\s*$", line)
            if heading:
                current = strip_inline_markdown(heading.group(1)).lower()
                sections.setdefault(current, [])
                continue
        if current is not None:
            sections[current].append(line)
    return {key: "\n".join(lines).strip() for key, lines in sections.items()}


def section_with_prefix(sections: dict[str, str], prefix: str) -> str:
    wanted = prefix.lower()
    for key, value in sections.items():
        if key.startswith(wanted):
            return value
    return ""


def first_markdown_paragraph(
    value: str, limit: int = MAX_DECOMPOSITION_PROSE
) -> str | None:
    without_comments = re.sub(r"<!--.*?-->", "", value, flags=re.DOTALL)
    lines: list[str] = []
    fenced = False
    for raw in without_comments.splitlines():
        line = raw.strip()
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced or not line:
            if lines:
                break
            continue
        if line.startswith(("|", "#", "---")):
            if lines:
                break
            continue
        if re.match(r"^[-*+]\s+", line):
            if lines:
                break
            continue
        lines.append(strip_inline_markdown(line))
    if not lines:
        return None
    return clip_text(" ".join(lines), limit)


def markdown_list_items(
    value: str,
    limit: int = MAX_SECTION_ITEMS,
    item_limit: int = MAX_DECOMPOSITION_LIST_ITEM,
) -> list[str]:
    without_comments = re.sub(r"<!--.*?-->", "", value, flags=re.DOTALL)
    items: list[str] = []
    current: list[str] | None = None
    fenced = False

    def finish_item() -> bool:
        nonlocal current
        if current:
            item = strip_inline_markdown(" ".join(current), item_limit)
            if item and item not in items:
                items.append(item)
        current = None
        return len(items) >= limit

    for raw in without_comments.splitlines():
        line = raw.strip()
        if line.startswith("```"):
            if finish_item():
                break
            fenced = not fenced
            continue
        if fenced:
            continue
        match = re.match(r"^\s*[-*+]\s+(.+)$", raw)
        if match:
            if finish_item():
                break
            current = [match.group(1).strip()]
            continue
        if current is not None:
            if not line or line.startswith(("|", "#", "---")):
                if finish_item():
                    break
            elif raw[:1].isspace():
                current.append(line)
            else:
                if finish_item():
                    break
    finish_item()
    return items


def frontmatter_strings(value: Any, limit: int = MAX_SECTION_ITEMS) -> list[str]:
    if value is None or value == "":
        return []
    candidates = value if isinstance(value, list) else [value]
    result: list[str] = []
    for candidate in candidates:
        if not isinstance(candidate, (str, int)):
            continue
        item = clip_text(candidate, 160)
        if item and item not in result:
            result.append(item)
            if len(result) >= limit:
                break
    return result


def extract_contract(text: str, label: str) -> str | None:
    code = re.search(rf"{re.escape(label)}:\s*`([^`]+)`", text, flags=re.IGNORECASE)
    if code:
        return clip_text(code.group(1), 240)
    line = re.search(
        rf"{re.escape(label)}:\s*(.+?)(?=\s+(?:Input|Output) contract:|$)",
        text,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    return strip_inline_markdown(line.group(1)) if line else None


def blocking_question_count(section: str) -> int:
    count = 0
    for raw in section.splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 2 or set("".join(cells)) <= {"-", ":"}:
            continue
        if cells[-1].lower() in {"yes", "y", "true", "blocking"}:
            count += 1
    return count


def lane_purpose(text: str) -> str | None:
    lines = text.splitlines()
    start = next(
        (index + 1 for index, line in enumerate(lines) if line.lower().startswith("lane-meta:")),
        0,
    )
    for raw in lines[start:]:
        line = raw.strip()
        if line.startswith("## "):
            break
        if (
            not line
            or line.startswith((">", "<!--", "Input contract:", "Output contract:"))
        ):
            continue
        if line.lower().startswith("lane-meta:"):
            continue
        return strip_inline_markdown(line)
    return None


def leg_title(text: str, leg_id: str) -> str:
    heading = next(
        (strip_inline_markdown(match.group(1)) for line in text.splitlines() if (match := re.match(r"^#\s+(.+)$", line))),
        leg_id,
    )
    remainder = re.sub(
        rf"^{re.escape(leg_id)}(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?\s*[—-]\s*",
        "",
        heading,
        flags=re.IGNORECASE,
    )
    return clip_text(remainder or heading, 200)


def parse_decomposition(
    root: Path,
    discovery: dict[str, Any],
    artifacts: ArtifactCollector,
    issues: IssueCollector,
) -> dict[str, Any]:
    empty = {"availability": "empty", "swimlanes": [], "legs": [], "edges": []}
    if discovery["availability"] == "empty":
        return empty
    if discovery["availability"] == "unavailable" or discovery["root"] is None:
        return {**empty, "availability": "unavailable"}

    tree: Path = discovery["root"]
    swimlanes: list[dict[str, Any]] = []
    legs: list[dict[str, Any]] = []
    invalid = False
    lane_ids: set[str] = set()
    leg_ids: set[str] = set()

    try:
        lane_directories = sorted(
            (
                child
                for child in tree.iterdir()
                if child.is_dir() and not child.is_symlink() and not child.name.startswith(".")
            ),
            key=lambda item: item.name,
        )
    except OSError as exc:
        issues.add(
            code="DECOMPOSITION_TREE_UNREADABLE",
            severity="error",
            domain="decomposition",
            message=f"The swimlane tree cannot be read: {exc}",
        )
        return {**empty, "availability": "unavailable"}

    if len(lane_directories) > MAX_SWIMLANES:
        invalid = True
        issues.add(
            code="DECOMPOSITION_LANE_LIMIT_EXCEEDED",
            severity="error",
            domain="decomposition",
            message=f"The swimlane tree exceeds the {MAX_SWIMLANES}-lane snapshot limit.",
            remediation="Split or archive obsolete lane plans before opening the Cockpit.",
        )
        lane_directories = lane_directories[:MAX_SWIMLANES]

    for directory in lane_directories:
        prds = [path for path in lane_prd_paths(tree) if path.parent == directory]
        leg_files = sorted(
            (
                path
                for path in directory.glob("*.md")
                if re.search(r"(?:^|-)leg-[0-9]{2}-[a-z0-9][a-z0-9-]*\.md$", path.name)
            ),
            key=lambda item: item.name,
        )
        if not prds:
            if leg_files:
                invalid = True
                issues.add(
                    code="DECOMPOSITION_ORPHAN_LEGS",
                    severity="error",
                    domain="decomposition",
                    message=f"Leg files have no lane PRD under {directory.relative_to(root).as_posix()}.",
                    remediation="Add _lane.md or the legacy <lane>.plan.md parent.",
                )
            continue
        if len(prds) != 1:
            invalid = True
            issues.add(
                code="DECOMPOSITION_LANE_PRD_AMBIGUOUS",
                severity="error",
                domain="decomposition",
                message=f"Multiple lane PRDs were observed under {directory.relative_to(root).as_posix()}.",
                remediation="Keep exactly one _lane.md or legacy *.plan.md per lane directory.",
            )
            continue
        prd = prds[0]
        try:
            text = read_text(prd)
        except (OSError, UnicodeError, ValueError) as exc:
            invalid = True
            issues.add(
                code="DECOMPOSITION_LANE_UNREADABLE",
                severity="error",
                domain="decomposition",
                message=f"Lane PRD cannot be parsed: {prd.relative_to(root).as_posix()} ({exc})",
            )
            continue

        heading_match = next(
            (re.match(r"^#\s+Swimlane\s*[·:-]\s*([a-z0-9]+(?:-[a-z0-9]+)*)\s*$", line, re.IGNORECASE) for line in text.splitlines() if line.startswith("# ")),
            None,
        )
        heading_match = heading_match if heading_match and heading_match.group(1) else None
        meta_line = next(
            (line for line in text.splitlines() if line.lower().startswith("lane-meta:")),
            "",
        )
        thread_match = re.search(r"\bthread=(yes|no)\b", meta_line, re.IGNORECASE)
        risk_match = re.search(r"\brisk=(low|med|high)\b", meta_line, re.IGNORECASE)
        owner_match = re.search(r"\bowner=([^·|\n]+)", meta_line, re.IGNORECASE)
        owner = clip_text(owner_match.group(1), 120).strip() if owner_match else ""
        if not heading_match or not thread_match or not risk_match or not owner or "<" in owner:
            invalid = True
            issues.add(
                code="DECOMPOSITION_LANE_IDENTITY_INVALID",
                severity="error",
                domain="decomposition",
                message=f"Lane identity or lane-meta is invalid: {prd.relative_to(root).as_posix()}.",
                remediation="Provide '# Swimlane · <kebab-seam>' and real thread, risk, and owner values.",
            )
            continue
        seam_name = heading_match.group(1).lower()
        lane_id = seam_name if seam_name.startswith("swimlane-") else f"swimlane-{seam_name}"
        if lane_id in lane_ids:
            invalid = True
            issues.add(
                code="DECOMPOSITION_LANE_ID_DUPLICATE",
                severity="error",
                domain="decomposition",
                message=f"Duplicate swimlane id was observed: {lane_id}.",
            )
            continue
        lane_ids.add(lane_id)
        lane_artifact_id = artifacts.add(
            prd,
            label=f"Swimlane · {seam_name}",
            kind="plan",
            entity={"kind": "swimlane", "id": lane_id},
        )
        sections = markdown_sections(text)
        consumed_section = section_with_prefix(sections, "the interface this lane consumes")
        evolution_match = re.search(
            r"\*\*Seam evolution:\*\*\s*(.+?)(?=\n\s*\n|\n---|\n##|$)",
            text,
            flags=re.IGNORECASE | re.DOTALL,
        )
        lane_record = {
            "id": lane_id,
            "label": f"Swimlane · {seam_name}",
            "purpose": lane_purpose(text),
            "thread": thread_match.group(1).lower() == "yes",
            "risk": risk_match.group(1).lower(),
            "owner": owner,
            "seam": {
                "rationale": first_markdown_paragraph(section_with_prefix(sections, "seam")),
                "inputContract": extract_contract(text, "Input contract"),
                "outputContract": extract_contract(text, "Output contract"),
                "consumedInterface": first_markdown_paragraph(consumed_section),
                "evolution": (
                    strip_inline_markdown(
                        evolution_match.group(1), MAX_DECOMPOSITION_PROSE
                    )
                    if evolution_match
                    else None
                ),
            },
            "legIds": [],
            "blockingQuestionCount": blocking_question_count(
                section_with_prefix(sections, "open questions")
            ),
            "artifactIds": [lane_artifact_id] if lane_artifact_id else [],
        }
        swimlanes.append(lane_record)

        for leg_path in leg_files:
            if len(legs) >= MAX_LEGS:
                invalid = True
                issues.add(
                    code="DECOMPOSITION_LEG_LIMIT_EXCEEDED",
                    severity="error",
                    domain="decomposition",
                    message=f"The decomposition exceeds the {MAX_LEGS}-leg snapshot limit.",
                    remediation="Split or archive obsolete leg plans before opening the Cockpit.",
                )
                break
            try:
                leg_text = read_text(leg_path)
                frontmatter = parse_frontmatter(leg_text)
            except (OSError, UnicodeError, ValueError) as exc:
                invalid = True
                issues.add(
                    code="DECOMPOSITION_LEG_UNREADABLE",
                    severity="error",
                    domain="decomposition",
                    message=f"Leg cannot be parsed: {leg_path.relative_to(root).as_posix()} ({exc})",
                )
                continue
            leg_id = frontmatter.get("leg")
            leg_lane_id = frontmatter.get("swimlane")
            status = frontmatter.get("status")
            if (
                not isinstance(leg_id, str)
                or not re.fullmatch(r"swimlane-[a-z0-9]+(?:-[a-z0-9]+)*-leg-[0-9]{2}", leg_id)
                or leg_lane_id != lane_id
                or status not in {"proposed", "accepted", "in_progress", "done", "superseded"}
            ):
                invalid = True
                issues.add(
                    code="DECOMPOSITION_LEG_IDENTITY_INVALID",
                    severity="error",
                    domain="decomposition",
                    message=f"Leg identity, swimlane, or status is invalid: {leg_path.relative_to(root).as_posix()}.",
                    remediation="Use stable leg/swimlane ids and a supported lifecycle status.",
                )
                continue
            if leg_id in leg_ids:
                invalid = True
                issues.add(
                    code="DECOMPOSITION_LEG_ID_DUPLICATE",
                    severity="error",
                    domain="decomposition",
                    message=f"Duplicate leg id was observed: {leg_id}.",
                )
                continue
            dependencies = frontmatter_strings(frontmatter.get("depends_on"))
            if any(
                not re.fullmatch(r"swimlane-[a-z0-9]+(?:-[a-z0-9]+)*-leg-[0-9]{2}", dependency)
                for dependency in dependencies
            ):
                invalid = True
                issues.add(
                    code="DECOMPOSITION_DEPENDENCY_ID_INVALID",
                    severity="error",
                    domain="decomposition",
                    message=f"Leg has an invalid depends_on id: {leg_id}.",
                )
                continue
            leg_ids.add(leg_id)
            leg_artifact_id = artifacts.add(
                leg_path,
                label=leg_title(leg_text, leg_id),
                kind="plan",
                entity={"kind": "leg", "id": leg_id},
            )
            parent = frontmatter.get("parent")
            if isinstance(parent, str) and parent and parent != prd.name:
                issues.add(
                    code="DECOMPOSITION_PARENT_MISMATCH",
                    severity="warning",
                    domain="decomposition",
                    message=f"Leg {leg_id} names parent {parent}, but its observed lane PRD is {prd.name}.",
                    entity={"kind": "leg", "id": leg_id},
                    remediation="Update parent/back-link metadata when the canonical scaffold is corrected.",
                    artifact_ids=[leg_artifact_id] if leg_artifact_id else [],
                )
            leg_sections = markdown_sections(leg_text)
            consumes_produces = section_with_prefix(leg_sections, "consumes / produces")
            consumes: list[str] = []
            produces: list[str] = []
            for item in markdown_list_items(consumes_produces):
                consume_match = re.match(r"Consumes:\s*(.+)", item, re.IGNORECASE)
                produce_match = re.match(r"Produces:\s*(.+)", item, re.IGNORECASE)
                if consume_match:
                    consumes.append(
                        clip_text(
                            consume_match.group(1), MAX_DECOMPOSITION_LIST_ITEM
                        )
                    )
                if produce_match:
                    produces.append(
                        clip_text(
                            produce_match.group(1), MAX_DECOMPOSITION_LIST_ITEM
                        )
                    )
            leg_record = {
                "id": leg_id,
                "swimlaneId": lane_id,
                "order": int(leg_id.rsplit("-", 1)[1]),
                "title": leg_title(leg_text, leg_id),
                "tech": (
                    clip_text(frontmatter["tech"], 80)
                    if isinstance(frontmatter.get("tech"), str) and frontmatter["tech"]
                    else None
                ),
                "status": status,
                "specRefs": frontmatter_strings(frontmatter.get("spec_ref")),
                "dependsOn": dependencies,
                "responsibility": first_markdown_paragraph(
                    section_with_prefix(leg_sections, "responsibility")
                ),
                "proves": markdown_list_items(section_with_prefix(leg_sections, "proves")),
                "independence": first_markdown_paragraph(
                    section_with_prefix(leg_sections, "independence")
                ),
                "consumes": consumes,
                "produces": produces,
                "appetite": first_markdown_paragraph(
                    section_with_prefix(leg_sections, "appetite")
                ),
                "yields": markdown_list_items(section_with_prefix(leg_sections, "yields")),
                "reverifyWhen": first_markdown_paragraph(
                    section_with_prefix(leg_sections, "re-verify when")
                ),
                "artifactIds": [leg_artifact_id] if leg_artifact_id else [],
            }
            legs.append(leg_record)
            lane_record["legIds"].append(leg_id)

    known_leg_ids = {leg["id"] for leg in legs}
    edges: list[dict[str, Any]] = []
    for leg in legs:
        for dependency in leg["dependsOn"]:
            if dependency not in known_leg_ids:
                invalid = True
                issues.add(
                    code="DECOMPOSITION_DEPENDENCY_DANGLING",
                    severity="error",
                    domain="decomposition",
                    message=f"Leg {leg['id']} depends on unknown leg {dependency}.",
                    entity={"kind": "leg", "id": leg["id"]},
                    remediation="Add the missing leg or remove the stale depends_on id.",
                    artifact_ids=leg["artifactIds"],
                )
                continue
            edges.append(
                {
                    "id": stable_id("decompedge", dependency, leg["id"]),
                    "source": dependency,
                    "target": leg["id"],
                    "kind": "depends_on",
                    "artifactIds": leg["artifactIds"],
                }
            )

    dependencies_by_leg = {
        leg["id"]: {dependency for dependency in leg["dependsOn"] if dependency in known_leg_ids}
        for leg in legs
    }
    dependents: dict[str, set[str]] = {leg_id: set() for leg_id in known_leg_ids}
    indegree = {leg_id: len(dependencies) for leg_id, dependencies in dependencies_by_leg.items()}
    for leg_id, dependencies in dependencies_by_leg.items():
        for dependency in dependencies:
            dependents[dependency].add(leg_id)
    frontier = sorted(leg_id for leg_id, count in indegree.items() if count == 0)
    visited: list[str] = []
    while frontier:
        current = frontier.pop(0)
        visited.append(current)
        for dependent in sorted(dependents[current]):
            indegree[dependent] -= 1
            if indegree[dependent] == 0:
                frontier.append(dependent)
                frontier.sort()
    if len(visited) != len(known_leg_ids):
        invalid = True
        cyclic = sorted(known_leg_ids - set(visited))
        issues.add(
            code="DECOMPOSITION_DEPENDENCY_CYCLE",
            severity="error",
            domain="decomposition",
            message="A dependency cycle was observed among: " + ", ".join(cyclic[:8]),
            entity={"kind": "leg", "id": cyclic[0]} if cyclic else None,
            remediation="Break the cycle with a one-way contract or explicit boundary.",
        )

    for lane in swimlanes:
        lane["legIds"] = sorted(
            set(lane["legIds"]),
            key=lambda leg_id: next(
                (leg["order"] for leg in legs if leg["id"] == leg_id),
                999,
            ),
        )
    if invalid:
        artifacts.drop_entity_kinds({"swimlane", "leg"})
        issues.drop_entity_kinds({"swimlane", "leg"})
        return {**empty, "availability": "unavailable"}
    return {
        "availability": "available",
        "swimlanes": sorted(swimlanes, key=lambda item: item["id"]),
        "legs": sorted(legs, key=lambda item: (item["swimlaneId"], item["order"], item["id"])),
        "edges": sorted(edges, key=lambda item: (item["source"], item["target"], item["id"])),
    }


class CvgRunner:
    def __init__(self, cvg_home: Path, project_root: Path) -> None:
        self.cvg_home = cvg_home
        self.project_root = project_root
        self.executable = cvg_home / "bin" / "cvg"
        if not self.executable.is_file():
            raise SnapshotError(f"cvg executable is missing: {self.executable}")

    def run(self, args: Iterable[str]) -> dict[str, Any]:
        command = ["/bin/bash", str(self.executable), *args, "--json"]
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in {"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL",
                       "CVG_TASKSPEC_BIN", "TASKSPEC_BIN", "CVG_SEAMWISE_BIN"}
        }
        environment.update(
            {
                "CVG_HOME": str(self.cvg_home),
                "CVG_PROJECT_ROOT": str(self.project_root),
                "CVG_COLOR": "0",
                "NO_COLOR": "1",
            }
        )
        try:
            result = subprocess.run(
                command,
                cwd=self.project_root,
                env=environment,
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=CVG_TIMEOUT_SECONDS,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise SnapshotError(
                f"core command failed to execute: {' '.join(args)} ({exc})"
            ) from exc
        try:
            document = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise SnapshotError(
                f"core command returned invalid JSON: {' '.join(args)}"
            ) from exc
        required = {"ok", "exit_code", "data", "meta"}
        if not isinstance(document, dict) or not required.issubset(document):
            raise SnapshotError(
                f"core command returned an invalid envelope: {' '.join(args)}"
            )
        if document.get("exit_code") != result.returncode:
            raise SnapshotError(
                f"core command exit mismatch: {' '.join(args)}"
            )
        return document


def gate_from_envelope(definition: dict[str, Any], envelope: dict[str, Any]) -> dict[str, Any]:
    return {
        "command": definition["command"],
        "token": envelope.get("token") if isinstance(envelope.get("token"), str) else None,
        "verdict": (
            envelope.get("verdict")
            if isinstance(envelope.get("verdict"), str)
            else None
        ),
        "exitCode": (
            envelope.get("exit_code")
            if isinstance(envelope.get("exit_code"), int)
            else None
        ),
        "ok": envelope.get("ok") if isinstance(envelope.get("ok"), bool) else None,
    }


def git_project(root: Path) -> dict[str, Any]:
    def run(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=10,
            check=False,
            env={
                key: value
                for key, value in os.environ.items()
                if key in {"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"}
            }
            | {"GIT_OPTIONAL_LOCKS": "0"},
        )

    try:
        top = run("rev-parse", "--show-toplevel")
        if top.returncode != 0:
            return {
                "available": False,
                "root": None,
                "branch": None,
                "commit": None,
                "dirty": None,
            }
        branch = run("symbolic-ref", "--quiet", "--short", "HEAD")
        commit = run("rev-parse", "HEAD")
        dirty = run("status", "--porcelain", "--untracked-files=normal", "--", ".")
        return {
            "available": commit.returncode == 0 and dirty.returncode == 0,
            "root": top.stdout.strip() or None,
            "branch": branch.stdout.strip() if branch.returncode == 0 else None,
            "commit": commit.stdout.strip() if commit.returncode == 0 else None,
            "dirty": bool(dirty.stdout) if dirty.returncode == 0 else None,
        }
    except (OSError, subprocess.TimeoutExpired):
        return {
            "available": False,
            "root": None,
            "branch": None,
            "commit": None,
            "dirty": None,
        }


def project_document_inventory(
    root: Path,
    artifacts: ArtifactCollector,
    issues: IssueCollector,
) -> list[str]:
    paths: list[Path] = []
    readme = root / "README.md"
    if readme.is_file() or readme.is_symlink():
        paths.append(readme)
    truncated = False
    document_count = 0
    for document_root in (root / "cvg" / "docs", root / "docs"):
        remaining = max(0, MAX_PROJECT_DOCUMENTS - document_count)
        if remaining == 0:
            truncated = True
            break
        documents, root_truncated = iter_bounded_documents(
            document_root,
            suffixes={".md", ".markdown", ".pdf"},
            limit=remaining,
        )
        paths.extend(documents)
        document_count += len(documents)
        truncated = truncated or root_truncated
    if truncated:
        issues.add(
            code="PROJECT_DOCUMENT_LIMIT_EXCEEDED",
            severity="warning",
            domain="project",
            message=f"Project document inventory was capped at {MAX_PROJECT_DOCUMENTS} files.",
            remediation="Archive obsolete documents or split the workspace before opening the Cockpit.",
        )
    artifact_ids: list[str] = []
    for path in paths:
        artifact_id = artifacts.add(
            path,
            label=(
                "Project README"
                if path == readme
                else path.relative_to(root).as_posix()
            ),
            kind="readme" if path == readme else "document",
            entity={"kind": "project", "id": root.name},
            truth_class="observed",
        )
        if artifact_id:
            artifact_ids.append(artifact_id)
    return sorted(set(artifact_ids))


def artifact_inventory(
    root: Path,
    artifacts: ArtifactCollector,
    decomposition_discovery: dict[str, Any],
) -> dict[str, list[str]]:
    by_pass = {f"pass-{index}": [] for index in range(9)}

    def add_many(
        paths: Iterable[Path],
        *,
        pass_id: str,
        kind: str,
        truth_class: str = "canonical",
    ) -> None:
        for path in sorted(set(paths), key=lambda item: item.as_posix()):
            artifact_id = artifacts.add(
                path,
                label=path.stem.replace("-", " ").replace("_", " ").strip().title(),
                kind=kind,
                entity={"kind": "pass", "id": pass_id},
                truth_class=truth_class,
            )
            if artifact_id:
                by_pass[pass_id].append(artifact_id)

    docs = root / "cvg" / "docs"
    add_many((docs / "brd").glob("*.md") if (docs / "brd").is_dir() else (), pass_id="pass-0", kind="brief")
    add_many(docs.glob("brd-*.md") if docs.is_dir() else (), pass_id="pass-0", kind="brief")
    add_many((docs / "tech-spec").glob("*.md") if (docs / "tech-spec").is_dir() else (), pass_id="pass-1", kind="spec")
    add_many(docs.glob("tech-spec-*.md") if docs.is_dir() else (), pass_id="pass-1", kind="spec")
    add_many((docs / "adrs").glob("*.md") if (docs / "adrs").is_dir() else (), pass_id="pass-2", kind="decision")
    if (docs / "CONTEXT.md").is_file():
        add_many((docs / "CONTEXT.md",), pass_id="pass-2", kind="context")

    lane_roots = (
        decomposition_discovery["roots"]
        if decomposition_discovery["roots"]
        else ([decomposition_discovery["root"]] if decomposition_discovery["root"] else [])
    )
    lane_files = sorted(
        {
            path
            for lane_root in lane_roots
            for path in iter_regular_files(lane_root, "*.md")
            if ".consensus" not in path.parts
        },
        key=lambda item: item.as_posix(),
    )
    add_many(lane_files, pass_id="pass-3", kind="plan")
    if decomposition_discovery["root"] is not None:
        review_path = decomposition_discovery["root"] / ".consensus" / "objection-log.json"
        if review_path.is_file():
            add_many((review_path,), pass_id="pass-4", kind="review")

    tasks_root = root / "cvg" / "tasks"
    if not tasks_root.is_dir() and (root / "tasks").is_dir():
        tasks_root = root / "tasks"
    add_many(
        (
            path
            for path in iter_regular_files(tasks_root, "T-*.md")
            if path.name.startswith("T-")
        ),
        pass_id="pass-5",
        kind="task",
    )
    add_many(
        iter_regular_files(root / "cvg" / "execution"),
        pass_id="pass-7",
        kind="contract",
    )
    add_many(
        iter_regular_files(root / "cvg" / "receipts", "*.json"),
        pass_id="pass-8",
        kind="receipt",
    )
    add_many(
        (
            path
            for path in iter_regular_files(root / "cvg" / "loop")
            if path.name in {"state.env", "HANDOFF.md"}
        ),
        pass_id="pass-8",
        kind="run",
        truth_class="canonical",
    )
    return {key: sorted(set(value)) for key, value in by_pass.items()}


def find_review_path(root: Path) -> Path | None:
    for candidate in (
        root / "cvg" / "swimlanes" / ".consensus" / "objection-log.json",
        root / "cvg" / "sketch" / ".consensus" / "objection-log.json",
    ):
        if candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None


def parse_review(
    root: Path,
    artifacts_by_pass: dict[str, list[str]],
    issues: IssueCollector,
) -> dict[str, Any] | None:
    path = find_review_path(root)
    if path is None:
        return None
    artifact_ids = artifacts_by_pass["pass-4"]
    try:
        document = json.loads(read_text(path))
        if not isinstance(document, dict):
            raise ValueError("review root must be an object")
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        issues.add(
            code="REVIEW_INVALID",
            severity="blocking",
            domain="review",
            message=f"Consensus record is invalid: {exc}",
            remediation="Repair the objection log and rerun `cvg review --check`.",
            entity={"kind": "pass", "id": "pass-4"},
            artifact_ids=artifact_ids,
        )
        return None

    objections: list[dict[str, Any]] = []
    raw_objections = document.get("objections", [])
    if not isinstance(raw_objections, list):
        raw_objections = []
    for index, raw in enumerate(raw_objections):
        if not isinstance(raw, dict):
            continue
        resolution = raw.get("resolution") if isinstance(raw.get("resolution"), dict) else {}
        disposition = str(resolution.get("disposition") or "").upper()
        decided_by = str(resolution.get("decided_by") or "").strip()
        residual = str(resolution.get("risk_residual") or "").strip().lower()
        resolved = (
            disposition in {"FIX", "ACCEPT"}
            and bool(decided_by)
            and not residual.startswith("open")
        )
        objection_id = str(raw.get("id") or f"objection-{index + 1}")
        objections.append(
            {
                "id": objection_id,
                "title": clip_text(
                    raw.get("title")
                    or raw.get("evidence")
                    or "Untitled objection"
                ),
                "severity": str(raw.get("severity") or "unknown"),
                "resolved": resolved,
                "artifactIds": artifact_ids,
            }
        )

    questions: list[dict[str, Any]] = []
    raw_questions = document.get("open_questions", [])
    if isinstance(raw_questions, list):
        for index, raw in enumerate(raw_questions):
            if not isinstance(raw, dict):
                continue
            question = str(raw.get("q") or raw.get("question") or "Unrecorded question")
            questions.append(
                {
                    "id": stable_id(
                        "question",
                        question,
                        raw.get("owner") or "unassigned",
                    ),
                    "question": clip_text(question, 500),
                    "owner": clip_text(raw.get("owner") or "unassigned", 120),
                    "blocksBuild": raw.get("blocks_build") is True,
                }
            )

    objections.sort(key=lambda item: item["id"])
    questions.sort(key=lambda item: item["id"])
    unresolved = sum(1 for item in objections if not item["resolved"])
    unresolved += sum(1 for item in questions if item["blocksBuild"])
    return {
        "verdict": str(document.get("verdict") or "UNKNOWN"),
        "round": int(document.get("rounds_run") or document.get("round") or 0),
        "unresolvedCount": unresolved,
        "objections": objections,
        "openQuestions": questions,
        "artifactIds": artifact_ids,
    }


def task_root(root: Path) -> Path:
    canonical = root / "cvg" / "tasks"
    if canonical.is_dir():
        return canonical
    legacy = root / "tasks"
    return legacy if legacy.is_dir() else canonical


def parse_tasks(
    root: Path,
    artifacts: ArtifactCollector,
    issues: IssueCollector,
) -> dict[str, Any]:
    directory = task_root(root)
    empty_stats = {
        "total": 0,
        "ready": 0,
        "inProgress": 0,
        "blocked": 0,
        "done": 0,
        "parked": 0,
    }
    if not directory.is_dir():
        issues.add(
            code="TASK_DOMAIN_UNAVAILABLE",
            severity="info",
            domain="work",
            message="No canonical task directory is present yet.",
            remediation="Complete Pass 4, then preview Task-Specs with `cvg tasks plan`.",
        )
        return {
            "availability": "unavailable",
            "tasks": [],
            "frontier": {"taskIds": [], "blockedTaskIds": []},
            "stats": empty_stats,
        }

    paths = [
        path
        for path in iter_regular_files(directory, "T-*.md")
        if path.name.startswith("T-")
    ]
    if len(paths) > MAX_TASKS:
        issues.add(
            code="TASK_LIMIT_EXCEEDED",
            severity="error",
            domain="work",
            message=f"Task count exceeds the snapshot limit ({MAX_TASKS}).",
            remediation="Archive terminal tasks or query a narrower workspace.",
        )
        return {
            "availability": "unavailable",
            "tasks": [],
            "frontier": {"taskIds": [], "blockedTaskIds": []},
            "stats": empty_stats,
        }

    parsed: list[dict[str, Any]] = []
    unavailable = False
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        artifact_id = artifacts.add(
            path,
            label=path.stem,
            kind="task",
            truth_class="canonical",
        )
        try:
            fields = parse_frontmatter(read_text(path))
            task_id = str(fields.get("id") or "").strip()
            title = str(fields.get("title") or "").strip()
            status = str(fields.get("status") or "").strip().replace("-", "_")
            if not task_id or not title or not status:
                raise ValueError("frontmatter requires id, title, and status")
            depends = fields.get("depends_on", [])
            if isinstance(depends, str):
                depends = [depends] if depends and depends != "(none)" else []
            if not isinstance(depends, list):
                depends = []
            task = {
                "id": task_id,
                "title": clip_text(title, 240),
                "status": status,
                "effort": (
                    str(fields["effort"]) if fields.get("effort") not in {None, ""} else None
                ),
                "priority": (
                    str(fields["priority"])
                    if fields.get("priority") not in {None, "", "(none)"}
                    else None
                ),
                "agent": (
                    str(fields["agent"]) if fields.get("agent") not in {None, ""} else None
                ),
                "budgetIterations": safe_int(fields.get("budget_iterations")),
                "dependsOn": sorted(
                    str(dep).strip()
                    for dep in depends
                    if str(dep).strip() and str(dep).strip() != "(none)"
                ),
                "signedOff": fields.get("signed_off") is True,
                "dispatchable": False,
                "blockingReasons": [],
                "artifactIds": [artifact_id] if artifact_id else [],
                "_path": relative,
            }
            if artifact_id and artifact_id in artifacts._items:
                artifacts._items[artifact_id]["entity"] = {
                    "kind": "task",
                    "id": task_id,
                }
            parsed.append(task)
        except (OSError, UnicodeError, ValueError) as exc:
            unavailable = True
            issues.add(
                code="TASK_INVALID",
                severity="error",
                domain="work",
                message=f"Task-Spec cannot be parsed: {relative} ({exc})",
                remediation="Repair canonical Task-Spec frontmatter; never edit `_state.yaml` as a substitute.",
                artifact_ids=[artifact_id] if artifact_id else [],
            )

    parsed.sort(key=lambda task: task["id"])
    by_id = {task["id"]: task for task in parsed}
    duplicate_ids = len(by_id) != len(parsed)
    if duplicate_ids:
        unavailable = True
        issues.add(
            code="TASK_ID_DUPLICATE",
            severity="error",
            domain="work",
            message="More than one canonical Task-Spec declares the same id.",
            remediation="Give every Task-Spec one unique canonical id.",
        )

    for task in parsed:
        reasons: list[str] = []
        if task["status"] != "ready":
            reasons.append(f"status is {task['status']}, not ready")
        for dependency in task["dependsOn"]:
            target = by_id.get(dependency)
            if target is None:
                reasons.append(f"dependency {dependency} is missing")
            elif target["status"] not in {"done", "accepted"}:
                reasons.append(
                    f"dependency {dependency} is {target['status']}, not terminal"
                )
        task["blockingReasons"] = sorted(reasons)
        task["dispatchable"] = not reasons
        task.pop("_path", None)

    ready_ids = sorted(task["id"] for task in parsed if task["dispatchable"])
    blocked_ids = sorted(
        task["id"]
        for task in parsed
        if task["status"] == "ready" and not task["dispatchable"]
    )
    canonical_stats = {key: 0 for key in STATUS_KEYS}
    for task in parsed:
        key = task["status"]
        if key == "accepted":
            key = "done"
        if key in canonical_stats:
            canonical_stats[key] += 1
    stats = {
        "total": len(parsed),
        "ready": canonical_stats["ready"],
        "inProgress": canonical_stats["in_progress"],
        "blocked": canonical_stats["blocked"],
        "done": canonical_stats["done"],
        "parked": canonical_stats["parked"],
    }
    availability = "unavailable" if unavailable else ("available" if parsed else "empty")
    return {
        "availability": availability,
        "tasks": parsed,
        "frontier": {"taskIds": ready_ids, "blockedTaskIds": blocked_ids},
        "stats": stats,
    }


def safe_int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def parse_execution(
    root: Path,
    artifacts: ArtifactCollector,
    work: dict[str, Any],
    issues: IssueCollector,
) -> dict[str, Any]:
    directory = root / "cvg" / "execution"
    if not directory.is_dir():
        return {"availability": "unavailable", "runs": []}
    profiles = [
        path
        for path in iter_regular_files(directory)
        if path.name == "execution-profile.yaml"
    ]
    if not profiles:
        return {"availability": "empty", "runs": []}

    tasks = {task["id"]: task for task in work["tasks"]}
    runs: list[dict[str, Any]] = []
    unavailable = False
    for profile_path in sorted(profiles):
        artifact_id = artifacts.add(
            profile_path,
            label=f"{profile_path.parent.name} execution profile",
            kind="contract",
            truth_class="canonical",
        )
        relative = profile_path.relative_to(root).as_posix()
        try:
            profile = json.loads(read_text(profile_path))
            if not isinstance(profile, dict) or profile.get("schema") != "cvg.execution-profile.v1":
                raise ValueError("unsupported execution profile schema")
            task = profile.get("task")
            if not isinstance(task, dict) or not str(task.get("id") or ""):
                raise ValueError("execution profile has no task id")
            task_id = str(task["id"])
            run_id = stable_id("run", task_id, relative)
            loop_dir = root / "cvg" / "loop" / task_id
            loop_artifact_ids: list[str] = []
            attempt = None
            checkpoint_data: dict[str, Any] | None = None
            handoff_artifact_id: str | None = None
            terminal: dict[str, Any] | None = None
            state = "bound"
            enforcement = (
                profile.get("enforcement")
                if isinstance(profile.get("enforcement"), dict)
                else {}
            )
            runtime = {
                "primaryRuntime": (
                    str(enforcement["primary_runtime"])
                    if enforcement.get("primary_runtime")
                    else None
                ),
                "assurance": (
                    str(enforcement["assurance"])
                    if enforcement.get("assurance")
                    else None
                ),
            }
            state_path = loop_dir / "state.env"
            if state_path.is_file() and not state_path.is_symlink():
                state_artifact = artifacts.add(
                    state_path,
                    label=f"{task_id} loop checkpoint",
                    kind="run",
                    entity={"kind": "run", "id": run_id},
                    truth_class="canonical",
                )
                if state_artifact:
                    loop_artifact_ids.append(state_artifact)
                checkpoint = parse_env_state(read_text(state_path))
                attempt = safe_int(checkpoint.get("ITER"))
                checkpoint_data = {
                    "attempt": attempt,
                    "strikes": safe_int(checkpoint.get("STRIKES")),
                    "tokensUsed": safe_int(checkpoint.get("TOKENS_USED")),
                    "startedAtEpoch": safe_int(checkpoint.get("STARTED_AT")),
                    "elapsedSeconds": safe_int(checkpoint.get("ELAPSED_PRIOR")),
                    "artifactId": state_artifact,
                }
                state = "running"
            handoff = loop_dir / "HANDOFF.md"
            if handoff.is_file() and not handoff.is_symlink():
                handoff_artifact = artifacts.add(
                    handoff,
                    label=f"{task_id} handoff",
                    kind="run",
                    entity={"kind": "run", "id": run_id},
                    truth_class="canonical",
                )
                if handoff_artifact:
                    loop_artifact_ids.append(handoff_artifact)
                    handoff_artifact_id = handoff_artifact
                state = "paused"
            receipt_path = root / "cvg" / "receipts" / f"{task_id}.json"
            if receipt_path.is_file():
                try:
                    receipt_document = json.loads(read_text(receipt_path))
                    state = (
                        "settled"
                        if receipt_document.get("result") == "pass"
                        else "blocked"
                    )
                    terminal = {
                        "result": str(receipt_document.get("result") or "unknown"),
                        "recordedAt": (
                            str(receipt_document["recorded_at"])
                            if receipt_document.get("recorded_at")
                            else None
                        ),
                    }
                except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
                    state = "unknown"
            entity = {"kind": "run", "id": run_id}
            if artifact_id:
                artifact = next(
                    (
                        item
                        for item in artifacts._items.values()
                        if item["id"] == artifact_id
                    ),
                    None,
                )
                if artifact:
                    artifact["entity"] = entity
            runs.append(
                {
                    "id": run_id,
                    "taskId": task_id,
                    "state": state,
                    "attempt": attempt,
                    "budgetIterations": safe_int(tasks.get(task_id, {}).get("budgetIterations")),
                    "runtime": runtime,
                    "checkpoint": checkpoint_data,
                    "terminal": terminal,
                    "handoffArtifactId": handoff_artifact_id,
                    "profileArtifactId": artifact_id or "",
                    "artifactIds": sorted(
                        [item for item in [artifact_id, *loop_artifact_ids] if item]
                    ),
                }
            )
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            unavailable = True
            issues.add(
                code="EXECUTION_PROFILE_INVALID",
                severity="error",
                domain="execution",
                message=f"Execution profile cannot be parsed: {relative} ({exc})",
                remediation="Rebind the Task-Spec and rerun `cvg bind --check`.",
                artifact_ids=[artifact_id] if artifact_id else [],
            )
    runs.sort(key=lambda run: (run["taskId"], run["id"]))
    return {
        "availability": "unavailable" if unavailable else "available",
        "runs": runs,
    }


def inspect_digest_binding(root: Path, reference: object) -> dict[str, Any]:
    raw_path = reference.get("path") if isinstance(reference, dict) else None
    expected = reference.get("sha256") if isinstance(reference, dict) else None
    binding = {
        "path": raw_path if isinstance(raw_path, str) else None,
        "expectedSha256": expected if isinstance(expected, str) else None,
        "currentSha256": None,
        "matches": None,
    }
    if not isinstance(raw_path, str) or not isinstance(expected, str):
        return binding
    candidate = root / raw_path
    try:
        resolved = candidate.resolve(strict=True)
        if not within(root.resolve(), resolved) or candidate.is_symlink() or not candidate.is_file():
            return binding
        if candidate.stat().st_size > MAX_ARTIFACT_BYTES:
            return binding
        current = sha256_bytes(candidate.read_bytes())
        binding["currentSha256"] = current
        binding["matches"] = current == expected
        return binding
    except OSError:
        return binding


def parse_receipts(
    root: Path,
    artifacts: ArtifactCollector,
    issues: IssueCollector,
) -> dict[str, Any]:
    directory = root / "cvg" / "receipts"
    if not directory.is_dir():
        return {"availability": "unavailable", "items": []}
    paths = iter_regular_files(directory, "*.json")
    if not paths:
        return {"availability": "empty", "items": []}
    receipts: list[dict[str, Any]] = []
    unavailable = False
    for path in sorted(paths):
        artifact_id = artifacts.add(
            path,
            label=path.stem.replace("-", " "),
            kind="receipt",
            truth_class="canonical",
        )
        relative = path.relative_to(root).as_posix()
        try:
            document = json.loads(read_text(path))
            if not isinstance(document, dict) or document.get("schema") != "cvg.execution-receipt.v1":
                raise ValueError("unsupported execution receipt schema")
            task_id = str(document.get("task_id") or "")
            if not task_id:
                raise ValueError("execution receipt has no task_id")
            task_binding = inspect_digest_binding(root, document.get("task_spec"))
            profile_binding = inspect_digest_binding(
                root,
                document.get("execution_profile"),
            )
            comparisons = [
                binding["matches"]
                for binding in (task_binding, profile_binding)
                if binding["matches"] is not None
            ]
            if False in comparisons:
                integrity = "mismatch"
            elif len(comparisons) == 2 and all(comparisons):
                integrity = "verified"
            else:
                integrity = "unavailable"
            freshness = (
                "current"
                if integrity == "verified"
                else "stale"
                if integrity == "mismatch"
                else "unavailable"
            )
            evaluation = (
                document.get("evaluation")
                if isinstance(document.get("evaluation"), dict)
                else {}
            )
            receipt_id = stable_id("receipt", relative)
            entity = {"kind": "receipt", "id": receipt_id}
            if artifact_id and artifact_id in artifacts._items:
                artifacts._items[artifact_id]["entity"] = entity
            receipts.append(
                {
                    "id": receipt_id,
                    "taskId": task_id,
                    "result": str(document.get("result") or "unknown"),
                    "recordedAt": (
                        str(document["recorded_at"])
                        if document.get("recorded_at")
                        else None
                    ),
                    "integrity": integrity,
                    "freshness": freshness,
                    "bindings": {
                        "task": task_binding,
                        "executionProfile": profile_binding,
                        "evaluationOutputSha256": (
                            str(evaluation["output_sha256"])
                            if evaluation.get("output_sha256")
                            else None
                        ),
                        "pathPolicy": (
                            str(evaluation["path_policy"])
                            if evaluation.get("path_policy")
                            else None
                        ),
                    },
                    "provenance": {
                        "generatedBy": (
                            str(document["generated_by"])
                            if document.get("generated_by")
                            else None
                        ),
                        "postHoc": document.get("post_hoc") is True,
                    },
                    "artifactIds": [artifact_id] if artifact_id else [],
                }
            )
            if integrity == "mismatch":
                issues.add(
                    code="RECEIPT_INTEGRITY_MISMATCH",
                    severity="blocking",
                    domain="receipts",
                    message=f"Receipt no longer matches its task or execution profile: {relative}",
                    remediation="Rebind and rerun; never treat a stale receipt as settlement.",
                    entity=entity,
                    artifact_ids=[artifact_id] if artifact_id else [],
                )
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            unavailable = True
            issues.add(
                code="RECEIPT_INVALID",
                severity="error",
                domain="receipts",
                message=f"Receipt cannot be parsed: {relative} ({exc})",
                remediation="Repair or archive the invalid receipt before relying on settlement.",
                artifact_ids=[artifact_id] if artifact_id else [],
            )
    receipts.sort(key=lambda receipt: (receipt["taskId"], receipt["id"]))
    return {
        "availability": "unavailable" if unavailable else "available",
        "items": receipts,
    }


def parse_metric_signals(
    root: Path,
    artifacts: ArtifactCollector,
    issues: IssueCollector,
) -> list[dict[str, Any]]:
    path = task_root(root) / "_metrics.jsonl"
    if not path.is_file() or path.is_symlink():
        return []
    artifact_id = artifacts.add(
        path,
        label="Task lifecycle metrics",
        kind="event",
        truth_class="canonical",
    )
    try:
        text = read_text(path)
    except (OSError, UnicodeError, ValueError) as exc:
        issues.add(
            code="METRICS_UNAVAILABLE",
            severity="warning",
            domain="work",
            message=f"Task metrics cannot be read: {exc}",
            artifact_ids=[artifact_id] if artifact_id else [],
        )
        return []
    signals: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
            if not isinstance(event, dict):
                raise ValueError("event is not an object")
        except (ValueError, json.JSONDecodeError) as exc:
            issues.add(
                code="METRIC_EVENT_INVALID",
                severity="warning",
                domain="work",
                message=f"Task metric line {line_number} is invalid: {exc}",
                artifact_ids=[artifact_id] if artifact_id else [],
            )
            continue
        task_id = str(event.get("task") or event.get("task_id") or "")
        kind = str(event.get("event") or event.get("outcome") or "task_event")
        signal_id = stable_id("signal", "metric", line_number, task_id, kind)
        signal: dict[str, Any] = {
            "id": signal_id,
            "kind": "task",
            "severity": "error" if kind in {"fail", "error", "blocked"} else "info",
            "summary": f"{task_id + ': ' if task_id else ''}{kind}",
            "occurredAt": (
                str(event.get("ts") or event.get("timestamp"))
                if event.get("ts") or event.get("timestamp")
                else None
            ),
            "artifactIds": [artifact_id] if artifact_id else [],
        }
        if task_id:
            signal["entity"] = {"kind": "task", "id": task_id}
        signals.append(signal)
    return signals[-MAX_SIGNALS:]


def build_method(
    runner: CvgRunner,
    version: str,
    lane: str,
    artifacts_by_pass: dict[str, list[str]],
    review: dict[str, Any] | None,
    work: dict[str, Any],
    execution: dict[str, Any],
    receipts: dict[str, Any],
    issues: IssueCollector,
) -> tuple[
    dict[str, Any],
    dict[str, Any],
    list[dict[str, Any]],
    str,
]:
    required_orders = LANE_ORDERS[lane]
    required_set = set(required_orders)
    core_orders = tuple(order for order in required_orders if order < 5)
    gates: dict[str, dict[str, Any]] = {}
    gate_signals: list[dict[str, Any]] = []
    for order in core_orders:
        definition = PASS_DEFINITIONS[order]
        envelope = runner.run(definition["args"])
        gate = gate_from_envelope(definition, envelope)
        gates[definition["id"]] = gate
        gate_signals.append(
            {
                "id": stable_id(
                    "signal",
                    "gate",
                    definition["id"],
                    gate["token"],
                    gate["exitCode"],
                ),
                "kind": "gate",
                "severity": (
                    "success"
                    if gate["ok"] is True
                    else "error"
                    if gate["ok"] is False
                    else "warning"
                ),
                "summary": (
                    f"{definition['label']} gate "
                    f"{gate['verdict'] or ('passed' if gate['ok'] else 'did not pass')}"
                ),
                "occurredAt": None,
                "entity": {"kind": "pass", "id": definition["id"]},
                "artifactIds": artifacts_by_pass[definition["id"]],
            }
        )

    next_envelope = runner.run(("next", "--lane", lane))
    raw_next = next_envelope.get("verdict")
    if not isinstance(raw_next, str):
        token = next_envelope.get("token")
        if isinstance(token, str) and token.startswith("NEXT_PASS="):
            raw_next = token.split("=", 1)[1]
    if not isinstance(raw_next, str):
        raise SnapshotError(
            f"`cvg next --lane {lane} --json` returned no NEXT_PASS verdict"
        )
    if raw_next.isdigit() and 0 <= int(raw_next) <= 8:
        active_order: int | None = int(raw_next)
        if active_order not in required_set:
            raise SnapshotError(
                f"`cvg next --lane {lane} --json` returned pass "
                f"{active_order}, which is outside the selected lane"
            )
    elif raw_next.upper() in {"DONE", "COMPLETE", "SETTLED"}:
        active_order = None
    else:
        raise SnapshotError(
            f"`cvg next --lane {lane} --json` returned unsupported verdict: "
            f"{raw_next}"
        )

    # Defence in depth: the conductor cannot authorize past a core gate that
    # belongs to the selected lane and currently fails, even if downstream
    # evidence happens to exist. Omitted passes never become hidden blockers.
    active_index = (
        len(required_orders)
        if active_order is None
        else required_orders.index(active_order)
    )
    for order in required_orders[:active_index]:
        if order >= 5:
            continue
        if gates[f"pass-{order}"]["ok"] is not True:
            active_order = order
            break

    # `cvg next` may consume the derived task index, but the snapshot's work
    # contract is rebuilt from canonical Task-Spec frontmatter. A missing task,
    # an empty task set, or an unsigned spec therefore keeps Pass 5 open even if
    # a stale `_state.yaml` projection claims otherwise.
    if 5 in required_set:
        pass_5_index = required_orders.index(5)
        active_is_after_pass_5 = (
            active_order is None
            or required_orders.index(active_order) > pass_5_index
        )
        tasks = work["tasks"]
        pass_5_closed = (
            work["availability"] == "available"
            and bool(tasks)
            and all(task["signedOff"] for task in tasks)
        )
        if active_is_after_pass_5 and not pass_5_closed:
            active_order = 5

    active_pass_id = f"pass-{active_order}" if active_order is not None else None
    active_index = (
        len(required_orders)
        if active_order is None
        else required_orders.index(active_order)
    )
    passes: list[dict[str, Any]] = []
    for definition in PASS_DEFINITIONS:
        order = definition["order"]
        pass_id = definition["id"]
        if pass_id in gates:
            gate = gates[pass_id]
        else:
            gate = {
                "command": definition["command"],
                "token": None,
                "verdict": None,
                "exitCode": None,
                "ok": None,
            }

        if definition["optional"]:
            status = "complete" if artifacts_by_pass[pass_id] else "optional"
        elif order not in required_set:
            status = "skipped"
        elif active_order is None:
            status = "complete"
        elif required_orders.index(order) < active_index:
            status = "complete"
        elif order == active_order:
            status = "blocked" if order < 5 and gate["ok"] is not True else "active"
        else:
            status = "waiting"

        passes.append(
            {
                "id": pass_id,
                "order": order,
                "label": definition["label"],
                "summary": definition["summary"],
                "optional": definition["optional"],
                "status": status,
                "gate": gate,
                "artifactIds": artifacts_by_pass[pass_id],
            }
        )

    blocking_issue_ids: list[str] = []
    if active_order is not None and active_order < 5:
        gate = gates[f"pass-{active_order}"]
        if gate["ok"] is not True:
            blocking_issue_ids.append(
                issues.add(
                    code="PASS_GATE_BLOCKED",
                    severity="blocking",
                    domain="authorization",
                    message=(
                        f"Pass {active_order} {PASS_DEFINITIONS[active_order]['label']} "
                        f"has not closed ({gate['verdict'] or 'unknown verdict'})."
                    ),
                    remediation=PASS_DEFINITIONS[active_order]["command"],
                    entity={"kind": "pass", "id": f"pass-{active_order}"},
                    artifact_ids=artifacts_by_pass[f"pass-{active_order}"],
                )
            )
    if active_order == 4 and review and review["unresolvedCount"] > 0:
        blocking_issue_ids.append(
            issues.add(
                code="REVIEW_UNRESOLVED",
                severity="blocking",
                domain="review",
                message=(
                    f"Consensus has {review['unresolvedCount']} unresolved owner "
                    "decision(s); Pass 5 is not authorized."
                ),
                remediation="Record owner decisions, then rerun `cvg review --check`.",
                entity={"kind": "pass", "id": "pass-4"},
                artifact_ids=review["artifactIds"],
            )
        )

    if active_order is None:
        authorization = {
            "state": "complete",
            "nextPassId": None,
            "command": None,
            "rationale": "The Converge descent is complete for the selected lane.",
            "blockingIssueIds": [],
        }
    elif blocking_issue_ids:
        authorization = {
            "state": "blocked",
            "nextPassId": f"pass-{active_order}",
            "command": PASS_DEFINITIONS[active_order]["command"],
            "rationale": "A canonical gate or owner-decision barrier is still open.",
            "blockingIssueIds": sorted(set(blocking_issue_ids)),
        }
    elif active_order >= 5 and (
        work["availability"] == "unavailable"
        or execution["availability"] == "unavailable" and active_order >= 7
        or receipts["availability"] == "unavailable" and active_order >= 8
    ):
        issue_id = issues.add(
            code="AUTHORIZATION_DOMAIN_UNAVAILABLE",
            severity="blocking",
            domain="authorization",
            message="A lifecycle domain required for the current pass is unavailable.",
            remediation="Repair the unavailable canonical domain before continuing.",
            entity={"kind": "pass", "id": f"pass-{active_order}"},
        )
        authorization = {
            "state": "unknown",
            "nextPassId": f"pass-{active_order}",
            "command": None,
            "rationale": "Authorization cannot be proven from the available canonical state.",
            "blockingIssueIds": [issue_id],
        }
    else:
        authorization = {
            "state": "allowed",
            "nextPassId": f"pass-{active_order}",
            "command": PASS_DEFINITIONS[active_order]["command"],
            "rationale": "Every required earlier pass is closed; the current pass may proceed.",
            "blockingIssueIds": [],
        }

    if active_order is None:
        authorization.update(
            {
                "mutation": "none",
                "dryRunSupported": False,
                "enabled": False,
            }
        )
    else:
        authorization.update(ACTION_POLICY[active_order])
        authorization["enabled"] = (
            authorization["command"] is not None
            and authorization["state"] != "unknown"
        )

    return (
        {
            "name": "Converge",
            "version": version,
            "activePassId": active_pass_id,
            "passes": passes,
            "edges": list(METHOD_EDGES),
        },
        authorization,
        gate_signals,
        lane,
    )


def build_health(
    root: Path,
    runner: CvgRunner,
    project: dict[str, Any],
    review: dict[str, Any] | None,
    work: dict[str, Any],
    execution: dict[str, Any],
    receipts: dict[str, Any],
    authorization: dict[str, Any],
    artifacts: ArtifactCollector,
    issues: IssueCollector,
) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def add(
        check_id: str,
        component: str,
        status: str,
        required: bool,
        summary: str,
        artifact_ids: Iterable[str] = (),
    ) -> None:
        checks.append(
            {
                "id": check_id,
                "component": component,
                "status": status,
                "required": required,
                "summary": summary,
                "artifactIds": sorted(set(artifact_ids)),
            }
        )

    add(
        "workspace-control-plane",
        "workspace",
        "healthy" if (root / "cvg" / "INDEX.md").is_file() else "blocked",
        True,
        "Canonical cvg/ control plane is present."
        if (root / "cvg" / "INDEX.md").is_file()
        else "Canonical cvg/INDEX.md is missing.",
    )
    git = project["git"]
    add(
        "git",
        "git",
        "degraded" if git["available"] and git["dirty"] else "healthy" if git["available"] else "unavailable",
        False,
        "Project has uncommitted changes."
        if git["available"] and git["dirty"]
        else "Git metadata is readable."
        if git["available"]
        else "Git metadata is unavailable.",
    )
    if git["available"] and git["dirty"]:
        issues.add(
            code="PROJECT_DIRTY",
            severity="warning",
            domain="project",
            message="The project workspace has uncommitted changes.",
            remediation="Review the diff before treating the snapshot as release evidence.",
        )

    signing_status = "unavailable"
    signing_summary = "No local signing-key source was detected."
    if os.environ.get("TASKSPEC_SIGNING_KEY"):
        signing_status = "healthy"
        signing_summary = "A signing-key source is configured for this process."
    elif git["available"]:
        try:
            key_probe = subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "rev-parse",
                    "--git-path",
                    "info/taskspec-signing-key",
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=5,
                check=False,
                env={
                    key: value
                    for key, value in os.environ.items()
                    if key in {"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"}
                }
                | {"GIT_OPTIONAL_LOCKS": "0"},
            )
            if key_probe.returncode == 0 and key_probe.stdout.strip():
                key_path = Path(key_probe.stdout.strip())
                if not key_path.is_absolute() and git["root"]:
                    key_path = Path(git["root"]) / key_path
                if key_path.is_file():
                    signing_status = "healthy"
                    signing_summary = "The repository-local signing key is provisioned."
        except (OSError, subprocess.TimeoutExpired):
            pass
    add(
        "signing",
        "signing",
        signing_status,
        True,
        signing_summary,
    )

    engine_families = {
        "codex": "openai",
        "claude": "anthropic",
        "kimi": "moonshot",
        "grok": "xai",
    }
    installed_engines = sorted(
        name for name in engine_families if shutil.which(name)
    )
    installed_families = {
        engine_families[name] for name in installed_engines
    }
    if len(installed_engines) >= 2 and len(installed_families) >= 2:
        engine_status = "healthy"
    elif installed_engines:
        engine_status = "degraded"
    else:
        engine_status = "unavailable"
    add(
        "engines",
        "engines",
        engine_status,
        False,
        (
            "Installed offline engine CLIs: " + ", ".join(installed_engines) + "."
            if installed_engines
            else "No supported engine CLI was found on PATH."
        ),
    )

    fence = root / ".cvg" / "gate.yaml"
    fence_id = artifacts.add(
        fence,
        label="Repository write fence",
        kind="policy",
        entity={"kind": "project", "id": project["name"]},
        truth_class="canonical",
    ) if fence.is_file() else None
    add(
        "path-fence",
        "path-fence",
        "healthy" if fence_id else "blocked",
        True,
        "Repository write fence is present."
        if fence_id
        else "Repository write fence is absent.",
        [fence_id] if fence_id else [],
    )
    if not fence_id:
        issues.add(
            code="WRITE_FENCE_MISSING",
            severity="blocking",
            domain="health",
            message="The project-local `.cvg/gate.yaml` write fence is missing.",
            remediation="Run `cvg init` or restore the reviewed repository write fence.",
        )

    add(
        "consensus-record",
        "review",
        "empty" if review is None else "degraded" if review["unresolvedCount"] else "healthy",
        False,
        "No consensus record exists yet."
        if review is None
        else f"Consensus contains {review['unresolvedCount']} unresolved decision(s)."
        if review["unresolvedCount"]
        else "Consensus record has no unresolved decisions.",
        review["artifactIds"] if review else [],
    )
    for check_id, component, domain in (
        ("tasks", "tasks", work),
        ("execution", "execution", execution),
        ("receipts", "receipts", receipts),
    ):
        availability = domain["availability"]
        status = (
            "healthy"
            if availability == "available"
            else "empty"
            if availability == "empty"
            else "unavailable"
        )
        add(
            check_id,
            component,
            status,
            False,
            f"{component.title()} domain is {availability}.",
        )

    runtime_status = (
        "healthy"
        if execution["availability"] == "available"
        else "empty"
        if execution["availability"] == "empty"
        else "unavailable"
    )
    add(
        "runtime-enforcement",
        "runtime-enforcement",
        runtime_status,
        False,
        (
            "Execution profiles parsed; runtime enforcement is represented."
            if runtime_status == "healthy"
            else "No bound execution profile exists yet."
            if runtime_status == "empty"
            else "Runtime-enforcement state is unavailable."
        ),
        (
            artifact_id
            for run in execution["runs"]
            for artifact_id in run["artifactIds"]
        ),
    )

    try:
        plugin = runner.run(("doctor", "plugin"))
        plugin_verdict = str(plugin.get("verdict") or "UNKNOWN").upper()
        if plugin_verdict == "OK":
            plugin_status = "healthy"
        elif plugin_verdict in {"STALE", "ERROR", "FAIL"}:
            plugin_status = "blocked"
        else:
            plugin_status = "unavailable"
        plugin_summary = f"Offline plugin parity verdict: {plugin_verdict}."
    except SnapshotError as exc:
        plugin_status = "unavailable"
        plugin_summary = f"Plugin parity could not be inspected offline: {exc}"
    add(
        "plugin-parity",
        "plugin-parity",
        plugin_status,
        False,
        plugin_summary,
    )

    tracker_status = "unavailable"
    tracker_summary = "No optional tracker choice is configured."
    config_path = root / ".cvg" / "config"
    if config_path.is_file() and not config_path.is_symlink():
        try:
            configured_keys = {
                match.group(1).lower()
                for line in read_text(config_path).splitlines()
                if (match := re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=.*", line))
            }
            if "tracker" in configured_keys:
                tracker_status = "healthy"
                tracker_summary = (
                    "An optional tracker choice is configured; connectivity was "
                    "not probed."
                )
        except (OSError, UnicodeError, ValueError):
            tracker_summary = "Tracker configuration exists but is unreadable."
    add(
        "tracker-config",
        "tracker-config",
        tracker_status,
        False,
        tracker_summary,
    )

    if authorization["state"] == "unknown":
        overall = "blocked"
    elif any(check["required"] and check["status"] == "blocked" for check in checks):
        overall = "blocked"
    elif any(check["status"] in {"degraded", "unavailable"} for check in checks):
        overall = "degraded"
    else:
        overall = "healthy"
    return {"overall": overall, "checks": sorted(checks, key=lambda item: item["id"])}


def load_version(cvg_home: Path) -> str:
    try:
        version = (cvg_home / "VERSION").read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise SnapshotError(f"cannot read Converge VERSION: {exc}") from exc
    if not version:
        raise SnapshotError("Converge VERSION is empty")
    return version


def build_snapshot(project_root: Path, cvg_home: Path) -> dict[str, Any]:
    root = project_root.resolve()
    tool_home = cvg_home.resolve()
    if not root.is_dir():
        raise SnapshotError(f"project root is not a directory: {root}")
    if not (root / "cvg").is_dir():
        raise SnapshotError(
            f"canonical Converge control plane is missing under {root}/cvg"
        )

    observed_at = utc_now()
    issues = IssueCollector()
    artifacts = ArtifactCollector(root, observed_at, issues)
    version = load_version(tool_home)
    runner = CvgRunner(tool_home, root)
    lane = resolve_lane(root)
    git = git_project(root)
    project_artifact_ids: list[str] = []
    index = root / "cvg" / "INDEX.md"
    if index.is_file():
        artifact_id = artifacts.add(
            index,
            label="Converge workspace index",
            kind="index",
            entity={"kind": "project", "id": root.name},
            truth_class="canonical",
        )
        if artifact_id:
            project_artifact_ids.append(artifact_id)
    project_artifact_ids.extend(project_document_inventory(root, artifacts, issues))

    project = {
        "name": root.name,
        "root": str(root),
        "lane": lane,
        "git": git,
        "artifactIds": sorted(project_artifact_ids),
    }
    decomposition_discovery = discover_decomposition_tree(root, issues)
    artifacts_by_pass = artifact_inventory(root, artifacts, decomposition_discovery)
    decomposition = parse_decomposition(
        root,
        decomposition_discovery,
        artifacts,
        issues,
    )
    review = parse_review(root, artifacts_by_pass, issues)
    work = parse_tasks(root, artifacts, issues)
    execution = parse_execution(root, artifacts, work, issues)
    receipts = parse_receipts(root, artifacts, issues)
    method, authorization, gate_signals, lane = build_method(
        runner,
        version,
        lane,
        artifacts_by_pass,
        review,
        work,
        execution,
        receipts,
        issues,
    )
    health = build_health(
        root,
        runner,
        project,
        review,
        work,
        execution,
        receipts,
        authorization,
        artifacts,
        issues,
    )
    signals = gate_signals + parse_metric_signals(root, artifacts, issues)
    for receipt in receipts["items"]:
        signals.append(
            {
                "id": stable_id("signal", "receipt", receipt["id"], receipt["result"]),
                "kind": "receipt",
                "severity": "success" if receipt["result"] == "pass" else "error",
                "summary": f"{receipt['taskId']}: receipt {receipt['result']}",
                "occurredAt": receipt["recordedAt"],
                "entity": {"kind": "receipt", "id": receipt["id"]},
                "artifactIds": receipt["artifactIds"],
            }
        )
    signals = sorted(
        signals[-MAX_SIGNALS:],
        key=lambda signal: (
            signal["occurredAt"] or "",
            signal["kind"],
            signal["id"],
        ),
    )

    snapshot: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "snapshotId": "",
        "observedAt": observed_at,
        "source": "workspace",
        "project": project,
        "method": method,
        "review": review,
        "decomposition": decomposition,
        "work": work,
        "execution": execution,
        "receipts": receipts,
        "health": health,
        "signals": signals,
        "issues": issues.values(),
        "authorization": authorization,
        "artifacts": artifacts.values(),
    }
    snapshot["snapshotId"] = compute_snapshot_id(snapshot)
    return snapshot


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a read-only Converge WorkspaceSnapshot 3.0"
    )
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--cvg-home", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        snapshot = build_snapshot(Path(args.project_root), Path(args.cvg_home))
    except SnapshotError as exc:
        print(f"cvg snapshot: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(snapshot, indent=2, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
