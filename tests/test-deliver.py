#!/usr/bin/env python3
"""Regression checks for demand identity, budget accounting and false readiness."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
from _cvg_deliver import Delivery, DeliveryError, SCHEMA, parser


class DeliveryRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cvg-deliver-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.repository("source")

    def repository(self, name):
        root = self.root / name
        root.mkdir()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "product.py").write_text("VALUE = 1\n")
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=test", "-c", "user.email=test@localhost", "commit", "-qm", "source"], check=True)
        return root

    def delivery(self, project=None, demand="same-id"):
        args = parser().parse_args(["--project-root", str(project or self.project), "--cvg-version", "0.2.1",
                                    "--taskspec-bin", "taskspec", "--seamwise-bin", "seamwise", "resume", "--demand", demand])
        return Delivery(args)

    def seed(self, delivery):
        delivery.workspace.mkdir(parents=True)
        intent = delivery.workspace / "intent.txt"
        intent.write_text("own demand")
        delivery.state = {"contract": SCHEMA, "project": str(delivery.project), "workspace": str(delivery.workspace),
                          "demand": delivery.args.demand, "phase": "preparing", "limits": {"max_seconds": 1000},
                          "intent": {"path": "intent.txt", "sha256": hashlib.sha256(intent.read_bytes()).hexdigest()},
                          "commands": []}
        delivery.save()

    def test_same_identifier_never_reuses_another_projects_checkpoint(self):
        first = self.delivery()
        self.seed(first)
        second = self.delivery(self.repository("other"))
        self.assertNotEqual(first.home, second.home)
        self.assertFalse(second.state_path.exists())
        second.home.mkdir(parents=True)
        second.state_path.write_bytes(first.state_path.read_bytes())
        with self.assertRaisesRegex(DeliveryError, "identity"):
            second.load()

    def test_modified_intent_cannot_resume_original_authority(self):
        delivery = self.delivery()
        self.seed(delivery)
        (delivery.workspace / "intent.txt").write_text("different demand")
        with self.assertRaisesRegex(DeliveryError, "intent changed"):
            delivery.load()

    def test_repeated_recovery_charges_only_unaccounted_interval(self):
        delivery = self.delivery()
        self.seed(delivery)
        state = json.loads(delivery.state_path.read_text())
        state.update(elapsed_seconds=20, commands=[{"status": "started", "started_at": 100, "accounted_at": 110}])
        delivery.state_path.write_text(json.dumps(state))
        with patch("_cvg_deliver.time.time", return_value=130), patch("_cvg_deliver.time.monotonic", return_value=50):
            delivery.load()
            self.assertEqual(delivery.remaining(), 960)
            delivery.save()
        with patch("_cvg_deliver.time.time", return_value=140), patch("_cvg_deliver.time.monotonic", return_value=80):
            delivery.load()
            self.assertEqual(delivery.remaining(), 950)

    def test_signing_key_and_external_backlog_do_not_cross_demand_boundary(self):
        delivery = self.delivery()
        with patch.dict(os.environ, {"TASKSPEC_SIGNING_KEY": "other-project-secret", "TASKSPEC_BACKLOG_DIR": "/other/tasks", "CVG_VERIFIER": "/untrusted/verifier"}):
            env = delivery.environment()
        self.assertNotIn("TASKSPEC_SIGNING_KEY", env)
        self.assertNotIn("CVG_VERIFIER", env)
        self.assertEqual(Path(env["TASKSPEC_BACKLOG_DIR"]), delivery.workspace / "cvg/tasks")

    def test_settled_but_unavailable_judge_never_counts_as_independent_acceptance(self):
        delivery = self.delivery()
        self.seed(delivery)
        log = delivery.home / "attempt.log"
        log.write_text("CHECK_VERIFY=UNAVAILABLE\nTASK_LOOP=LOCAL_SETTLED\n")
        delivery.state["commands"] = [{"label": "execute T-example", "log": str(log)}]
        with self.assertRaisesRegex(DeliveryError, "no upheld"):
            delivery.require_independent_proof("T-example")
        log.write_text("CHECK_VERIFY=UPHELD\nTASK_LOOP=NO_OP\n")
        with self.assertRaisesRegex(DeliveryError, "no upheld"):
            delivery.require_independent_proof("T-example")

    def test_product_drift_invalidates_clean_delivery_even_when_head_is_unchanged(self):
        delivery = self.delivery()
        delivery.home.mkdir(parents=True)
        subprocess.run(["git", "clone", "-q", str(self.project), str(delivery.workspace)], check=True)
        delivery.check_product_clean()
        (delivery.workspace / "product.py").write_text("VALUE = 2\n")
        with self.assertRaisesRegex(DeliveryError, "uncommitted product"):
            delivery.check_product_clean()

    def test_resumption_continues_previously_approved_authorization(self):
        delivery = self.delivery()
        delivery.state = {"phase": "authorizing", "reviewer": "owner", "alignment_digest": "reviewed-digest", "commands": []}
        def continue_authorization():
            self.assertEqual(delivery.args.reviewer, "owner")
            self.assertEqual(delivery.args.alignment_digest, "reviewed-digest")
            return "READY_FOR_ACCEPTANCE"
        with patch.object(delivery, "authorize", side_effect=continue_authorization):
            self.assertEqual(delivery.resume(), "READY_FOR_ACCEPTANCE")


if __name__ == "__main__":
    unittest.main()
