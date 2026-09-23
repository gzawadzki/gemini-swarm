#!/usr/bin/env python3
"""Focused test suite for run-outcome and rework measurement."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

import importlib.util
spec = importlib.util.spec_from_file_location("run_outcome", PROJECT_ROOT / "scripts" / "run-outcome.py")
run_outcome = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_outcome)

TRACE_DELIVERY_ONLY = """\
2026-09-19T16:18:17Z launch  -                    run.meta         20260919T161817Z
2026-09-19T16:19:05Z launch  t1                   prompt.submit    114 bytes
2026-09-19T16:19:23Z launch  t1                   prompt.stalled   agent did not react in 15s (attempt 1)
2026-09-19T16:19:26Z launch  t1                   prompt.landed    state_change_seq moved (attempt 2)
"""

TRACE_WITH_REWORK = """\
2026-09-19T16:18:17Z launch  -                    run.meta         20260919T161817Z
2026-09-19T16:19:05Z launch  t1                   prompt.submit    114 bytes
2026-09-19T16:19:06Z launch  t1                   prompt.landed    agent left idle (attempt 1)
2026-09-19T16:25:00Z review  t1                   prompt.rework    fix failing assertion in test
"""


class TestTraceAndRework(unittest.TestCase):
    def test_missing_trace_returns_none(self):
        rework, delivery = run_outcome.parse_trace_events(None)
        self.assertIsNone(rework)
        self.assertIsNone(delivery)

    def test_launcher_delivery_does_not_imply_zero_rework(self):
        # A single initial prompt in trace cannot justify rework=0.
        rework, delivery = run_outcome.parse_trace_events(TRACE_DELIVERY_ONLY)
        self.assertIsNone(rework)
        self.assertEqual(delivery, 1)

    def test_trace_with_explicit_rework_event(self):
        rework, delivery = run_outcome.parse_trace_events(TRACE_WITH_REWORK)
        self.assertEqual(rework, 1)
        self.assertEqual(delivery, 0)


class TestValueParsers(unittest.TestCase):
    def test_duration(self):
        self.assertIsNone(run_outcome.parse_duration(None))
        self.assertEqual(run_outcome.parse_duration("25m"), 1500.0)
        self.assertEqual(run_outcome.parse_duration("1500s"), 1500.0)
        self.assertEqual(run_outcome.parse_duration("1h"), 3600.0)
        self.assertEqual(run_outcome.parse_duration(900), 900.0)

    def test_cost(self):
        self.assertIsNone(run_outcome.parse_cost(None))
        self.assertEqual(run_outcome.parse_cost("$0.42"), 0.42)
        self.assertEqual(run_outcome.parse_cost(0.42), 0.42)

    def test_post_merge_fixes(self):
        # 0 must be preserved as int 0 (zero rework), never None (unknown)
        self.assertEqual(run_outcome.parse_post_merge_fixes(0), 0)
        self.assertEqual(run_outcome.parse_post_merge_fixes("0"), 0)
        self.assertEqual(run_outcome.parse_post_merge_fixes(2), 2)
        self.assertIsNone(run_outcome.parse_post_merge_fixes(None))
        self.assertIsNone(run_outcome.parse_post_merge_fixes("unknown"))

    def test_human_minutes(self):
        self.assertIsNone(run_outcome.parse_human_minutes(None))
        self.assertEqual(run_outcome.parse_human_minutes("15m"), 15.0)
        self.assertEqual(run_outcome.parse_human_minutes(20.5), 20.5)


class TestArchiveFixturesAndAnnotation(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.runs_dir = Path(self.temp_dir.name)

        # Fixture 1: Unannotated archive with launcher trace
        self.run1 = self.runs_dir / "20260919T100000Z"
        self.run1.mkdir()
        (self.run1 / "run.json").write_text(json.dumps({"run_id": "20260919T100000Z"}), encoding="utf-8")
        (self.run1 / "trace.log").write_text(TRACE_DELIVERY_ONLY, encoding="utf-8")

        # Fixture 2: Unannotated archive without trace
        self.run2 = self.runs_dir / "20260919T110000Z"
        self.run2.mkdir()
        (self.run2 / "run.json").write_text(json.dumps({"run_id": "20260919T110000Z"}), encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_historical_reading_marks_absent_as_unknown(self):
        data1 = run_outcome.read_run_data(self.run1)
        self.assertFalse(data1["annotated"])
        self.assertIsNone(data1["prompt_retries"])  # Unknown rework
        self.assertEqual(data1["prompt_delivery_retries"], 1)
        self.assertIsNone(data1["merge_outcome"])
        self.assertIsNone(data1["post_merge_fixes"])

        data2 = run_outcome.read_run_data(self.run2)
        self.assertIsNone(data2["prompt_retries"])
        self.assertIsNone(data2["prompt_delivery_retries"])

    def test_annotate_preserves_zero_and_overrides(self):
        annotated = run_outcome.annotate_run(
            run_dir=self.run1,
            human_minutes=15.0,
            merge_outcome="merged",
            post_merge_fixes=0,
            elapsed_seconds=1500.0,
            cost_usd=0.35,
            prompt_retries=0,  # Human explicitly established 0 rework
            notes="clean merge",
        )
        self.assertTrue(annotated["annotated"])
        self.assertEqual(annotated["post_merge_fixes"], 0)
        self.assertEqual(annotated["prompt_retries"], 0)
        self.assertEqual(annotated["human_minutes"], 15.0)

        # File check
        with open(self.run1 / "outcome.json", "r", encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(saved["post_merge_fixes"], 0)
        self.assertEqual(saved["prompt_retries"], 0)

        # Partial update preserves other fields
        updated = run_outcome.annotate_run(run_dir=self.run1, post_merge_fixes=1)
        self.assertEqual(updated["post_merge_fixes"], 1)
        self.assertEqual(updated["human_minutes"], 15.0)


class TestCLI(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.runs_dir = Path(self.temp_dir.name)
        self.run_dir = self.runs_dir / "20260920T100000Z"
        self.run_dir.mkdir()
        (self.run_dir / "run.json").write_text(json.dumps({"run_id": "20260920T100000Z"}), encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_cmd(self, args: list[str]) -> subprocess.CompletedProcess:
        cmd = [sys.executable, str(PROJECT_ROOT / "scripts" / "run-outcome.py")] + args
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_cli_annotate_and_report_json(self):
        p1 = self.run_cmd([
            "annotate", "20260920T100000Z",
            "--runs-dir", str(self.runs_dir),
            "-o", "merged",
            "-f", "0",
            "-m", "12",
            "-e", "20m",
            "-c", "$0.20",
        ])
        self.assertEqual(p1.returncode, 0, msg=p1.stderr)

        p2 = self.run_cmd(["report", "--runs-dir", str(self.runs_dir), "--json"])
        self.assertEqual(p2.returncode, 0)
        records = json.loads(p2.stdout)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["merge_outcome"], "merged")
        self.assertEqual(records[0]["post_merge_fixes"], 0)
        self.assertEqual(records[0]["human_minutes"], 12.0)
        self.assertEqual(records[0]["elapsed_seconds"], 1200.0)
        self.assertEqual(records[0]["cost_usd"], 0.20)
        self.assertIsNone(records[0]["prompt_retries"])  # Absent rework marked unknown/null

    def test_cli_report_table_formats_unknown(self):
        p = self.run_cmd(["report", "--runs-dir", str(self.runs_dir)])
        self.assertEqual(p.returncode, 0)
        self.assertIn("RUN ID", p.stdout)
        self.assertIn("unknown", p.stdout)


if __name__ == "__main__":
    unittest.main()
