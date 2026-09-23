#!/usr/bin/env python3
"""jev-eval.py - Evaluation tooling for Jev semantic critique decisions.

Prepares candidate JSONL records from existing swarm run archives leaving
human labels blank, and generates evaluation reports for supplied thresholds
measuring coverage and false accepts broken down by named risk type and diff
size bucket.

Stdlib only. Never infers human labels from Jev or generative critique.
Never describes the 0.10 threshold as calibrated.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DIFF_SIZE_BUCKETS = [
    "small (<=100)",
    "medium (101-400)",
    "large (401-600)",
    "oversized (>600)",
]

STANDARD_RISK_TYPES = [
    "requirement_missing",
    "correctness_defect",
    "unrelated_change",
    "security_risk",
    "check_weakened",
    "regression_test_missing",
]


def parse_diff_stat(diff_text: str) -> Tuple[int, int, int]:
    """Parse unified diff text into (additions, deletions, total_lines_changed)."""
    if not diff_text:
        return 0, 0, 0
    additions = 0
    deletions = 0
    for line in diff_text.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            additions += 1
        elif line.startswith("-"):
            deletions += 1
    return additions, deletions, additions + deletions


def get_diff_size_bucket(lines: int) -> str:
    """Classify diff line count into standard swarm size buckets."""
    if lines <= 100:
        return "small (<=100)"
    elif lines <= 400:
        return "medium (101-400)"
    elif lines <= 600:
        return "large (401-600)"
    else:
        return "oversized (>600)"


def normalize_bucket(bucket_val: Any, diff_lines: Optional[int] = None) -> str:
    """Normalize bucket representation to one of standard diff size buckets."""
    if isinstance(bucket_val, str) and bucket_val:
        b_lower = bucket_val.lower()
        if "small" in b_lower or "<=100" in b_lower:
            return "small (<=100)"
        if "medium" in b_lower or "101-400" in b_lower:
            return "medium (101-400)"
        if "large" in b_lower or "401-600" in b_lower:
            return "large (401-600)"
        if "oversize" in b_lower or ">600" in b_lower:
            return "oversized (>600)"
    if diff_lines is not None:
        return get_diff_size_bucket(diff_lines)
    return "small (<=100)"


def find_run_directories(paths: List[str]) -> List[Path]:
    """Find run archive directories containing state.json."""
    run_dirs: List[Path] = []
    for p_str in paths:
        p = Path(p_str).expanduser()
        if not p.exists():
            continue
        if p.is_file() and p.name == "state.json":
            run_dirs.append(p.parent)
        elif p.is_dir():
            if (p / "state.json").is_file():
                run_dirs.append(p)
            else:
                for sub in sorted(p.iterdir()):
                    if sub.is_dir() and (sub / "state.json").is_file():
                        run_dirs.append(sub)
    # Deduplicate while preserving order
    seen = set()
    unique: List[Path] = []
    for d in run_dirs:
        resolved = d.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(d)
    return unique


def extract_jev_info(
    archive_dir: Path, task_name: str
) -> Optional[Dict[str, Any]]:
    """Extract Jev signal vector and metadata from critique files.

    Handles prior archives that may not contain Jev signals.
    Never relies only on risk_max: records the full specific signal vector.
    """
    critique_file = archive_dir / f"{task_name}.critique.json"
    jev_response_file = archive_dir / f"{task_name}.critique.jev-response.json"

    attempted = False
    route = ""
    model = ""
    risk_max: Optional[float] = None
    signals: Dict[str, float] = {}

    if critique_file.is_file():
        try:
            with critique_file.open("r", encoding="utf-8", errors="replace") as f:
                c_data = json.load(f)
            if isinstance(c_data, dict) and "jev" in c_data and isinstance(c_data["jev"], dict):
                j_obj = c_data["jev"]
                attempted = bool(j_obj.get("attempted", False))
                route = str(j_obj.get("route", "") or "")
                model = str(j_obj.get("model", "") or "")
                raw_max = j_obj.get("risk_max")
                if raw_max is not None:
                    try:
                        risk_max = float(raw_max)
                    except (ValueError, TypeError):
                        pass
                raw_signals = j_obj.get("signals")
                if isinstance(raw_signals, dict):
                    for k, v in raw_signals.items():
                        try:
                            signals[str(k)] = float(v)
                        except (ValueError, TypeError):
                            pass
        except Exception:
            pass

    if (not signals or risk_max is None) and jev_response_file.is_file():
        try:
            with jev_response_file.open("r", encoding="utf-8", errors="replace") as f:
                r_data = json.load(f)
            if isinstance(r_data, dict):
                model = model or str(r_data.get("model", "") or "")
                answers = r_data.get("answers")
                if isinstance(answers, dict):
                    for k, v in answers.items():
                        if isinstance(v, dict) and "noul" in v:
                            try:
                                signals[str(k)] = float(v["noul"])
                            except (ValueError, TypeError):
                                pass
                    if signals:
                        attempted = True
                        if risk_max is None:
                            risk_max = max(signals.values())
        except Exception:
            pass

    if not attempted and not signals and risk_max is None:
        return None

    if risk_max is None and signals:
        risk_max = max(signals.values())

    return {
        "attempted": attempted,
        "route": route,
        "model": model,
        "risk_max": risk_max,
        "signals": signals,
    }


def prepare_candidate_records(
    archive_dirs: List[Path],
) -> List[Dict[str, Any]]:
    """Scan archive directories and prepare candidate JSONL records.

    Leaves human labels explicitly blank (None).
    Never infers human labels from Jev or critique verdicts.
    """
    records: List[Dict[str, Any]] = []

    for d in archive_dirs:
        state_file = d / "state.json"
        if not state_file.is_file():
            continue

        run_id = d.name
        run_meta_file = d / "run.json"
        if run_meta_file.is_file():
            try:
                with run_meta_file.open("r", encoding="utf-8", errors="replace") as f:
                    meta = json.load(f)
                if isinstance(meta, dict) and meta.get("run_id"):
                    run_id = str(meta["run_id"])
            except Exception:
                pass

        try:
            with state_file.open("r", encoding="utf-8", errors="replace") as f:
                state_data = json.load(f)
        except Exception:
            continue

        if not isinstance(state_data, list):
            continue

        for task in state_data:
            if not isinstance(task, dict):
                continue
            name = str(task.get("name", "unknown"))
            prompt = str(task.get("prompt", ""))
            files = task.get("files", [])
            pitfalls = task.get("pitfalls", [])
            worker_model = str(task.get("model", ""))

            # Read diff
            diff_file = d / f"{name}.diff"
            diff_text = ""
            if diff_file.is_file():
                try:
                    with diff_file.open("r", encoding="utf-8", errors="replace") as f:
                        diff_text = f.read()
                except Exception:
                    pass

            adds, dels, total_lines = parse_diff_stat(diff_text)
            diff_stat = f"+{adds}/-{dels}" if (adds > 0 or dels > 0) else ""
            bucket = get_diff_size_bucket(total_lines)

            # Jev signals
            jev_info = extract_jev_info(d, name)

            record = {
                "id": f"{run_id}:{name}",
                "run_id": run_id,
                "task_name": name,
                "prompt": prompt,
                "declared_files": files,
                "declared_pitfalls": pitfalls,
                "worker_model": worker_model,
                "diff_stat": diff_stat,
                "diff_lines": total_lines,
                "diff_size_bucket": bucket,
                "diff": diff_text,
                "jev": jev_info,
                # Human label is deliberately left blank.
                # Must never be inferred from Jev or critique verdict.
                "human_label": None,
            }
            records.append(record)

    return records


def evaluate_labeled_records(
    records: List[Dict[str, Any]], threshold: float
) -> Dict[str, Any]:
    """Evaluate labeled records against a supplied threshold.

    Excludes records with missing human labels.
    Calculates coverage and false accepts overall, by named risk, and by diff size bucket.
    """
    total_records = len(records)
    missing_labels_count = 0
    labeled_records: List[Dict[str, Any]] = []

    for r in records:
        hl = r.get("human_label")
        if hl is None:
            missing_labels_count += 1
            continue

        # Valid explicit human label check
        is_labeled = False
        acceptable = False
        risks: List[str] = []

        if isinstance(hl, bool):
            is_labeled = True
            acceptable = hl
        elif isinstance(hl, dict):
            acc_val = hl.get("acceptable")
            if isinstance(acc_val, bool):
                is_labeled = True
                acceptable = acc_val
                raw_risks = hl.get("risks")
                if isinstance(raw_risks, list):
                    risks = [str(item) for item in raw_risks]
                elif isinstance(raw_risks, dict):
                    risks = [str(k) for k, v in raw_risks.items() if v]

        if not is_labeled:
            missing_labels_count += 1
            continue

        if not acceptable and not risks:
            risks = ["unspecified"]

        labeled_records.append({
            "record": r,
            "acceptable": acceptable,
            "risks": risks,
        })

    labeled_count = len(labeled_records)
    acceptable_count = sum(1 for item in labeled_records if item["acceptable"])
    defective_count = labeled_count - acceptable_count

    auto_accepted_count = 0
    false_accept_count = 0
    true_accept_count = 0
    correct_escalation_count = 0
    false_escalation_count = 0

    # Risk tracking
    all_risk_types = set(STANDARD_RISK_TYPES)
    for item in labeled_records:
        all_risk_types.update(item["risks"])

    risk_stats: Dict[str, Dict[str, Any]] = {
        rt: {
            "human_flagged": 0,
            "false_accepts": 0,
            "signal_under_threshold": 0,
            "false_accept_rate": 0.0,
        }
        for rt in sorted(all_risk_types)
    }

    # Bucket tracking
    bucket_stats: Dict[str, Dict[str, Any]] = {
        b: {
            "labeled": 0,
            "acceptable": 0,
            "defective": 0,
            "auto_accepted": 0,
            "coverage_rate": 0.0,
            "false_accepts": 0,
            "false_accept_rate": 0.0,
        }
        for b in DIFF_SIZE_BUCKETS
    }

    for item in labeled_records:
        r = item["record"]
        acceptable = item["acceptable"]
        item_risks = item["risks"]

        bucket = normalize_bucket(r.get("diff_size_bucket"), r.get("diff_lines", 0))
        if bucket not in bucket_stats:
            bucket_stats[bucket] = {
                "labeled": 0,
                "acceptable": 0,
                "defective": 0,
                "auto_accepted": 0,
                "coverage_rate": 0.0,
                "false_accepts": 0,
                "false_accept_rate": 0.0,
            }

        bucket_stats[bucket]["labeled"] += 1
        if acceptable:
            bucket_stats[bucket]["acceptable"] += 1
        else:
            bucket_stats[bucket]["defective"] += 1

        # Evaluate Jev decision
        jev = r.get("jev")
        jev_signals: Dict[str, float] = {}
        risk_max: Optional[float] = None

        if isinstance(jev, dict):
            raw_signals = jev.get("signals")
            if isinstance(raw_signals, dict):
                for k, v in raw_signals.items():
                    try:
                        jev_signals[str(k)] = float(v)
                    except (ValueError, TypeError):
                        pass
            raw_max = jev.get("risk_max")
            if raw_max is not None:
                try:
                    risk_max = float(raw_max)
                except (ValueError, TypeError):
                    pass
            elif jev_signals:
                risk_max = max(jev_signals.values())

        jev_auto_accept = (risk_max is not None and risk_max <= threshold)

        if jev_auto_accept:
            auto_accepted_count += 1
            bucket_stats[bucket]["auto_accepted"] += 1
            if acceptable:
                true_accept_count += 1
            else:
                false_accept_count += 1
                bucket_stats[bucket]["false_accepts"] += 1
        else:
            if acceptable:
                false_escalation_count += 1
            else:
                correct_escalation_count += 1

        # Track risks
        for rt in item_risks:
            if rt not in risk_stats:
                risk_stats[rt] = {
                    "human_flagged": 0,
                    "false_accepts": 0,
                    "signal_under_threshold": 0,
                    "false_accept_rate": 0.0,
                }
            risk_stats[rt]["human_flagged"] += 1
            if jev_auto_accept:
                risk_stats[rt]["false_accepts"] += 1
            sig_val = jev_signals.get(rt)
            if sig_val is not None and sig_val <= threshold:
                risk_stats[rt]["signal_under_threshold"] += 1

    # Calculate rates
    for rt, stats in risk_stats.items():
        if stats["human_flagged"] > 0:
            stats["false_accept_rate"] = round(
                stats["false_accepts"] / stats["human_flagged"], 4
            )

    for b, b_data in bucket_stats.items():
        if b_data["labeled"] > 0:
            b_data["coverage_rate"] = round(
                b_data["auto_accepted"] / b_data["labeled"], 4
            )
        if b_data["auto_accepted"] > 0:
            b_data["false_accept_rate"] = round(
                b_data["false_accepts"] / b_data["auto_accepted"], 4
            )

    coverage_rate = (
        round(auto_accepted_count / labeled_count, 4) if labeled_count > 0 else 0.0
    )
    false_accept_rate_accepted = (
        round(false_accept_count / auto_accepted_count, 4)
        if auto_accepted_count > 0
        else 0.0
    )
    false_accept_rate_defective = (
        round(false_accept_count / defective_count, 4)
        if defective_count > 0
        else 0.0
    )

    return {
        "threshold": threshold,
        "threshold_calibrated": False,
        "threshold_status": "uncalibrated_policy_default",
        "dataset": {
            "total_records": total_records,
            "missing_labels_excluded": missing_labels_count,
            "labeled_evaluated": labeled_count,
            "human_acceptable": acceptable_count,
            "human_defective": defective_count,
        },
        "overall": {
            "auto_accepted": auto_accepted_count,
            "coverage_rate": coverage_rate,
            "false_accepts": false_accept_count,
            "false_accept_rate_of_accepted": false_accept_rate_accepted,
            "false_accept_rate_of_defective": false_accept_rate_defective,
            "true_accepts": true_accept_count,
            "correct_escalations": correct_escalation_count,
            "false_escalations": false_escalation_count,
        },
        "by_risk_type": risk_stats,
        "by_diff_size_bucket": bucket_stats,
    }


def format_report_text(result: Dict[str, Any]) -> str:
    """Format evaluation results into a human-readable text report.

    Never describes the 0.10 threshold as calibrated.
    Clearly distinguishes missing labels from acceptable examples.
    """
    t = result["threshold"]
    ds = result["dataset"]
    ov = result["overall"]
    risks = result["by_risk_type"]
    buckets = result["by_diff_size_bucket"]

    lines = [
        "=" * 80,
        "                    JEV EVALUATION REPORT (SHADOW MODE EVAL)",
        "=" * 80,
        f"Threshold: {t:.2f} [UNCALIBRATED POLICY DEFAULT]",
        "Notice:",
        f"  HERDR_SWARM_JEV_ACCEPT_MAX={t:.2f} is an uncalibrated policy default,",
        "  not an empirically calibrated threshold on swarm data.",
        "  It must not be assumed safe or production-ready without eval verification.",
        "-" * 80,
        "DATASET OVERVIEW (DISTINGUISHING LABELS FROM ACCEPTABLE EXAMPLES)",
        f"  Total records in input:        {ds['total_records']}",
        f"  Missing human labels:          {ds['missing_labels_excluded']}  [EXCLUDED: missing label != acceptable]",
        f"  Explicitly labeled records:    {ds['labeled_evaluated']}  [EVALUATED]",
    ]

    labeled_n = ds["labeled_evaluated"]
    if labeled_n > 0:
        acc_pct = ds["human_acceptable"] / labeled_n * 100
        def_pct = ds["human_defective"] / labeled_n * 100
        lines.append(f"    - Human acceptable (clean):  {ds['human_acceptable']}  ({acc_pct:.1f}%)")
        lines.append(f"    - Human defective (risks):   {ds['human_defective']}  ({def_pct:.1f}%)")
    else:
        lines.append("    (No labeled records found; skipping metric breakdown)")
        lines.append("=" * 80)
        return "\n".join(lines)

    lines.extend([
        "-" * 80,
        f"OVERALL METRICS (threshold = {t:.2f})",
        f"  Coverage (auto-accepted):      {ov['auto_accepted']} / {labeled_n}  ({ov['coverage_rate'] * 100:.1f}%)",
        f"  False accepts:                 {ov['false_accepts']}  ({ov['false_accept_rate_of_accepted'] * 100:.1f}% of auto-accepted)",
        f"  True accepts (safe):           {ov['true_accepts']} / {labeled_n}  ({ov['true_accepts'] / labeled_n * 100:.1f}%)",
        f"  Correct escalations (caught):  {ov['correct_escalations']} / {labeled_n}  ({ov['correct_escalations'] / labeled_n * 100:.1f}%)",
        f"  False escalations (cautious):  {ov['false_escalations']} / {labeled_n}  ({ov['false_escalations'] / labeled_n * 100:.1f}%)",
        "-" * 80,
        "FALSE ACCEPTS BY NAMED RISK TYPE",
        "  Risk Type                Flagged by Human  False Accepts  FA Rate  Signal <= T",
        "  -----------------------  ----------------  -------------  -------  -----------",
    ])

    for r_name, r_data in sorted(risks.items()):
        # Show all standard risks or any risk with human_flagged > 0
        if r_name in STANDARD_RISK_TYPES or r_data["human_flagged"] > 0:
            lines.append(
                f"  {r_name:<23}  {r_data['human_flagged']:>16}  "
                f"{r_data['false_accepts']:>13}  "
                f"{r_data['false_accept_rate'] * 100:>6.1f}%  "
                f"{r_data['signal_under_threshold']:>11}"
            )

    lines.extend([
        "-" * 80,
        "FALSE ACCEPTS AND COVERAGE BY DIFF SIZE BUCKET",
        "  Diff Size Bucket  Labeled  Acceptable  Defective  Auto-Accepted (Coverage)  False Accepts",
        "  ----------------  -------  ----------  ---------  ------------------------  -------------",
    ])

    for b_name in DIFF_SIZE_BUCKETS:
        b_data = buckets.get(b_name, {})
        lab = b_data.get("labeled", 0)
        acc = b_data.get("acceptable", 0)
        dfc = b_data.get("defective", 0)
        aac = b_data.get("auto_accepted", 0)
        cov = b_data.get("coverage_rate", 0.0) * 100
        fa = b_data.get("false_accepts", 0)
        far = b_data.get("false_accept_rate", 0.0) * 100
        lines.append(
            f"  {b_name:<16}  {lab:>7}  {acc:>10}  {dfc:>9}  "
            f"{aac:>10} / {lab:<3} ({cov:>5.1f}%)  "
            f"{fa:>5} ({far:>5.1f}%)"
        )

    lines.append("=" * 80)
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev semantic decision evaluation toolkit."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # prepare subcommand
    prep_parser = subparsers.add_parser(
        "prepare",
        help="Extract candidate JSONL records from run archives (leaving human labels blank).",
    )
    prep_parser.add_argument(
        "archives",
        nargs="*",
        default=[],
        help="Path(s) to run archives or directory containing run archives (default: ~/.herdr/runs or .herdr-swarm).",
    )
    prep_parser.add_argument(
        "-o",
        "--output",
        default="",
        help="Output JSONL file path (default: stdout).",
    )

    # report subcommand
    rep_parser = subparsers.add_parser(
        "report",
        help="Evaluate labeled JSONL records at a supplied threshold.",
    )
    rep_parser.add_argument(
        "-i",
        "--input",
        required=True,
        help="Path to labeled JSONL file (or - for stdin).",
    )
    rep_parser.add_argument(
        "-t",
        "--threshold",
        type=float,
        default=0.10,
        help="Supplied Jev auto-accept threshold (default: 0.10).",
    )
    rep_parser.add_argument(
        "-f",
        "--format",
        choices=["text", "json"],
        default="text",
        help="Output format: text table or json (default: text).",
    )
    rep_parser.add_argument(
        "-o",
        "--output",
        default="",
        help="Output file path (default: stdout).",
    )

    args = parser.parse_args()

    if args.command == "prepare":
        search_paths = args.archives
        if not search_paths:
            env_run_dir = os.environ.get("HERDR_SWARM_RUN_DIR")
            if env_run_dir:
                search_paths.append(env_run_dir)
            search_paths.append(os.path.expanduser("~/.herdr/runs"))
            search_paths.append(".herdr-swarm")

        archive_dirs = find_run_directories(search_paths)
        if not archive_dirs:
            sys.stderr.write("jev-eval: no run archives containing state.json were found.\n")
            sys.exit(1)

        records = prepare_candidate_records(archive_dirs)
        out_f = open(args.output, "w", encoding="utf-8") if args.output else sys.stdout
        try:
            for r in records:
                out_f.write(json.dumps(r) + "\n")
        finally:
            if args.output:
                out_f.close()

    elif args.command == "report":
        if args.threshold < 0.0 or args.threshold > 1.0:
            sys.stderr.write("jev-eval: threshold must be between 0.0 and 1.0.\n")
            sys.exit(1)

        records: List[Dict[str, Any]] = []
        if args.input == "-":
            for line in sys.stdin:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        else:
            in_path = Path(args.input).expanduser()
            if not in_path.is_file():
                sys.stderr.write(f"jev-eval: file not found: {args.input}\n")
                sys.exit(1)
            with in_path.open("r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            records.append(json.loads(line))
                        except json.JSONDecodeError:
                            pass

        result = evaluate_labeled_records(records, args.threshold)

        if args.format == "json":
            out_str = json.dumps(result, indent=2) + "\n"
        else:
            out_str = format_report_text(result) + "\n"

        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(out_str)
        else:
            sys.stdout.write(out_str)


if __name__ == "__main__":
    main()
