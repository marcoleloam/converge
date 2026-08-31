#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PACK="$(mktemp -t converge-pack.XXXXXX)"
trap 'rm -f "$PACK"' EXIT
npm pack --dry-run --json > "$PACK"
python3 - "$PACK" <<'PY'
import json, pathlib, re, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())[0]
files = {item["path"] for item in payload["files"]}
required = {
    "bin/cvg",
    "bin/_ui.sh",
    "bin/_cvg_compose.py",
    "bin/cvg-agent-context.py",
    "contracts/cli-command-matrix.json",
    "contracts/converge-cli-result-v1.schema.json",
    "contracts/converge-composition-receipt-v1.schema.json",
    "templates/workspace/INDEX.md",
    "install.sh",
    "VERSION",
    ".claude-plugin/plugin.json",
}
missing = sorted(required - files)
assert not missing, f"package missing anchors: {missing}"
skills = sorted(path for path in files if re.fullmatch(r"skills/[^/]+/SKILL.md", path))
assert len(skills) == 11, f"expected exactly eleven skills, got {len(skills)}: {skills}"
assert not any(path.startswith("skills/task-spec/") for path in files), "embedded Task-Spec tree shipped"
assert not any("seamwise" in path.lower() and path.startswith(("src/", "vendor/", "skills/")) for path in files), "embedded Seamwise implementation shipped"
debris = [path for path in files if re.search(r"(^|/)(__pycache__|node_modules|test-results|playwright-report)(/|$)", path) or path.endswith((".pyc", ".pyo", ".DS_Store", ".tsbuildinfo"))]
assert not debris, f"package contains runtime debris: {debris}"
assert payload["version"] == "0.2.1"
print(f"PACKAGE=READY files={len(files)} skills={len(skills)}")
PY
