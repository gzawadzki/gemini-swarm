#!/usr/bin/env python3
"""tests/test-jev-eval.py - Unit tests for Jev evaluation toolkit."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import importlib.util
spec = importlib.util.spec_from_file_location("jev_eval", str(REPO_ROOT / "scripts" / "jev-eval.py"))
jev_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jev_eval)

FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "eval_fixture.jsonl"


class TestJevEval(unittest.TestCase):
    def setUp(self):
        with open(FIXTURE_PATH, "r", encoding="utf-8") as f:
            self.fixture_records = [json.loads(line) for line in f if line.strip()]

    def test_unlabeled_exclusion(self):
        """Unlabeled records are excluded from evaluation and never treated as acceptable."""
        res = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        ds = res["dataset"]
        self.assertEqual(ds["total_records"], 10)
        self.assertEqual(ds["missing_labels_excluded"], 2)
        self.assertEqual(ds["total_labeled"], 8)

        report = jev_eval.format_report_text(res)
        self.assertIn("Missing human labels:          2  [EXCLUDED: missing label != acceptable]", report)

    def test_unscored_labeled_records_separated_from_denominator(self):
        """Labeled archives with no Jev signals are not counted as false escalations or in coverage."""
        res = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        ds = res["dataset"]
        ov = res["overall"]

        # 2 labeled records have jev: null (run-005:t1 and run-005:t2)
        self.assertEqual(ds["unscored_labeled_excluded"], 2)
        # Denominator for Jev scoring metrics is strictly the 6 scored records
        self.assertEqual(ds["scored_denominator"], 6)
        self.assertEqual(ov["scored_denominator"], 6)

        # Coverage is 4 auto-accepted / 6 scored (NOT 4 / 8)
        self.assertEqual(ov["auto_accepted"], 4)
        self.assertAlmostEqual(ov["coverage_rate"], 4 / 6, places=4)

        # Unscored records must NOT become false escalations (only run-002:t2 is a false escalation)
        self.assertEqual(ov["false_escalations"], 1)
        # Only run-003:t1 is a correct escalation
        self.assertEqual(ov["correct_escalations"], 1)

    def test_false_accept_counts_and_threshold_scaling(self):
        """Verify false accepts at default 0.10 and strict 0.04 thresholds."""
        res_default = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        ov_def = res_default["overall"]
        self.assertEqual(ov_def["auto_accepted"], 4)
        self.assertEqual(ov_def["false_accepts"], 3)
        self.assertAlmostEqual(ov_def["false_accept_rate_of_accepted"], 3 / 4, places=4)
        self.assertEqual(ov_def["true_accepts"], 1)

        res_strict = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.04)
        ov_str = res_strict["overall"]
        self.assertEqual(ov_str["auto_accepted"], 1)
        self.assertEqual(ov_str["false_accepts"], 0)
        self.assertEqual(ov_str["true_accepts"], 1)

    def test_breakdown_by_named_risk(self):
        """Verify false accepts tracked per named risk type on scored records."""
        res = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        by_risk = res["by_risk_type"]

        self.assertEqual(by_risk["correctness_defect"]["false_accepts"], 1)
        self.assertEqual(by_risk["security_risk"]["false_accepts"], 1)
        self.assertEqual(by_risk["unrelated_change"]["false_accepts"], 1)
        self.assertEqual(by_risk["regression_test_missing"]["false_accepts"], 1)
        self.assertEqual(by_risk["requirement_missing"]["false_accepts"], 0)
        self.assertEqual(by_risk["check_weakened"]["false_accepts"], 0)

    def test_breakdown_by_diff_size_bucket(self):
        """Verify scored records, coverage, and false accepts per diff size bucket."""
        res = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        b = res["by_diff_size_bucket"]

        self.assertEqual(b["small (<=100)"]["scored"], 2)
        self.assertEqual(b["small (<=100)"]["auto_accepted"], 2)
        self.assertEqual(b["small (<=100)"]["false_accepts"], 1)

        self.assertEqual(b["medium (101-400)"]["scored"], 2)
        self.assertEqual(b["medium (101-400)"]["auto_accepted"], 1)
        self.assertEqual(b["medium (101-400)"]["false_accepts"], 1)

        self.assertEqual(b["large (401-600)"]["scored"], 1)
        self.assertEqual(b["large (401-600)"]["auto_accepted"], 0)

        self.assertEqual(b["oversized (>600)"]["scored"], 1)
        self.assertEqual(b["oversized (>600)"]["auto_accepted"], 1)
        self.assertEqual(b["oversized (>600)"]["false_accepts"], 1)

    def test_threshold_never_described_as_calibrated(self):
        """Report text and JSON must clearly disclaim the threshold as uncalibrated."""
        res = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        self.assertFalse(res["threshold_calibrated"])
        self.assertEqual(res["threshold_status"], "uncalibrated_policy_default")

        report = jev_eval.format_report_text(res)
        self.assertIn("UNCALIBRATED POLICY DEFAULT", report)
        self.assertIn("not an empirically calibrated threshold", report)
        cleaned = report.lower().replace("uncalibrated", "").replace("not an empirically calibrated", "")
        self.assertNotIn("calibrated", cleaned)

    def test_prepare_and_cli_pipeline(self):
        """Test archive extraction with blank human labels and CLI invocation."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            run1 = base / "run-2026-09-01"
            run1.mkdir()
            with (run1 / "state.json").open("w", encoding="utf-8") as f:
                json.dump([{"name": "t1", "prompt": "p", "files": ["f.py"]}], f)
            with (run1 / "t1.diff").open("w", encoding="utf-8") as f:
                f.write("+newline\n")
            with (run1 / "t1.critique.json").open("w", encoding="utf-8") as f:
                json.dump({"verdict": "pass", "jev": {"attempted": True, "risk_max": 0.03, "signals": {"correctness_defect": 0.03}}}, f)

            run2 = base / "run-legacy"
            run2.mkdir()
            with (run2 / "state.json").open("w", encoding="utf-8") as f:
                json.dump([{"name": "t2", "prompt": "p2"}], f)

            out_cand = base / "cand.jsonl"
            res_prep = subprocess.run(
                [sys.executable, str(REPO_ROOT / "scripts" / "jev-eval.py"), "prepare", str(base), "-o", str(out_cand)],
                capture_output=True, text=True
            )
            self.assertEqual(res_prep.returncode, 0)
            with out_cand.open("r", encoding="utf-8") as f:
                cands = [json.loads(line) for line in f if line.strip()]

            self.assertEqual(len(cands), 2)
            c1 = next(c for c in cands if c["task_name"] == "t1")
            self.assertIsNone(c1["human_label"])
            self.assertEqual(c1["jev"]["risk_max"], 0.03)
            self.assertEqual(c1["diff_lines"], 1)

            c2 = next(c for c in cands if c["task_name"] == "t2")
            self.assertIsNone(c2["human_label"])
            self.assertIsNone(c2["jev"])

            # Test report CLI on fixture
            res_rep = subprocess.run(
                [sys.executable, str(REPO_ROOT / "scripts" / "jev-eval.py"), "report", "-i", str(FIXTURE_PATH), "-t", "0.10", "-f", "json"],
                capture_output=True, text=True
            )
            self.assertEqual(res_rep.returncode, 0)
            rep_json = json.loads(res_rep.stdout)
            self.assertEqual(rep_json["overall"]["false_accepts"], 3)
            self.assertEqual(rep_json["dataset"]["unscored_labeled_excluded"], 2)


if __name__ == "__main__":
    unittest.main()
