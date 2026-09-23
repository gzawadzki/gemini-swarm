#!/usr/bin/env python3
"""Run outcome and rework measurement for herdr-swarm.

Annotates archived runs with human minutes, merge outcome, post-merge fixes,
elapsed time to correct solution, known cost, and prompt rework retries.
Reports metrics across archived runs.

Stdlib-only: no third-party dependencies.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Dict, List, Optional, Tuple, Union


def get_default_runs_dir() -> Path:
    env_dir = os.environ.get("HERDR_SWARM_RUN_DIR")
    if env_dir:
        return Path(env_dir).expanduser().resolve()
    return (Path.home() / ".herdr" / "runs").resolve()


def resolve_run_dir(target: str, runs_dir: Optional[Path] = None) -> Path:
    base_dir = runs_dir or get_default_runs_dir()
    if target in ("latest", "last"):
        if not base_dir.is_dir():
            raise FileNotFoundError(f"Runs directory does not exist: {base_dir}")
        candidates = sorted([d for d in base_dir.iterdir() if d.is_dir()], key=lambda d: d.name)
        if not candidates:
            raise FileNotFoundError(f"No run archives found in: {base_dir}")
        return candidates[-1]

    p = Path(target).expanduser()
    if p.is_file():
        return p.resolve().parent
    if p.is_dir():
        return p.resolve()

    cand = base_dir / target
    if cand.is_dir():
        return cand.resolve()
    raise FileNotFoundError(f"Run archive not found: {target}")


def parse_trace_events(trace_content: Optional[str]) -> Tuple[Optional[int], Optional[int]]:
    """Parses trace.log for prompt rework retries and delivery retries.

    Returns:
      (prompt_rework_retries, prompt_delivery_retries)

    Rule: trace.log records launcher delivery attempts (submit_prompt), not
    later task re-prompts after human review. A single initial prompt in trace
    cannot justify rework=0. prompt_rework_retries is None (unknown) unless a
    dedicated rework event is present in the trace.
    """
    if trace_content is None:
        return None, None

    lines = trace_content.splitlines()
    prompt_lines = [l for l in lines if "prompt." in l]
    if not prompt_lines:
        return None, None

    rework_events = 0
    has_explicit_rework = False
    delivery_retries = 0

    for line in prompt_lines:
        parts = line.strip().split(None, 4)
        if len(parts) < 4:
            continue
        event = parts[3]
        detail = parts[4] if len(parts) > 4 else ""

        if event in ("prompt.rework", "prompt.reprompt", "prompt.retry"):
            rework_events += 1
            has_explicit_rework = True

        m = re.search(r"attempt\s+(\d+)", detail, re.IGNORECASE)
        if m:
            attempt_num = int(m.group(1))
            if attempt_num > 1:
                delivery_retries += 1

    prompt_retries = rework_events if has_explicit_rework else None
    return prompt_retries, delivery_retries


def parse_duration(val: Union[str, int, float, None]) -> Optional[float]:
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    s = str(val).strip()
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None
    if s.endswith("s"):
        s = s[:-1]
    elif s.endswith("m") or s.endswith("min") or s.endswith("mins"):
        return float(s.rstrip("mins ")) * 60.0
    elif s.endswith("h"):
        return float(s[:-1]) * 3600.0
    try:
        return float(s)
    except ValueError:
        raise ValueError(f"Invalid duration: '{val}'")


def format_duration(seconds: Optional[Union[float, int]]) -> str:
    if seconds is None:
        return "unknown"
    sec = float(seconds)
    if sec < 60:
        return f"{int(sec)}s"
    m = int(sec // 60)
    s = int(sec % 60)
    return f"{m}m {s:02d}s" if s else f"{m}m"


def parse_cost(val: Union[str, int, float, None]) -> Optional[float]:
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    s = str(val).strip().lstrip("$")
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None
    try:
        return float(s)
    except ValueError:
        raise ValueError(f"Invalid cost: '{val}'")


def format_cost(cost: Optional[Union[float, int]]) -> str:
    return f"${float(cost):.2f}" if cost is not None else "unknown"


def parse_human_minutes(val: Union[str, int, float, None]) -> Optional[float]:
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    s = str(val).strip().rstrip("mins ")
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None
    try:
        return float(s)
    except ValueError:
        raise ValueError(f"Invalid human minutes: '{val}'")


def format_human_minutes(minutes: Optional[Union[float, int]]) -> str:
    if minutes is None:
        return "unknown"
    val = float(minutes)
    return f"{int(val)}m" if val.is_integer() else f"{val:.1f}m"


def parse_post_merge_fixes(val: Union[str, int, None]) -> Optional[Union[int, str]]:
    if val is None:
        return None
    if isinstance(val, int):
        return val
    s = str(val).strip()
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None
    try:
        return int(s)
    except ValueError:
        return s


def parse_int_field(val: Union[str, int, None]) -> Optional[int]:
    if val is None:
        return None
    if isinstance(val, int):
        return val
    s = str(val).strip()
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None
    return int(s)


def read_run_data(run_dir: Path) -> Dict[str, Any]:
    run_id = run_dir.name
    run_meta_path = run_dir / "run.json"
    if run_meta_path.is_file():
        try:
            with open(run_meta_path, "r", encoding="utf-8") as f:
                run_id = json.load(f).get("run_id") or run_id
        except Exception:
            pass

    outcome_path = run_dir / "outcome.json"
    outcome_data: Dict[str, Any] = {}
    is_annotated = False
    if outcome_path.is_file():
        try:
            with open(outcome_path, "r", encoding="utf-8") as f:
                outcome_data = json.load(f)
                is_annotated = True
                run_id = outcome_data.get("run_id") or run_id
        except Exception:
            pass

    trace_path = run_dir / "trace.log"
    trace_rework, trace_delivery = None, None
    if trace_path.is_file():
        try:
            tc = trace_path.read_text(encoding="utf-8", errors="replace")
            trace_rework, trace_delivery = parse_trace_events(tc)
        except Exception:
            pass

    annotated_retries = outcome_data.get("prompt_retries")
    if annotated_retries is not None:
        final_retries = parse_int_field(annotated_retries)
    else:
        final_retries = trace_rework

    return {
        "run_id": run_id,
        "archive_dir": str(run_dir.resolve()),
        "annotated": is_annotated,
        "merge_outcome": outcome_data.get("merge_outcome"),
        "human_minutes": outcome_data.get("human_minutes"),
        "post_merge_fixes": outcome_data.get("post_merge_fixes"),
        "elapsed_seconds": outcome_data.get("elapsed_seconds"),
        "cost_usd": outcome_data.get("cost_usd"),
        "prompt_retries": final_retries,
        "prompt_delivery_retries": trace_delivery,
        "notes": outcome_data.get("notes"),
        "annotated_at": outcome_data.get("annotated_at"),
    }


def annotate_run(
    run_dir: Path,
    human_minutes: Optional[float] = None,
    merge_outcome: Optional[str] = None,
    post_merge_fixes: Optional[Union[int, str]] = None,
    elapsed_seconds: Optional[float] = None,
    cost_usd: Optional[float] = None,
    prompt_retries: Optional[int] = None,
    notes: Optional[str] = None,
    overwrite: bool = False,
) -> Dict[str, Any]:
    existing = read_run_data(run_dir)
    outcome_path = run_dir / "outcome.json"

    if overwrite or not existing["annotated"]:
        record: Dict[str, Any] = {
            "run_id": existing["run_id"],
            "merge_outcome": None,
            "human_minutes": None,
            "post_merge_fixes": None,
            "elapsed_seconds": None,
            "cost_usd": None,
            "prompt_retries": None,
            "notes": None,
            "annotated_at": None,
        }
    else:
        record = {
            "run_id": existing["run_id"],
            "merge_outcome": existing["merge_outcome"],
            "human_minutes": existing["human_minutes"],
            "post_merge_fixes": existing["post_merge_fixes"],
            "elapsed_seconds": existing["elapsed_seconds"],
            "cost_usd": existing["cost_usd"],
            "prompt_retries": existing["prompt_retries"],
            "notes": existing["notes"],
            "annotated_at": existing["annotated_at"],
        }

    if merge_outcome is not None:
        record["merge_outcome"] = merge_outcome.strip() if merge_outcome else None
    if human_minutes is not None:
        record["human_minutes"] = human_minutes
    if post_merge_fixes is not None:
        record["post_merge_fixes"] = post_merge_fixes
    if elapsed_seconds is not None:
        record["elapsed_seconds"] = elapsed_seconds
    if cost_usd is not None:
        record["cost_usd"] = cost_usd
    if prompt_retries is not None:
        record["prompt_retries"] = prompt_retries
    if notes is not None:
        record["notes"] = notes.strip() if notes else None

    record["annotated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    tmp_path = run_dir / f"outcome.json.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    tmp_path.replace(outcome_path)

    return read_run_data(run_dir)


def format_table(records: List[Dict[str, Any]]) -> str:
    headers = ["RUN ID", "MERGE", "HUMAN MIN", "FIXES", "ELAPSED", "COST", "RETRIES", "ANNOTATED"]
    rows = []
    for r in records:
        rows.append([
            r["run_id"],
            r["merge_outcome"] or "unknown",
            format_human_minutes(r["human_minutes"]),
            str(r["post_merge_fixes"]) if r["post_merge_fixes"] is not None else "unknown",
            format_duration(r["elapsed_seconds"]),
            format_cost(r["cost_usd"]),
            str(r["prompt_retries"]) if r["prompt_retries"] is not None else "unknown",
            "yes" if r["annotated"] else "no",
        ])

    widths = [len(h) for h in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    header_fmt = "  ".join(f"%-{w}s" for w in widths)
    lines = [header_fmt % tuple(headers), "  ".join("-" * w for w in widths)]
    for row in rows:
        lines.append(header_fmt % tuple(row))
    return "\n".join(lines)


def format_single_run(r: Dict[str, Any]) -> str:
    lines = [
        f"Run Outcome: {r['run_id']}",
        f"  Archive dir:       {r['archive_dir']}",
        f"  Annotated:         {'yes' if r['annotated'] else 'no'}",
        f"  Merge outcome:     {r['merge_outcome'] or 'unknown'}",
        f"  Human minutes:     {format_human_minutes(r['human_minutes'])}",
        f"  Post-merge fixes:  {str(r['post_merge_fixes']) if r['post_merge_fixes'] is not None else 'unknown'}",
        f"  Elapsed time:      {format_duration(r['elapsed_seconds'])}",
        f"  Cost:              {format_cost(r['cost_usd'])}",
        f"  Prompt retries:    {str(r['prompt_retries']) if r['prompt_retries'] is not None else 'unknown'}",
        f"  Delivery retries:  {str(r['prompt_delivery_retries']) if r['prompt_delivery_retries'] is not None else 'unknown'}",
        f"  Notes:             {r['notes'] or 'unknown'}",
    ]
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--runs-dir", help="Path to archive runs directory")

    parser = argparse.ArgumentParser(prog="run-outcome", parents=[common])
    subparsers = parser.add_subparsers(dest="subcommand")

    annotate_parser = subparsers.add_parser("annotate", parents=[common])
    annotate_parser.add_argument("run", help="Run ID or archive path (or 'latest')")
    annotate_parser.add_argument("-m", "--human-minutes", help="Operator minutes spent")
    annotate_parser.add_argument("-o", "--merge-outcome", help="Outcome (merged, abandoned, rejected, etc.)")
    annotate_parser.add_argument("-f", "--post-merge-fixes", help="Post-merge fixes count or description")
    annotate_parser.add_argument("-e", "--elapsed", help="Elapsed time to correct solution (e.g. 25m, 1500s)")
    annotate_parser.add_argument("-c", "--cost", help="Known inference cost in USD")
    annotate_parser.add_argument("-r", "--prompt-retries", help="Prompt rework retries count")
    annotate_parser.add_argument("--notes", help="Notes or explanation")
    annotate_parser.add_argument("--overwrite", action="store_true", help="Overwrite existing outcome")
    annotate_parser.add_argument("--json", action="store_true", help="Output JSON")

    report_parser = subparsers.add_parser("report", parents=[common])
    report_parser.add_argument("run", nargs="?", help="Optional run ID to inspect")
    report_parser.add_argument("--json", action="store_true", help="Output JSON")

    show_parser = subparsers.add_parser("show", parents=[common])
    show_parser.add_argument("run", help="Run ID or path to inspect")
    show_parser.add_argument("--json", action="store_true", help="Output JSON")

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    runs_dir = Path(args.runs_dir).expanduser().resolve() if args.runs_dir else None

    if args.subcommand == "annotate":
        try:
            r_dir = resolve_run_dir(args.run, runs_dir)
            result = annotate_run(
                run_dir=r_dir,
                human_minutes=parse_human_minutes(args.human_minutes),
                merge_outcome=args.merge_outcome,
                post_merge_fixes=parse_post_merge_fixes(args.post_merge_fixes),
                elapsed_seconds=parse_duration(args.elapsed),
                cost_usd=parse_cost(args.cost),
                prompt_retries=parse_int_field(args.prompt_retries),
                notes=args.notes,
                overwrite=args.overwrite,
            )
            if args.json:
                print(json.dumps(result, indent=2))
            else:
                print(f"Annotated archive: {r_dir}")
                print(format_single_run(result))
            return 0
        except (FileNotFoundError, ValueError) as e:
            sys.stderr.write(f"ERROR: {e}\n")
            return 1

    elif args.subcommand in ("report", "show") or args.subcommand is None:
        target = getattr(args, "run", None)
        as_json = getattr(args, "json", False)
        base_dir = runs_dir or get_default_runs_dir()

        if target:
            try:
                r_dir = resolve_run_dir(target, base_dir)
                data = read_run_data(r_dir)
                print(json.dumps(data, indent=2) if as_json else format_single_run(data))
                return 0
            except FileNotFoundError as e:
                sys.stderr.write(f"ERROR: {e}\n")
                return 1

        if not base_dir.is_dir():
            print("[]" if as_json else f"No run archives found in {base_dir}")
            return 0

        run_dirs = sorted([d for d in base_dir.iterdir() if d.is_dir()], key=lambda d: d.name)
        records = [read_run_data(d) for d in run_dirs]
        if as_json:
            print(json.dumps(records, indent=2))
        else:
            print(format_table(records) if records else f"No run archives found in {base_dir}")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
