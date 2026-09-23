#!/usr/bin/env python3
"""jev-eval.py - Evaluation toolkit for Jev semantic critique decisions.

Prepares candidate JSONL records from run archives (leaving human labels blank),
and evaluates labeled records measuring coverage and false accepts on scored diffs
by named risk type and diff size bucket.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DIFF_BUCKETS = ["small (<=100)", "medium (101-400)", "large (401-600)", "oversized (>600)"]
STANDARD_RISKS = [
    "requirement_missing",
    "correctness_defect",
    "unrelated_change",
    "security_risk",
    "check_weakened",
    "regression_test_missing",
]


def parse_diff_stat(diff_text: str) -> Tuple[int, int, int]:
    """Return (additions, deletions, total_lines_changed)."""
    if not diff_text:
        return 0, 0, 0
    adds = dels = 0
    for line in diff_text.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            adds += 1
        elif line.startswith("-"):
            dels += 1
    return adds, dels, adds + dels


def get_diff_bucket(lines: int) -> str:
    """Classify line count into standard size buckets."""
    if lines <= 100:
        return "small (<=100)"
    if lines <= 400:
        return "medium (101-400)"
    if lines <= 600:
        return "large (401-600)"
    return "oversized (>600)"


def normalize_bucket(raw: Any, lines: int = 0) -> str:
    s = str(raw).lower() if raw else ""
    for name, tag in [("small", "<=100"), ("medium", "101-400"), ("large", "401-600"), ("oversized", ">600")]:
        if name in s or tag in s:
            return f"{name} ({tag})" if "(" not in name else name
    return get_diff_bucket(lines)


def find_run_directories(paths: List[str]) -> List[Path]:
    """Find directories containing state.json."""
    dirs: List[Path] = []
    for p_str in paths:
        p = Path(p_str).expanduser()
        if not p.exists():
            continue
        if p.is_file() and p.name == "state.json":
            dirs.append(p.parent)
        elif p.is_dir():
            if (p / "state.json").is_file():
                dirs.append(p)
            else:
                dirs.extend(sub for sub in sorted(p.iterdir()) if sub.is_dir() and (sub / "state.json").is_file())
    seen = set()
    return [d for d in dirs if not (d.resolve() in seen or seen.add(d.resolve()))]


def extract_jev_info(archive_dir: Path, name: str) -> Optional[Dict[str, Any]]:
    """Extract Jev signal vector and metadata; handles archives without Jev."""
    c_file = archive_dir / f"{name}.critique.json"
    r_file = archive_dir / f"{name}.critique.jev-response.json"
    attempted, route, model = False, "", ""
    risk_max: Optional[float] = None
    signals: Dict[str, float] = {}

    if c_file.is_file():
        try:
            with c_file.open("r", encoding="utf-8", errors="replace") as f:
                c_data = json.load(f)
            if isinstance(c_data, dict) and isinstance(c_data.get("jev"), dict):
                j = c_data["jev"]
                attempted, route, model = bool(j.get("attempted", False)), str(j.get("route", "") or ""), str(j.get("model", "") or "")
                if j.get("risk_max") is not None:
                    risk_max = float(j["risk_max"])
                if isinstance(j.get("signals"), dict):
                    signals = {str(k): float(v) for k, v in j["signals"].items() if v is not None}
        except Exception:
            pass

    if (not signals or risk_max is None) and r_file.is_file():
        try:
            with r_file.open("r", encoding="utf-8", errors="replace") as f:
                r_data = json.load(f)
            if isinstance(r_data, dict):
                model = model or str(r_data.get("model", "") or "")
                answers = r_data.get("answers", {})
                if isinstance(answers, dict):
                    extracted = {k: float(v["noul"]) for k, v in answers.items() if isinstance(v, dict) and "noul" in v}
                    if extracted:
                        signals, risk_max, attempted = extracted, max(extracted.values()), True
        except Exception:
            pass

    if not attempted and not signals and risk_max is None:
        return None
    if risk_max is None and signals:
        risk_max = max(signals.values())
    return {"attempted": attempted, "route": route, "model": model, "risk_max": risk_max, "signals": signals}


def prepare_candidate_records(archive_dirs: List[Path]) -> List[Dict[str, Any]]:
    """Scan archive dirs; candidate records leave human labels blank (None)."""
    records: List[Dict[str, Any]] = []
    for d in archive_dirs:
        state_file = d / "state.json"
        if not state_file.is_file():
            continue
        run_id = d.name
        run_meta = d / "run.json"
        if run_meta.is_file():
            try:
                with run_meta.open("r", encoding="utf-8", errors="replace") as f:
                    meta = json.load(f)
                if isinstance(meta, dict) and meta.get("run_id"):
                    run_id = str(meta["run_id"])
            except Exception:
                pass
        try:
            with state_file.open("r", encoding="utf-8", errors="replace") as f:
                tasks = json.load(f)
        except Exception:
            continue
        if not isinstance(tasks, list):
            continue

        for task in tasks:
            if not isinstance(task, dict):
                continue
            name = str(task.get("name", "unknown"))
            diff_file = d / f"{name}.diff"
            diff_text = ""
            if diff_file.is_file():
                try:
                    with diff_file.open("r", encoding="utf-8", errors="replace") as f:
                        diff_text = f.read()
                except Exception:
                    pass
            adds, dels, total = parse_diff_stat(diff_text)
            records.append({
                "id": f"{run_id}:{name}",
                "run_id": run_id,
                "task_name": name,
                "prompt": str(task.get("prompt", "")),
                "declared_files": task.get("files", []),
                "declared_pitfalls": task.get("pitfalls", []),
                "worker_model": str(task.get("model", "")),
                "diff_stat": f"+{adds}/-{dels}" if (adds or dels) else "",
                "diff_lines": total,
                "diff_size_bucket": get_diff_bucket(total),
                "diff": diff_text,
                "jev": extract_jev_info(d, name),
                "human_label": None,
            })
    return records


def evaluate_labeled_records(records: List[Dict[str, Any]], threshold: float) -> Dict[str, Any]:
    """Evaluate labeled records against threshold on Jev-scored records only."""
    missing_labels, unscored_labeled = 0, 0
    scored_items: List[Dict[str, Any]] = []

    for r in records:
        hl = r.get("human_label")
        if hl is None:
            missing_labels += 1
            continue

        is_labeled, acceptable, risks = False, False, []
        if isinstance(hl, bool):
            is_labeled, acceptable = True, hl
        elif isinstance(hl, dict) and isinstance(hl.get("acceptable"), bool):
            is_labeled, acceptable = True, hl["acceptable"]
            raw_r = hl.get("risks")
            if isinstance(raw_r, list):
                risks = [str(x) for x in raw_r]
            elif isinstance(raw_r, dict):
                risks = [str(k) for k, v in raw_r.items() if v]

        if not is_labeled:
            missing_labels += 1
            continue
        if not acceptable and not risks:
            risks = ["unspecified"]

        jev = r.get("jev")
        signals: Dict[str, float] = {}
        risk_max: Optional[float] = None
        if isinstance(jev, dict):
            if isinstance(jev.get("signals"), dict):
                signals = {str(k): float(v) for k, v in jev["signals"].items() if v is not None}
            if jev.get("risk_max") is not None:
                try:
                    risk_max = float(jev["risk_max"])
                except (ValueError, TypeError):
                    pass
            elif signals:
                risk_max = max(signals.values())

        if risk_max is None:
            unscored_labeled += 1
            continue

        scored_items.append({
            "record": r, "acceptable": acceptable, "risks": risks,
            "risk_max": risk_max, "signals": signals,
        })

    scored_n = len(scored_items)
    acc_n = sum(1 for x in scored_items if x["acceptable"])
    def_n = scored_n - acc_n
    auto_accept_n, false_accept_n, true_accept_n, correct_esc_n, false_esc_n = 0, 0, 0, 0, 0

    all_risks = set(STANDARD_RISKS)
    for x in scored_items:
        all_risks.update(x["risks"])

    risk_stats = {
        rt: {"human_flagged": 0, "false_accepts": 0, "signal_under_threshold": 0, "false_accept_rate": 0.0}
        for rt in sorted(all_risks)
    }
    bucket_stats = {
        b: {"scored": 0, "acceptable": 0, "defective": 0, "auto_accepted": 0, "coverage_rate": 0.0, "false_accepts": 0, "false_accept_rate": 0.0}
        for b in DIFF_BUCKETS
    }

    for x in scored_items:
        acc = x["acceptable"]
        bucket = normalize_bucket(x["record"].get("diff_size_bucket"), x["record"].get("diff_lines", 0))
        if bucket not in bucket_stats:
            bucket_stats[bucket] = {"scored": 0, "acceptable": 0, "defective": 0, "auto_accepted": 0, "coverage_rate": 0.0, "false_accepts": 0, "false_accept_rate": 0.0}
        bucket_stats[bucket]["scored"] += 1
        if acc:
            bucket_stats[bucket]["acceptable"] += 1
        else:
            bucket_stats[bucket]["defective"] += 1

        jev_auto = (x["risk_max"] <= threshold)
        if jev_auto:
            auto_accept_n += 1
            bucket_stats[bucket]["auto_accepted"] += 1
            if acc:
                true_accept_n += 1
            else:
                false_accept_n += 1
                bucket_stats[bucket]["false_accepts"] += 1
        else:
            if acc:
                false_esc_n += 1
            else:
                correct_esc_n += 1

        for rt in x["risks"]:
            st = risk_stats[rt]
            st["human_flagged"] += 1
            if jev_auto:
                st["false_accepts"] += 1
            if x["signals"].get(rt, 1.0) <= threshold:
                st["signal_under_threshold"] += 1

    for st in risk_stats.values():
        if st["human_flagged"] > 0:
            st["false_accept_rate"] = round(st["false_accepts"] / st["human_flagged"], 4)
    for b_data in bucket_stats.values():
        if b_data["scored"] > 0:
            b_data["coverage_rate"] = round(b_data["auto_accepted"] / b_data["scored"], 4)
        if b_data["auto_accepted"] > 0:
            b_data["false_accept_rate"] = round(b_data["false_accepts"] / b_data["auto_accepted"], 4)

    return {
        "threshold": threshold,
        "threshold_calibrated": False,
        "threshold_status": "uncalibrated_policy_default",
        "dataset": {
            "total_records": len(records),
            "missing_labels_excluded": missing_labels,
            "total_labeled": scored_n + unscored_labeled,
            "unscored_labeled_excluded": unscored_labeled,
            "scored_denominator": scored_n,
            "human_acceptable": acc_n,
            "human_defective": def_n,
        },
        "overall": {
            "scored_denominator": scored_n,
            "auto_accepted": auto_accept_n,
            "coverage_rate": round(auto_accept_n / scored_n, 4) if scored_n else 0.0,
            "false_accepts": false_accept_n,
            "false_accept_rate_of_accepted": round(false_accept_n / auto_accept_n, 4) if auto_accept_n else 0.0,
            "false_accept_rate_of_defective": round(false_accept_n / def_n, 4) if def_n else 0.0,
            "true_accepts": true_accept_n,
            "correct_escalations": correct_esc_n,
            "false_escalations": false_esc_n,
        },
        "by_risk_type": risk_stats,
        "by_diff_size_bucket": bucket_stats,
    }


def format_report_text(res: Dict[str, Any]) -> str:
    """Format report text; threshold 0.10 is never described as calibrated."""
    t, ds, ov, scored_n = res["threshold"], res["dataset"], res["overall"], res["dataset"]["scored_denominator"]
    lines = [
        "=" * 80,
        "                    JEV EVALUATION REPORT (SHADOW MODE EVAL)",
        "=" * 80,
        f"Threshold: {t:.2f} [UNCALIBRATED POLICY DEFAULT]",
        f"Notice: HERDR_SWARM_JEV_ACCEPT_MAX={t:.2f} is an uncalibrated policy default,",
        "  not an empirically calibrated threshold on swarm data.",
        "  It must not be assumed safe or production-ready without eval verification.",
        "-" * 80,
        "DATASET OVERVIEW (DISTINGUISHING LABELS FROM ACCEPTABLE EXAMPLES)",
        f"  Total records in input:        {ds['total_records']}",
        f"  Missing human labels:          {ds['missing_labels_excluded']}  [EXCLUDED: missing label != acceptable]",
        f"  Explicitly labeled records:    {ds['total_labeled']}",
        f"    - Scored by Jev (EVALUATED): {scored_n}  [DENOMINATOR for coverage & false accepts]",
        f"        Human acceptable (clean):{ds['human_acceptable']}  ({ds['human_acceptable'] / scored_n * 100:.1f}%)" if scored_n else "",
        f"        Human defective (risks): {ds['human_defective']}  ({ds['human_defective'] / scored_n * 100:.1f}%)" if scored_n else "",
        f"    - Unscored by Jev:           {ds['unscored_labeled_excluded']}  [EXCLUDED: labeled archive with no Jev signals]",
    ]
    lines = [line for line in lines if line]
    if not scored_n:
        return "\n".join(lines + ["  (No scored records available)", "=" * 80])

    lines.extend([
        "-" * 80,
        f"OVERALL METRICS (threshold = {t:.2f}, denominator = {scored_n} scored records)",
        f"  Coverage (auto-accepted):      {ov['auto_accepted']} / {scored_n}  ({ov['coverage_rate'] * 100:.1f}%)",
        f"  False accepts:                 {ov['false_accepts']}  ({ov['false_accept_rate_of_accepted'] * 100:.1f}% of auto-accepted)",
        f"  True accepts:                  {ov['true_accepts']} / {scored_n}  ({ov['true_accepts'] / scored_n * 100:.1f}%)",
        f"  Correct escalations:           {ov['correct_escalations']} / {scored_n}  ({ov['correct_escalations'] / scored_n * 100:.1f}%)",
        f"  False escalations:             {ov['false_escalations']} / {scored_n}  ({ov['false_escalations'] / scored_n * 100:.1f}%)",
        "-" * 80,
        "FALSE ACCEPTS BY NAMED RISK TYPE",
        "  Risk Type                Flagged by Human  False Accepts  FA Rate  Signal <= T",
        "  -----------------------  ----------------  -------------  -------  -----------",
    ])
    for rt, st in sorted(res["by_risk_type"].items()):
        if rt in STANDARD_RISKS or st["human_flagged"] > 0:
            lines.append(f"  {rt:<23}  {st['human_flagged']:>16}  {st['false_accepts']:>13}  {st['false_accept_rate'] * 100:>6.1f}%  {st['signal_under_threshold']:>11}")

    lines.extend([
        "-" * 80,
        "FALSE ACCEPTS AND COVERAGE BY DIFF SIZE BUCKET",
        "  Diff Size Bucket  Scored   Acceptable  Defective  Auto-Accepted (Coverage)  False Accepts",
        "  ----------------  -------  ----------  ---------  ------------------------  -------------",
    ])
    for b in DIFF_BUCKETS:
        bd = res["by_diff_size_bucket"].get(b, {})
        sc, aac, cov = bd.get("scored", 0), bd.get("auto_accepted", 0), bd.get("coverage_rate", 0.0) * 100
        fa, far = bd.get("false_accepts", 0), bd.get("false_accept_rate", 0.0) * 100
        lines.append(f"  {b:<16}  {sc:>7}  {bd.get('acceptable', 0):>10}  {bd.get('defective', 0):>9}  {aac:>10} / {sc:<3} ({cov:>5.1f}%)  {fa:>5} ({far:>5.1f}%)")
    lines.append("=" * 80)
    return "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(description="Jev semantic decision evaluation toolkit.")
    sub = p.add_subparsers(dest="command", required=True)

    prep = sub.add_parser("prepare", help="Extract candidate records from run archives.")
    prep.add_argument("archives", nargs="*", default=[], help="Path(s) to run archives.")
    prep.add_argument("-o", "--output", default="", help="Output JSONL path (default: stdout).")

    rep = sub.add_parser("report", help="Evaluate labeled records at supplied threshold.")
    rep.add_argument("-i", "--input", required=True, help="Input JSONL path (or - for stdin).")
    rep.add_argument("-t", "--threshold", type=float, default=0.10, help="Supplied threshold (default: 0.10).")
    rep.add_argument("-f", "--format", choices=["text", "json"], default="text", help="Format (default: text).")
    rep.add_argument("-o", "--output", default="", help="Output path (default: stdout).")

    args = p.parse_args()
    if args.command == "prepare":
        paths = args.archives or [os.environ.get("HERDR_SWARM_RUN_DIR", ""), os.path.expanduser("~/.herdr/runs"), ".herdr-swarm"]
        dirs = find_run_directories([p for p in paths if p])
        if not dirs:
            sys.stderr.write("jev-eval: no run archives containing state.json were found.\n")
            sys.exit(1)
        records = prepare_candidate_records(dirs)
        out_f = open(args.output, "w", encoding="utf-8") if args.output else sys.stdout
        try:
            for r in records:
                out_f.write(json.dumps(r) + "\n")
        finally:
            if args.output:
                out_f.close()

    elif args.command == "report":
        if not (0.0 <= args.threshold <= 1.0):
            sys.stderr.write("jev-eval: threshold must be between 0.0 and 1.0.\n")
            sys.exit(1)
        records = []
        if args.input == "-":
            records = [json.loads(line) for line in sys.stdin if line.strip()]
        else:
            with open(Path(args.input).expanduser(), "r", encoding="utf-8", errors="replace") as f:
                records = [json.loads(line) for line in f if line.strip()]

        res = evaluate_labeled_records(records, args.threshold)
        out_str = (json.dumps(res, indent=2) if args.format == "json" else format_report_text(res)) + "\n"
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(out_str)
        else:
            sys.stdout.write(out_str)


if __name__ == "__main__":
    main()
