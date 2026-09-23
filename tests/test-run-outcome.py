#!/usr/bin/env python3
"""Focused test suite for run-outcome and rework measurement.

Verifies:
  1. Prompt retries are derived correctly from available trace logs.
  2. Zero retries is distinguished from missing/unknown trace data.
  3. Absent data is always marked unknown (None), never assumed to be zero.
  4. Historical archives without annotations remain readable and non-destructive.
  5. Annotations write outcome.json cleanly in the archive dir after cleanup.
  6. CLI subcommands (annotate, report, show) format text and JSON correctly.

Stdlib-only: uses unittest with no external dependencies.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

# Import run-outcome functions directly
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

import importlib.util
spec = importlib.util.spec_from_file_location("run_outcome", PROJECT_ROOT / "scripts" / "run-outcome.py")
run_outcome = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_outcome)


SAMPLE_TRACE_WITH_RETRIES = """\
2026-09-19T16:18:17Z launch  -                    run.meta         20260919T161817Z skill=97fe877 dirty=0
2026-09-19T16:18:53Z launch  -                    run.start        2 task(s)
2026-09-19T16:19:05Z launch  task-a               prompt.submit    114 bytes
2026-09-19T16:19:23Z launch  task-a               prompt.stalled   herdr accepted it, agent did not react in 15s (attempt 1)
2026-09-19T16:19:26Z launch  task-a               prompt.landed    state_change_seq moved (attempt 2)
2026-09-19T16:19:33Z launch  task-b               prompt.submit    120 bytes
2026-09-19T16:19:51Z launch  task-b               prompt.stalled   herdr accepted it, agent did not react in 15s (attempt 1)
2026-09-19T16:19:54Z launch  task-b               prompt.landed    state_change_seq moved (attempt 2)
"""

SAMPLE_TRACE_ZERO_RETRIES = """\
2026-09-19T16:18:17Z launch  -                    run.meta         20260919T161817Z
2026-09-19T16:19:05Z launch  task-a               prompt.submit    114 bytes
2026-09-19T16:19:06Z launch  task-a               prompt.landed    state_change_seq moved (attempt 1)
2026-09-19T16:19:10Z launch  task-b               prompt.submit    100 bytes
2026-09-19T16:19:12Z launch  task-b               prompt.landed    agent left idle (attempt 1)
"""

SAMPLE_TRACE_NO_PROMPTS = """\
2026-09-19T16:18:17Z launch  -                    run.meta         20260919T161817Z
2026-09-19T16:18:53Z launch  -                    run.start        1 task(s)
2026-09-19T16:18:54Z launch  task-a               recon.accept     2 file(s)
"""


class TestDerivePromptRetries(unittest.TestCase):
    def test_missing_trace_returns_none(self):
        # A missing trace must be unknown (None), NEVER 0 by assumption
        self.assertIsNone(run_outcome.derive_prompt_retries(None))

    def test_empty_trace_returns_none(self):
        # An empty trace file contains no prompt data -> unknown
        self.assertIsNone(run_outcome.derive_prompt_retries(""))
        self.assertIsNone(run_outcome.derive_prompt_retries("   \n\n  "))

    def test_trace_without_prompt_events_returns_none(self):
        # Trace exists but has no prompt.* events -> absent prompt data is unknown
        self.assertIsNone(run_outcome.derive_prompt_retries(SAMPLE_TRACE_NO_PROMPTS))

    def test_trace_with_zero_retries(self):
        # Trace proves prompts landed on attempt 1 with zero retries -> 0
        retries = run_outcome.derive_prompt_retries(SAMPLE_TRACE_ZERO_RETRIES)
        self.assertEqual(retries, 0)

    def test_trace_with_retries(self):
        # Trace shows task-a retried once (attempt 2) and task-b retried once (attempt 2) -> 2
        retries = run_outcome.derive_prompt_retries(SAMPLE_TRACE_WITH_RETRIES)
        self.assertEqual(retries, 2)

    def test_trace_with_multiple_attempts_and_rejections(self):
        trace = """\
2026-09-19T16:19:05Z launch  t1 prompt.submit 100 bytes
2026-09-19T16:19:06Z launch  t1 prompt.submit attempt 1 rejected by herdr: busy
2026-09-19T16:19:10Z launch  t1 prompt.stalled herdr accepted it, agent did not react in 15s (attempt 2)
2026-09-19T16:19:15Z launch  t1 prompt.landed state_change_seq moved (attempt 3)
"""
        # attempt 3 landed -> 2 retries
        self.assertEqual(run_outcome.derive_prompt_retries(trace), 2)

    def test_trace_prompt_lost(self):
        trace = """\
2026-09-19T16:19:05Z launch  t1 prompt.submit 100 bytes
2026-09-19T16:19:20Z launch  t1 prompt.stalled herdr accepted it (attempt 1)
2026-09-19T16:19:35Z launch  t1 prompt.stalled herdr accepted it (attempt 2)
2026-09-19T16:19:36Z launch  t1 prompt.lost both attempts failed
"""
        self.assertEqual(run_outcome.derive_prompt_retries(trace), 1)

    def test_trace_explicit_retry_event(self):
        trace = """\
2026-09-19T16:19:05Z launch  t1 prompt.submit 100 bytes
2026-09-19T16:19:08Z launch  t1 prompt.retry retrying prompt submission
2026-09-19T16:19:10Z launch  t1 prompt.landed state_change_seq moved (attempt 1)
"""
        self.assertEqual(run_outcome.derive_prompt_retries(trace), 1)


class TestValueParsers(unittest.TestCase):
    def test_parse_duration(self):
        self.assertIsNone(run_outcome.parse_duration(None))
        self.assertIsNone(run_outcome.parse_duration("unknown"))
        self.assertEqual(run_outcome.parse_duration(900), 900.0)
        self.assertEqual(run_outcome.parse_duration("900s"), 900.0)
        self.assertEqual(run_outcome.parse_duration("15m"), 900.0)
        self.assertEqual(run_outcome.parse_duration("1h30m"), 5400.0)
        self.assertEqual(run_outcome.parse_duration("1.5h"), 5400.0)
        self.assertEqual(run_outcome.parse_duration("15:30"), 930.0)
        self.assertEqual(run_outcome.parse_duration("1:15:30"), 4530.0)

    def test_parse_cost(self):
        self.assertIsNone(run_outcome.parse_cost(None))
        self.assertIsNone(run_outcome.parse_cost("unknown"))
        self.assertEqual(run_outcome.parse_cost(0.25), 0.25)
        self.assertEqual(run_outcome.parse_cost("0.25"), 0.25)
        self.assertEqual(run_outcome.parse_cost("$0.42"), 0.42)
        self.assertEqual(run_outcome.parse_cost(0.0), 0.0)

    def test_parse_post_merge_fixes(self):
        # 0 must be preserved as int 0! Never None!
        self.assertEqual(run_outcome.parse_post_merge_fixes(0), 0)
        self.assertEqual(run_outcome.parse_post_merge_fixes("0"), 0)
        self.assertEqual(run_outcome.parse_post_merge_fixes(2), 2)
        self.assertEqual(run_outcome.parse_post_merge_fixes("3"), 3)
        self.assertEqual(run_outcome.parse_post_merge_fixes("fixed typo in readme"), "fixed typo in readme")
        self.assertIsNone(run_outcome.parse_post_merge_fixes(None))
        self.assertIsNone(run_outcome.parse_post_merge_fixes("unknown"))

    def test_parse_human_minutes(self):
        self.assertIsNone(run_outcome.parse_human_minutes(None))
        self.assertIsNone(run_outcome.parse_human_minutes("unknown"))
        self.assertEqual(run_outcome.parse_human_minutes(15), 15.0)
        self.assertEqual(run_outcome.parse_human_minutes("20.5"), 20.5)
        self.assertEqual(run_outcome.parse_human_minutes("15m"), 15.0)
        self.assertEqual(run_outcome.parse_human_minutes("10 mins"), 10.0)


class TestArchiveFixturesAndAnnotation(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.runs_dir = Path(self.temp_dir.name)

        # Fixture 1: run with trace containing 2 retries, unannotated
        self.run_retries_dir = self.runs_dir / "20260919T100000Z"
        self.run_retries_dir.mkdir(parents=True)
        (self.run_retries_dir / "run.json").write_text(
            json.dumps({"run_id": "20260919T100000Z", "started_at": 1789830000}),
            encoding="utf-8",
        )
        (self.run_retries_dir / "trace.log").write_text(SAMPLE_TRACE_WITH_RETRIES, encoding="utf-8")

        # Fixture 2: run with trace containing 0 retries, unannotated
        self.run_zero_dir = self.runs_dir / "20260919T110000Z"
        self.run_zero_dir.mkdir(parents=True)
        (self.run_zero_dir / "run.json").write_text(
            json.dumps({"run_id": "20260919T110000Z", "started_at": 1789833600}),
            encoding="utf-8",
        )
        (self.run_zero_dir / "trace.log").write_text(SAMPLE_TRACE_ZERO_RETRIES, encoding="utf-8")

        # Fixture 3: run without trace (tracing was disabled at launch)
        self.run_no_trace_dir = self.runs_dir / "20260919T120000Z"
        self.run_no_trace_dir.mkdir(parents=True)
        (self.run_no_trace_dir / "run.json").write_text(
            json.dumps({"run_id": "20260919T120000Z", "started_at": 1789837200}),
            encoding="utf-8",
        )

        # Fixture 4: run with trace but no prompt entries
        self.run_no_prompts_dir = self.runs_dir / "20260919T130000Z"
        self.run_no_prompts_dir.mkdir(parents=True)
        (self.run_no_prompts_dir / "run.json").write_text(
            json.dumps({"run_id": "20260919T130000Z", "started_at": 1789840800}),
            encoding="utf-8",
        )
        (self.run_no_prompts_dir / "trace.log").write_text(SAMPLE_TRACE_NO_PROMPTS, encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_historical_archive_readable_and_absent_marked_unknown(self):
        # 1. Run with retries trace: retries derived as 2, other fields None (unknown)
        data1 = run_outcome.read_run_data(self.run_retries_dir)
        self.assertEqual(data1["run_id"], "20260919T100000Z")
        self.assertFalse(data1["annotated"])
        self.assertEqual(data1["prompt_retries"], 2)
        self.assertIsNone(data1["merge_outcome"])
        self.assertIsNone(data1["human_minutes"])
        self.assertIsNone(data1["post_merge_fixes"])
        self.assertIsNone(data1["elapsed_seconds"])
        self.assertIsNone(data1["cost_usd"])

        # 2. Run with zero retries trace: retries derived as 0
        data2 = run_outcome.read_run_data(self.run_zero_dir)
        self.assertEqual(data2["prompt_retries"], 0)
        self.assertIsNone(data2["human_minutes"])

        # 3. Run without trace: retries must be None (unknown), NOT 0!
        data3 = run_outcome.read_run_data(self.run_no_trace_dir)
        self.assertIsNone(data3["prompt_retries"])
        self.assertEqual(data3["retries_source"], "absent")

        # 4. Run with trace lacking prompt events: retries must be None (unknown)
        data4 = run_outcome.read_run_data(self.run_no_prompts_dir)
        self.assertIsNone(data4["prompt_retries"])

    def test_annotate_run_writes_outcome_json_and_derives_retries(self):
        res = run_outcome.annotate_run(
            run_dir=self.run_retries_dir,
            human_minutes=15.0,
            merge_outcome="merged",
            post_merge_fixes=0,
            elapsed_seconds=900.0,
            cost_usd=0.35,
            notes="clean merge, zero rework",
        )

        outcome_file = self.run_retries_dir / "outcome.json"
        self.assertTrue(outcome_file.is_file())

        with open(outcome_file, "r", encoding="utf-8") as f:
            saved = json.load(f)

        self.assertEqual(saved["merge_outcome"], "merged")
        self.assertEqual(saved["human_minutes"], 15.0)
        self.assertEqual(saved["post_merge_fixes"], 0)  # Crucial: 0 preserved
        self.assertEqual(saved["elapsed_seconds"], 900.0)
        self.assertEqual(saved["cost_usd"], 0.35)
        self.assertEqual(saved["prompt_retries"], 2)  # Derived automatically from trace
        self.assertIn("annotated_at", saved)
        self.assertTrue(res["annotated"])

    def test_annotate_run_without_trace_leaves_retries_unknown(self):
        res = run_outcome.annotate_run(
            run_dir=self.run_no_trace_dir,
            human_minutes=5.0,
            merge_outcome="rejected",
        )
        self.assertIsNone(res["prompt_retries"])
        self.assertEqual(res["merge_outcome"], "rejected")

    def test_annotate_with_manual_prompt_retries_override(self):
        res = run_outcome.annotate_run(
            run_dir=self.run_no_trace_dir,
            prompt_retries=3,
        )
        self.assertEqual(res["prompt_retries"], 3)

    def test_partial_update_preserves_unmodified_fields(self):
        run_outcome.annotate_run(
            run_dir=self.run_retries_dir,
            merge_outcome="merged",
            human_minutes=12.0,
        )
        # Later update post_merge_fixes
        updated = run_outcome.annotate_run(
            run_dir=self.run_retries_dir,
            post_merge_fixes=1,
            notes="minor lint fix",
        )
        self.assertEqual(updated["merge_outcome"], "merged")
        self.assertEqual(updated["human_minutes"], 12.0)
        self.assertEqual(updated["post_merge_fixes"], 1)
        self.assertEqual(updated["notes"], "minor lint fix")

    def test_format_table_marks_absent_as_unknown(self):
        records = [
            run_outcome.read_run_data(self.run_retries_dir),
            run_outcome.read_run_data(self.run_zero_dir),
            run_outcome.read_run_data(self.run_no_trace_dir),
        ]
        table = run_outcome.format_table(records)

        lines = table.splitlines()
        self.assertIn("RUN ID", lines[0])
        self.assertIn("MERGE", lines[0])
        self.assertIn("RETRIES", lines[0])

        # Verify that run with retries has 2
        self.assertIn("2", lines[2])
        # Verify that run with zero retries has 0
        self.assertIn("0", lines[3])
        # Verify that run without trace has unknown for retries
        self.assertIn("unknown", lines[4])


class TestCLIExecution(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.runs_dir = Path(self.temp_dir.name)

        self.run_dir = self.runs_dir / "20260920T100000Z"
        self.run_dir.mkdir(parents=True)
        (self.run_dir / "run.json").write_text(
            json.dumps({"run_id": "20260920T100000Z"}),
            encoding="utf-8",
        )
        (self.run_dir / "trace.log").write_text(SAMPLE_TRACE_ZERO_RETRIES, encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_cmd(self, args: list[str]) -> subprocess.CompletedProcess:
        cmd = [sys.executable, str(PROJECT_ROOT / "scripts" / "run-outcome.py")] + args
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_cli_help(self):
        proc = self.run_cmd(["--help"])
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Annotate archived swarm runs", proc.stdout)

    def test_cli_report_table(self):
        proc = self.run_cmd(["report", "--runs-dir", str(self.runs_dir)])
        self.assertEqual(proc.returncode, 0)
        self.assertIn("20260920T100000Z", proc.stdout)
        self.assertIn("unknown", proc.stdout)

    def test_cli_report_json(self):
        proc = self.run_cmd(["report", "--runs-dir", str(self.runs_dir), "--json"])
        self.assertEqual(proc.returncode, 0)
        data = json.loads(proc.stdout)
        self.assertIsInstance(data, list)
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["run_id"], "20260920T100000Z")
        self.assertEqual(data[0]["prompt_retries"], 0)
        self.assertIsNone(data[0]["merge_outcome"])

    def test_cli_annotate_and_show(self):
        annotate_proc = self.run_cmd([
            "annotate",
            "20260920T100000Z",
            "--runs-dir", str(self.runs_dir),
            "--merge-outcome", "merged",
            "--human-minutes", "18.5",
            "--post-merge-fixes", "0",
            "--elapsed", "25m",
            "--cost", "$0.55",
            "--notes", "worked smoothly",
        ])
        self.assertEqual(annotate_proc.returncode, 0, msg=annotate_proc.stderr)

        show_proc = self.run_cmd([
            "show",
            "20260920T100000Z",
            "--runs-dir", str(self.runs_dir),
            "--json",
        ])
        self.assertEqual(show_proc.returncode, 0)
        record = json.loads(show_proc.stdout)
        self.assertTrue(record["annotated"])
        self.assertEqual(record["merge_outcome"], "merged")
        self.assertEqual(record["human_minutes"], 18.5)
        self.assertEqual(record["post_merge_fixes"], 0)
        self.assertEqual(record["elapsed_seconds"], 1500.0)
        self.assertEqual(record["cost_usd"], 0.55)
        self.assertEqual(record["prompt_retries"], 0)
        self.assertEqual(record["notes"], "worked smoothly")

    def test_cli_annotate_latest_and_env_var(self):
        cmd = [sys.executable, str(PROJECT_ROOT / "scripts" / "run-outcome.py"), "annotate", "latest", "-o", "merged"]
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env={"HERDR_SWARM_RUN_DIR": str(self.runs_dir), "PATH": os.environ.get("PATH", "")},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Annotated archive", proc.stdout)

    def test_cli_invalid_inputs_return_error(self):
        # Invalid duration
        proc1 = self.run_cmd(["annotate", "20260920T100000Z", "--runs-dir", str(self.runs_dir), "--elapsed", "not_a_duration"])
        self.assertNotEqual(proc1.returncode, 0)
        self.assertIn("ERROR:", proc1.stderr)

        # Invalid cost
        proc2 = self.run_cmd(["annotate", "20260920T100000Z", "--runs-dir", str(self.runs_dir), "--cost", "invalid_cost"])
        self.assertNotEqual(proc2.returncode, 0)
        self.assertIn("ERROR:", proc2.stderr)

        # Non-existent run
        proc3 = self.run_cmd(["show", "nonexistent-run", "--runs-dir", str(self.runs_dir)])
        self.assertNotEqual(proc3.returncode, 0)
        self.assertIn("ERROR:", proc3.stderr)


if __name__ == "__main__":
    unittest.main()
