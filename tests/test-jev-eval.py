#!/usr/bin/env python3
"""tests/test-jev-eval.py - Unit tests for Jev evaluation toolkit."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Add repo root to import path so we can import scripts directly if needed
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import importlib.util

spec = importlib.util.spec_from_file_location(
    "jev_eval", str(REPO_ROOT / "scripts" / "jev-eval.py")
)
jev_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jev_eval)

FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "eval_fixture.jsonl"


class TestJevEval(unittest.TestCase):
    def setUp(self):
        self.assertTrue(FIXTURE_PATH.is_file(), f"Fixture missing at {FIXTURE_PATH}")
        with open(FIXTURE_PATH, "r", encoding="utf-8") as f:
            self.fixture_records = [json.loads(line) for line in f if line.strip()]

    def test_unlabeled_exclusion(self):
        """Unlabeled records must be excluded from evaluation and not treated as acceptable."""
        result = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        ds = result["dataset"]

        # Fixture contains 8 records: 6 labeled and 2 unlabeled (run-004:t1 and run-004:t2)
        self.assertEqual(ds["total_records"], 8)
        self.assertEqual(ds["missing_labels_excluded"], 2)
        self.assertEqual(ds["labeled_evaluated"], 6)

        # Missing labels must NOT be added to acceptable or defective counts
        self.assertEqual(
            ds["labeled_evaluated"],
            ds["human_acceptable"] + ds["human_defective"],
        )
        self.assertEqual(ds["human_acceptable"], 2)
        self.assertEqual(ds["human_defective"], 4)

        # Text report must clearly distinguish missing labels from acceptable examples
        report_text = jev_eval.format_report_text(result)
        self.assertIn("Missing human labels:", report_text)
        self.assertIn("[EXCLUDED: missing label != acceptable]", report_text)
        self.assertIn("Explicitly labeled records:", report_text)

    def test_unlabeled_shapes_handling(self):
        """Records with various shapes of missing/empty human labels must be excluded."""
        records = [
            {"id": "1", "human_label": None},
            {"id": "2", "human_label": {}},
            {"id": "3", "human_label": {"acceptable": None}},
            {"id": "4", "human_label": "invalid"},
            {"id": "5"},  # no human_label key
            {"id": "6", "human_label": {"acceptable": True}},
        ]
        result = jev_eval.evaluate_labeled_records(records, threshold=0.10)
        self.assertEqual(result["dataset"]["total_records"], 6)
        self.assertEqual(result["dataset"]["missing_labels_excluded"], 5)
        self.assertEqual(result["dataset"]["labeled_evaluated"], 1)
        self.assertEqual(result["dataset"]["human_acceptable"], 1)

    def test_false_accept_counts_at_default_threshold(self):
        """Verify false accept and coverage counts at threshold 0.10."""
        result = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        ov = result["overall"]

        # 4 out of 6 labeled records have risk_max <= 0.10:
        # run-001:t1 (0.04), run-001:t2 (0.05), run-002:t1 (0.08), run-003:t2 (0.07)
        self.assertEqual(ov["auto_accepted"], 4)
        self.assertAlmostEqual(ov["coverage_rate"], 4 / 6, places=4)

        # Among those 4 auto-accepted, 3 are defective (run-001:t2, run-002:t1, run-003:t2):
        # 3 FALSE ACCEPTS!
        self.assertEqual(ov["false_accepts"], 3)
        self.assertAlmostEqual(ov["false_accept_rate_of_accepted"], 3 / 4, places=4)
        self.assertAlmostEqual(ov["false_accept_rate_of_defective"], 3 / 4, places=4)

        # 1 safe true accept (run-001:t1)
        self.assertEqual(ov["true_accepts"], 1)
        # 1 correct escalation (run-003:t1, defective with risk_max=0.85)
        self.assertEqual(ov["correct_escalations"], 1)
        # 1 false escalation (run-002:t2, acceptable with risk_max=0.15)
        self.assertEqual(ov["false_escalations"], 1)

    def test_false_accept_counts_at_strict_threshold(self):
        """At strict threshold 0.04, false accepts drop to 0."""
        result = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.04)
        ov = result["overall"]

        # Only run-001:t1 has risk_max <= 0.04 (0.04)
        self.assertEqual(ov["auto_accepted"], 1)
        self.assertEqual(ov["false_accepts"], 0)
        self.assertEqual(ov["false_accept_rate_of_accepted"], 0.0)
        self.assertEqual(ov["true_accepts"], 1)

    def test_breakdown_by_named_risk(self):
        """Verify false accepts broken down by named risk type."""
        result = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        by_risk = result["by_risk_type"]

        # correctness_defect: flagged in run-001:t2 (false accept)
        self.assertEqual(by_risk["correctness_defect"]["human_flagged"], 1)
        self.assertEqual(by_risk["correctness_defect"]["false_accepts"], 1)
        self.assertEqual(by_risk["correctness_defect"]["signal_under_threshold"], 1)

        # security_risk: flagged in run-002:t1 (false accept)
        self.assertEqual(by_risk["security_risk"]["human_flagged"], 1)
        self.assertEqual(by_risk["security_risk"]["false_accepts"], 1)
        self.assertEqual(by_risk["security_risk"]["signal_under_threshold"], 1)

        # unrelated_change: flagged in run-002:t1 (false accept)
        self.assertEqual(by_risk["unrelated_change"]["human_flagged"], 1)
        self.assertEqual(by_risk["unrelated_change"]["false_accepts"], 1)
        self.assertEqual(by_risk["unrelated_change"]["signal_under_threshold"], 1)

        # regression_test_missing: flagged in run-003:t2 (false accept)
        self.assertEqual(by_risk["regression_test_missing"]["human_flagged"], 1)
        self.assertEqual(by_risk["regression_test_missing"]["false_accepts"], 1)
        self.assertEqual(by_risk["regression_test_missing"]["signal_under_threshold"], 1)

        # requirement_missing: flagged in run-003:t1 (correctly escalated, risk_max=0.85)
        self.assertEqual(by_risk["requirement_missing"]["human_flagged"], 1)
        self.assertEqual(by_risk["requirement_missing"]["false_accepts"], 0)
        self.assertEqual(by_risk["requirement_missing"]["signal_under_threshold"], 0)

        # check_weakened: flagged in run-003:t1 (correctly escalated, risk_max=0.85)
        self.assertEqual(by_risk["check_weakened"]["human_flagged"], 1)
        self.assertEqual(by_risk["check_weakened"]["false_accepts"], 0)
        self.assertEqual(by_risk["check_weakened"]["signal_under_threshold"], 0)

    def test_breakdown_by_diff_size_bucket(self):
        """Verify false accepts and coverage broken down by diff size bucket."""
        result = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        by_bucket = result["by_diff_size_bucket"]

        # small (<=100): run-001:t1 (acceptable), run-001:t2 (defective, FA)
        small = by_bucket["small (<=100)"]
        self.assertEqual(small["labeled"], 2)
        self.assertEqual(small["acceptable"], 1)
        self.assertEqual(small["defective"], 1)
        self.assertEqual(small["auto_accepted"], 2)
        self.assertEqual(small["coverage_rate"], 1.0)
        self.assertEqual(small["false_accepts"], 1)
        self.assertEqual(small["false_accept_rate"], 0.5)

        # medium (101-400): run-002:t1 (defective, FA), run-002:t2 (acceptable, escalated)
        med = by_bucket["medium (101-400)"]
        self.assertEqual(med["labeled"], 2)
        self.assertEqual(med["acceptable"], 1)
        self.assertEqual(med["defective"], 1)
        self.assertEqual(med["auto_accepted"], 1)
        self.assertEqual(med["coverage_rate"], 0.5)
        self.assertEqual(med["false_accepts"], 1)
        self.assertEqual(med["false_accept_rate"], 1.0)

        # large (401-600): run-003:t1 (defective, escalated)
        large = by_bucket["large (401-600)"]
        self.assertEqual(large["labeled"], 1)
        self.assertEqual(large["acceptable"], 0)
        self.assertEqual(large["defective"], 1)
        self.assertEqual(large["auto_accepted"], 0)
        self.assertEqual(large["false_accepts"], 0)

        # oversized (>600): run-003:t2 (defective, FA)
        oversized = by_bucket["oversized (>600)"]
        self.assertEqual(oversized["labeled"], 1)
        self.assertEqual(oversized["acceptable"], 0)
        self.assertEqual(oversized["defective"], 1)
        self.assertEqual(oversized["auto_accepted"], 1)
        self.assertEqual(oversized["false_accepts"], 1)
        self.assertEqual(oversized["false_accept_rate"], 1.0)

    def test_threshold_never_described_as_calibrated(self):
        """The report must never describe 0.10 as calibrated."""
        result = jev_eval.evaluate_labeled_records(self.fixture_records, threshold=0.10)
        self.assertFalse(result["threshold_calibrated"])
        self.assertEqual(result["threshold_status"], "uncalibrated_policy_default")

        report_text = jev_eval.format_report_text(result)
        self.assertIn("UNCALIBRATED POLICY DEFAULT", report_text)
        self.assertIn("not an empirically calibrated threshold", report_text)
        # Check that the word 'calibrated' does not appear without 'uncalibrated' or 'not'
        cleaned = report_text.lower().replace("uncalibrated", "").replace("not an empirically calibrated", "")
        self.assertNotIn("calibrated", cleaned)

    def test_prepare_candidate_records_from_archive(self):
        """Candidate records must have blank human labels and specific signal vectors."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)

            # 1. Run with Jev signals and critique verdict pass
            run1 = base / "run-2026-09-01"
            run1.mkdir()
            with (run1 / "run.json").open("w", encoding="utf-8") as f:
                json.dump({"run_id": "run-2026-09-01"}, f)
            with (run1 / "state.json").open("w", encoding="utf-8") as f:
                json.dump([
                    {
                        "name": "task-a",
                        "prompt": "fix issue in core",
                        "files": ["core.py"],
                        "pitfalls": ["trap1"],
                        "model": "gemini-3.8-flash-high",
                    }
                ], f)
            with (run1 / "task-a.diff").open("w", encoding="utf-8") as f:
                f.write("diff --git a/core.py b/core.py\n--- a/core.py\n+++ b/core.py\n@@ -1 +1 @@\n-old\n+new\n")
            with (run1 / "task-a.critique.json").open("w", encoding="utf-8") as f:
                json.dump({
                    "verdict": "pass",
                    "auto_accepted": True,
                    "jev": {
                        "attempted": True,
                        "route": "typesafe",
                        "model": "jev-1.13.0",
                        "risk_max": 0.04,
                        "signals": {
                            "requirement_missing": 0.01,
                            "correctness_defect": 0.04,
                            "security_risk": 0.0,
                        },
                    },
                }, f)

            # 2. Older run without Jev signals
            run2 = base / "run-2026-08-15"
            run2.mkdir()
            with (run2 / "state.json").open("w", encoding="utf-8") as f:
                json.dump([
                    {
                        "name": "task-b",
                        "prompt": "legacy prompt",
                    }
                ], f)
            with (run2 / "task-b.critique.json").open("w", encoding="utf-8") as f:
                json.dump({"verdict": "pass"}, f)

            records = jev_eval.prepare_candidate_records([run1, run2])
            self.assertEqual(len(records), 2)

            rec_a = next(r for r in records if r["task_name"] == "task-a")
            # Human label must remain strictly blank / None
            self.assertIsNone(rec_a["human_label"])
            # Critique verdict must NOT have set a label
            self.assertEqual(rec_a["diff_lines"], 2)
            self.assertEqual(rec_a["diff_stat"], "+1/-1")
            self.assertEqual(rec_a["diff_size_bucket"], "small (<=100)")
            # Specific signal vector is recorded
            self.assertIsNotNone(rec_a["jev"])
            self.assertEqual(rec_a["jev"]["risk_max"], 0.04)
            self.assertEqual(rec_a["jev"]["signals"]["correctness_defect"], 0.04)
            self.assertEqual(rec_a["jev"]["signals"]["requirement_missing"], 0.01)

            rec_b = next(r for r in records if r["task_name"] == "task-b")
            self.assertIsNone(rec_b["human_label"])
            self.assertIsNone(rec_b["jev"])

    def test_cli_report_text_and_json(self):
        """Test invoking scripts/jev-eval.py via subprocess CLI."""
        # Text report
        cmd_text = [
            sys.executable,
            str(REPO_ROOT / "scripts" / "jev-eval.py"),
            "report",
            "-i",
            str(FIXTURE_PATH),
            "-t",
            "0.10",
        ]
        res_text = subprocess.run(cmd_text, capture_output=True, text=True)
        self.assertEqual(res_text.returncode, 0)
        self.assertIn("JEV EVALUATION REPORT", res_text.stdout)
        self.assertIn("Coverage (auto-accepted):      4 / 6  (66.7%)", res_text.stdout)
        self.assertIn("False accepts:                 3", res_text.stdout)
        self.assertIn("UNCALIBRATED POLICY DEFAULT", res_text.stdout)

        # JSON report
        cmd_json = [
            sys.executable,
            str(REPO_ROOT / "scripts" / "jev-eval.py"),
            "report",
            "-i",
            str(FIXTURE_PATH),
            "-t",
            "0.10",
            "-f",
            "json",
        ]
        res_json = subprocess.run(cmd_json, capture_output=True, text=True)
        self.assertEqual(res_json.returncode, 0)
        parsed = json.loads(res_json.stdout)
        self.assertEqual(parsed["overall"]["false_accepts"], 3)
        self.assertEqual(parsed["overall"]["auto_accepted"], 4)
        self.assertFalse(parsed["threshold_calibrated"])

    def test_cli_prepare_subcommand(self):
        """Test invoking scripts/jev-eval.py prepare via subprocess CLI."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            run_dir = Path(tmp_dir) / "run-test"
            run_dir.mkdir()
            with (run_dir / "state.json").open("w", encoding="utf-8") as f:
                json.dump([{"name": "t1", "prompt": "cmd test"}], f)
            with (run_dir / "t1.diff").open("w", encoding="utf-8") as f:
                f.write("+add line\n")

            out_file = Path(tmp_dir) / "candidates.jsonl"
            cmd = [
                sys.executable,
                str(REPO_ROOT / "scripts" / "jev-eval.py"),
                "prepare",
                str(run_dir),
                "-o",
                str(out_file),
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0)
            self.assertTrue(out_file.is_file())
            with out_file.open("r", encoding="utf-8") as f:
                lines = [json.loads(line) for line in f if line.strip()]
            self.assertEqual(len(lines), 1)
            self.assertIsNone(lines[0]["human_label"])
            self.assertEqual(lines[0]["diff_lines"], 1)


if __name__ == "__main__":
    unittest.main()
