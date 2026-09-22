#!/usr/bin/env bash
# Observable adapter failures: inherited stdin/pipes, budgets, policies, bad streams.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

adapter = Path(sys.argv[1]) / "skills/task-loop/scripts/engines/omp.sh"
with tempfile.TemporaryDirectory(prefix="cvg-omp-test-") as directory:
    root = Path(directory)
    fake = root / "fake-omp"
    fake.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
if args[:2] == ["config", "get"]:
    value = ["openai"] if args[2] == "disabledProviders" else {"bash": "deny"}
    print(json.dumps({"value": value}))
    sys.exit(0)
# This must read EOF, even when the engine's parent keeps its pipe open.
sys.stdin.read()
policy = json.loads(Path(args[args.index("--config") + 1]).read_text())
assert "openai" in policy["disabledProviders"], "operator provider deny lost"
assert policy["tools"]["approval"]["bash"] == "deny", "operator tool deny lost"
assert policy["mcp"]["enableProjectConfig"] is False
scenario = os.environ["SCENARIO"]
if scenario == "timeout": time.sleep(5)
if scenario == "empty": sys.exit(0)
if scenario == "child-pipe": subprocess.Popen(["sleep", "4"])
message = {"role": "assistant", "stopReason": "error" if scenario == "error" else "stop", "usage": {"totalTokens": 12}}
print(json.dumps({"type": "message_end", "message": message}))
# agent_end repeats the same message: usage must not double-count it.
print(json.dumps({"type": "agent_end", "messages": [message]}))
''')
    fake.chmod(0o755)
    prompt = root / "prompt.txt"
    prompt.write_text("Exercise a disposable adapter fixture.")
    base = ["bash", str(adapter), "--workdir", str(root), "--prompt-file", str(prompt)]
    env = dict(os.environ, CVG_OMP_CMD=str(fake))
    # An intentionally open stdin reproduces launch from an orchestration host.
    process = subprocess.Popen(base + ["--timeout", "5"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=dict(env, SCENARIO="child-pipe"))
    try:
        process.wait(timeout=3)
        process.stdin.close()
        out, err = process.stdout.read(), process.stderr.read()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert process.returncode == 0, (out, err)
    assert "ENGINE_TOKENS=12" in out and "ENGINE_TOKENS=24" not in out, out
    print("OMP_STDIN_AND_CHILD_PIPE=PASS")
    print("OMP_OPERATOR_DENIES_PRESERVED=PASS")
    for scenario in ("error", "empty"):
        result = subprocess.run(base + ["--timeout", "5"], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=8,
                                env=dict(env, SCENARIO=scenario))
        assert result.returncode != 0, (scenario, result.stdout)
    print("OMP_INCOMPLETE_OR_ERROR_STREAM=BLOCKED")
    result = subprocess.run(base + ["--timeout", "1"], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=5,
                            env=dict(env, SCENARIO="timeout"))
    assert result.returncode == 124, (result.returncode, result.stdout, result.stderr)
    print("OMP_TIMEOUT=124")

# A harness can route several model families. Its name cannot prove a judge
# independent; preserve the explicit uncertainty instead of claiming a pass.
import importlib.util
from unittest.mock import patch
scripts = Path(sys.argv[1]) / "skills/task-to-runtime-contract/scripts"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("verify_work", scripts / "verify-work.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
with patch.object(verifier.shutil, "which", return_value="/fixture/codex"):
    family = verifier.worker_family({"execution_backend": "omp"})
    assert verifier.pick_judge("codex", family) == ("codex", "unknown")
    assert verifier.pick_judge("codex", "openai") == ("codex", "same-family")
print("OMP_CROSS_FAMILY_NOT_ASSUMED=PASS")
PY
