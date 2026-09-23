#!/usr/bin/env python3
"""Run outcome and rework measurement for herdr-swarm.

Annotates archived runs with human time, merge outcome, post-merge fixes,
elapsed time to correct solution, known cost, and derived prompt retries.
Reports these metrics across archived runs.

Stdlib-only: uses no external Python dependencies.
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
    """Returns the runs archive directory, respecting HERDR_SWARM_RUN_DIR."""
    env_dir = os.environ.get("HERDR_SWARM_RUN_DIR")
    if env_dir:
        return Path(env_dir).expanduser().resolve()
    return (Path.home() / ".herdr" / "runs").resolve()


def resolve_run_dir(target: str, runs_dir: Optional[Path] = None) -> Path:
    """Resolves a run target into an archive directory path.

    The target can be:
      - 'latest' or 'last': the most recent run in runs_dir
      - a run ID like '20260919T161853Z'
      - a relative or absolute path to a run archive directory
      - a path to a file inside the archive (e.g. run.json, outcome.json)
    """
    base_dir = runs_dir or get_default_runs_dir()

    if target in ("latest", "last"):
        if not base_dir.is_dir():
            raise FileNotFoundError(f"Runs directory does not exist: {base_dir}")
        candidates = [d for d in base_dir.iterdir() if d.is_dir()]
        if not candidates:
            raise FileNotFoundError(f"No run archives found in: {base_dir}")
        candidates.sort(key=lambda d: d.name)
        return candidates[-1]

    path_target = Path(target).expanduser()
    if path_target.is_file():
        return path_target.resolve().parent
    if path_target.is_dir():
        return path_target.resolve()

    candidate = base_dir / target
    if candidate.is_dir():
        return candidate.resolve()

    raise FileNotFoundError(f"Run archive not found for: {target} (checked {path_target} and {candidate})")


def derive_prompt_retries(trace_content: Optional[str]) -> Optional[int]:
    """Derives the count of prompt retries from trace.log content.

    Rules:
      - Returns None if trace is absent or contains no prompt events.
        (Mark absent data unknown, never zero by assumption).
      - Returns int >= 0 if prompt events are found and retries can be computed.
    """
    if trace_content is None:
        return None

    lines = trace_content.splitlines()
    prompt_records: List[Tuple[str, str, str]] = []

    for line in lines:
        parts = line.strip().split(None, 4)
        if len(parts) >= 4 and parts[3].startswith("prompt."):
            task = parts[2]
            event = parts[3]
            detail = parts[4] if len(parts) > 4 else ""
            prompt_records.append((task, event, detail))
        elif "prompt." in line:
            # Fallback for irregular whitespace
            parts = line.strip().split(None, 4)
            if len(parts) >= 4:
                task = parts[2]
                event = parts[3]
                detail = parts[4] if len(parts) > 4 else ""
                if "prompt." in event:
                    prompt_records.append((task, event, detail))

    if not prompt_records:
        return None

    # Group prompt events by task and prompt submission cycles.
    # A new submission cycle starts when 'prompt.submit' is logged with '<N> bytes'
    # (initial submit in submit_prompt), or on first event for a task.
    task_cycles: Dict[str, List[Dict[str, Any]]] = {}

    for task, event, detail in prompt_records:
        if task not in task_cycles:
            task_cycles[task] = []

        is_initial_submit = (event == "prompt.submit" and bool(re.search(r"^\d+\s+bytes", detail)))
        if is_initial_submit or not task_cycles[task]:
            task_cycles[task].append({"attempts": set(), "explicit_retries": 0})

        current_cycle = task_cycles[task][-1]

        if event == "prompt.retry":
            current_cycle["explicit_retries"] += 1
        elif "retry" in detail.lower() and not re.search(r"attempt\s+\d+", detail, re.IGNORECASE):
            current_cycle["explicit_retries"] += 1

        # Look for attempt numbers, e.g. "(attempt 1)", "(attempt 2)", "attempt 1 rejected"
        for m in re.finditer(r"attempt\s+(\d+)", detail, re.IGNORECASE):
            current_cycle["attempts"].add(int(m.group(1)))

        # Look for "both attempts failed" or "N attempts failed"
        m_lost = re.search(r"(\d+)\s+attempts\s+failed", detail, re.IGNORECASE)
        if m_lost:
            current_cycle["attempts"].add(int(m_lost.group(1)))
        elif "both attempts failed" in detail.lower():
            current_cycle["attempts"].add(2)

    total_retries = 0
    for task, cycles in task_cycles.items():
        for cycle in cycles:
            attempts = cycle["attempts"]
            if attempts:
                max_att = max(attempts)
                cycle_retries = max(0, max_att - 1)
            else:
                cycle_retries = 0
            total_retries += cycle_retries + cycle["explicit_retries"]

    return total_retries


def parse_duration(val: Union[str, int, float, None]) -> Optional[float]:
    """Parses a duration input into seconds as a float.

    Supports:
      - 900 or 900s
      - 15m, 15min, 15mins
      - 1h, 1.5h, 1h30m, 1h 30m 15s
      - 15:30 (MM:SS) or 1:15:30 (HH:MM:SS)
      - None / "unknown" -> None
    """
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)

    s = str(val).strip()
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None

    if ":" in s:
        parts = s.split(":")
        try:
            if len(parts) == 2:
                return float(parts[0]) * 60 + float(parts[1])
            elif len(parts) == 3:
                return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
        except ValueError:
            raise ValueError(f"Invalid colon duration format: '{val}'")

    pattern = (
        r"^(?:(\d+(?:\.\d+)?)\s*h(?:ours?)?)?\s*"
        r"(?:(\d+(?:\.\d+)?)\s*m(?:in(?:ute)?s?)?)?\s*"
        r"(?:(\d+(?:\.\d+)?)\s*s(?:ec(?:ond)?s?)?)?$"
    )
    m = re.match(pattern, s, re.IGNORECASE)
    if m and any(m.groups()):
        h = float(m.group(1)) if m.group(1) else 0.0
        mn = float(m.group(2)) if m.group(2) else 0.0
        sec = float(m.group(3)) if m.group(3) else 0.0
        return h * 3600 + mn * 60 + sec

    try:
        return float(s)
    except ValueError:
        raise ValueError(f"Invalid duration value: '{val}'")


def format_duration(seconds: Optional[Union[float, int]]) -> str:
    """Formats seconds into a clean human string or 'unknown'."""
    if seconds is None:
        return "unknown"
    sec = float(seconds)
    if sec < 60:
        return f"{int(sec)}s"
    if sec < 3600:
        m = int(sec // 60)
        s = int(sec % 60)
        return f"{m}m {s:02d}s" if s else f"{m}m"
    h = int(sec // 3600)
    rem = sec % 3600
    m = int(rem // 60)
    s = int(rem % 60)
    if s:
        return f"{h}h {m:02d}m {s:02d}s"
    return f"{h}h {m:02d}m" if m else f"{h}h"


def parse_cost(val: Union[str, int, float, None]) -> Optional[float]:
    """Parses a cost value into USD float."""
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)

    s = str(val).strip()
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None

    if s.startswith("$"):
        s = s[1:].strip()

    try:
        return float(s)
    except ValueError:
        raise ValueError(f"Invalid cost value: '{val}'")


def format_cost(cost: Optional[Union[float, int]]) -> str:
    """Formats cost as $X.XX or 'unknown'."""
    if cost is None:
        return "unknown"
    return f"${float(cost):.2f}"


def parse_human_minutes(val: Union[str, int, float, None]) -> Optional[float]:
    """Parses human minutes into float."""
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)

    s = str(val).strip()
    if not s or s.lower() in ("null", "none", "unknown", "-"):
        return None

    if s.endswith("m") or s.endswith("min") or s.endswith("mins"):
        s = re.sub(r"[a-zA-Z]+$", "", s).strip()

    try:
        return float(s)
    except ValueError:
        raise ValueError(f"Invalid human minutes value: '{val}'")


def format_human_minutes(minutes: Optional[Union[float, int]]) -> str:
    """Formats human minutes or 'unknown'."""
    if minutes is None:
        return "unknown"
    val = float(minutes)
    if val.is_integer():
        return f"{int(val)}m"
    return f"{val:.1f}m"


def parse_post_merge_fixes(val: Union[str, int, None]) -> Optional[Union[int, str]]:
    """Parses post-merge fixes.

    Returns int if numeric, string if descriptive note, or None if omitted/unknown.
    Crucially: 0 returns 0, NOT None!
    """
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


def format_post_merge_fixes(fixes: Optional[Union[int, str]]) -> str:
    """Formats post merge fixes or 'unknown'."""
    if fixes is None:
        return "unknown"
    return str(fixes)


def parse_prompt_retries(val: Union[str, int, None]) -> Optional[int]:
    """Parses manual prompt retries override."""
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
        raise ValueError(f"Invalid prompt retries value: '{val}'")


def format_prompt_retries(retries: Optional[int]) -> str:
    """Formats prompt retries count or 'unknown'."""
    if retries is None:
        return "unknown"
    return str(retries)


def read_run_data(run_dir: Path) -> Dict[str, Any]:
    """Reads all available outcome and metadata for an archived run.

    Keeps historical archives readable: missing outcome.json or missing trace.log
    are handled gracefully, marking absent fields as None (unknown).
    """
    run_id = run_dir.name
    run_meta_path = run_dir / "run.json"
    if run_meta_path.is_file():
        try:
            with open(run_meta_path, "r", encoding="utf-8", errors="replace") as f:
                meta = json.load(f)
                run_id = meta.get("run_id") or run_id
        except Exception:
            pass

    outcome_path = run_dir / "outcome.json"
    outcome_data: Dict[str, Any] = {}
    is_annotated = False

    if outcome_path.is_file():
        try:
            with open(outcome_path, "r", encoding="utf-8", errors="replace") as f:
                outcome_data = json.load(f)
                is_annotated = True
                run_id = outcome_data.get("run_id") or run_id
        except Exception:
            pass

    # Trace log derivation
    trace_path = run_dir / "trace.log"
    derived_retries: Optional[int] = None
    has_trace = trace_path.is_file()

    if has_trace:
        try:
            trace_content = trace_path.read_text(encoding="utf-8", errors="replace")
            derived_retries = derive_prompt_retries(trace_content)
        except Exception:
            derived_retries = None

    # Prompt retries preference:
    # 1. Annotated explicit value (if present in outcome.json)
    # 2. Derived from trace.log
    # 3. None (unknown)
    annotated_retries = outcome_data.get("prompt_retries")
    if annotated_retries is not None:
        final_retries = parse_prompt_retries(annotated_retries)
        retries_source = "annotated"
    elif derived_retries is not None:
        final_retries = derived_retries
        retries_source = "trace"
    else:
        final_retries = None
        retries_source = "absent"

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
        "retries_source": retries_source,
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
    """Annotates an archived run and writes outcome.json.

    Writes directly into the run archive directory. Does not touch or require
    any agent worktree, satisfying post-cleanup constraints.
    """
    existing_data = read_run_data(run_dir)
    outcome_path = run_dir / "outcome.json"

    if overwrite or not existing_data["annotated"]:
        base_record: Dict[str, Any] = {
            "run_id": existing_data["run_id"],
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
        base_record = {
            "run_id": existing_data["run_id"],
            "merge_outcome": existing_data["merge_outcome"],
            "human_minutes": existing_data["human_minutes"],
            "post_merge_fixes": existing_data["post_merge_fixes"],
            "elapsed_seconds": existing_data["elapsed_seconds"],
            "cost_usd": existing_data["cost_usd"],
            "prompt_retries": existing_data["prompt_retries"],
            "notes": existing_data["notes"],
            "annotated_at": existing_data["annotated_at"],
        }

    # Update only fields that were provided
    if merge_outcome is not None:
        base_record["merge_outcome"] = merge_outcome.strip() if merge_outcome else None
    if human_minutes is not None:
        base_record["human_minutes"] = human_minutes
    if post_merge_fixes is not None:
        base_record["post_merge_fixes"] = post_merge_fixes
    if elapsed_seconds is not None:
        base_record["elapsed_seconds"] = elapsed_seconds
    if cost_usd is not None:
        base_record["cost_usd"] = cost_usd
    if prompt_retries is not None:
        base_record["prompt_retries"] = prompt_retries
    elif base_record["prompt_retries"] is None:
        # Auto-derive from trace if available and not previously recorded
        trace_path = run_dir / "trace.log"
        if trace_path.is_file():
            try:
                tc = trace_path.read_text(encoding="utf-8", errors="replace")
                derived = derive_prompt_retries(tc)
                if derived is not None:
                    base_record["prompt_retries"] = derived
            except Exception:
                pass

    if notes is not None:
        base_record["notes"] = notes.strip() if notes else None

    base_record["annotated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Atomic write to outcome.json
    tmp_path = run_dir / f"outcome.json.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(base_record, f, indent=2)
        f.write("\n")
    tmp_path.replace(outcome_path)

    return read_run_data(run_dir)


def format_table(records: List[Dict[str, Any]]) -> str:
    """Formats a list of run records into an aligned text table."""
    headers = [
        "RUN ID",
        "MERGE",
        "HUMAN MIN",
        "FIXES",
        "ELAPSED",
        "COST",
        "RETRIES",
        "ANNOTATED",
    ]

    rows: List[List[str]] = []
    for r in records:
        rows.append([
            r["run_id"],
            r["merge_outcome"] or "unknown",
            format_human_minutes(r["human_minutes"]),
            format_post_merge_fixes(r["post_merge_fixes"]),
            format_duration(r["elapsed_seconds"]),
            format_cost(r["cost_usd"]),
            format_prompt_retries(r["prompt_retries"]),
            "yes" if r["annotated"] else "no",
        ])

    widths = [len(h) for h in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    header_fmt = "  ".join(f"%-{w}s" for w in widths)
    separator = "  ".join("-" * w for w in widths)

    lines = [header_fmt % tuple(headers), separator]
    for row in rows:
        lines.append(header_fmt % tuple(row))

    return "\n".join(lines)


def format_single_run_summary(r: Dict[str, Any]) -> str:
    """Formats a single run record with full details."""
    annotated_str = "yes" if r["annotated"] else "no"
    if r.get("annotated_at"):
        annotated_str += f" ({r['annotated_at']})"

    retries_str = format_prompt_retries(r["prompt_retries"])
    if r["prompt_retries"] is not None:
        source_note = "derived from trace.log" if r.get("retries_source") == "trace" else "annotated"
        retries_str += f" ({source_note})"
    else:
        retries_str += " (no trace or no prompt events)"

    elapsed_str = format_duration(r["elapsed_seconds"])
    if r["elapsed_seconds"] is not None:
        elapsed_str += f" ({int(r['elapsed_seconds'])}s)"

    lines = [
        f"Run Outcome: {r['run_id']}",
        f"  Archive dir:       {r['archive_dir']}",
        f"  Annotated:         {annotated_str}",
        f"  Merge outcome:     {r['merge_outcome'] or 'unknown'}",
        f"  Human minutes:     {format_human_minutes(r['human_minutes'])}",
        f"  Post-merge fixes:  {format_post_merge_fixes(r['post_merge_fixes'])}",
        f"  Elapsed time:      {elapsed_str}",
        f"  Cost:              {format_cost(r['cost_usd'])}",
        f"  Prompt retries:    {retries_str}",
        f"  Notes:             {r['notes'] or 'unknown'}",
    ]
    return "\n".join(lines)


def run_report(
    target: Optional[str] = None,
    runs_dir: Optional[Path] = None,
    as_json: bool = False,
) -> int:
    """Handles the report command."""
    base_dir = runs_dir or get_default_runs_dir()

    if target:
        try:
            r_dir = resolve_run_dir(target, base_dir)
            data = read_run_data(r_dir)
            if as_json:
                print(json.dumps(data, indent=2))
            else:
                print(format_single_run_summary(data))
            return 0
        except FileNotFoundError as e:
            sys.stderr.write(f"ERROR: {e}\n")
            return 1

    if not base_dir.is_dir():
        if as_json:
            print("[]")
        else:
            print(f"No run archives found in {base_dir}")
        return 0

    run_dirs = [d for d in base_dir.iterdir() if d.is_dir()]
    run_dirs.sort(key=lambda d: d.name)

    records = [read_run_data(d) for d in run_dirs]

    if as_json:
        print(json.dumps(records, indent=2))
    else:
        if not records:
            print(f"No run archives found in {base_dir}")
        else:
            print(format_table(records))
    return 0


def run_annotate(args: argparse.Namespace) -> int:
    """Handles the annotate command."""
    base_dir = Path(args.runs_dir).expanduser().resolve() if args.runs_dir else get_default_runs_dir()
    try:
        r_dir = resolve_run_dir(args.run, base_dir)
    except FileNotFoundError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 1

    try:
        h_min = parse_human_minutes(args.human_minutes) if args.human_minutes is not None else None
        p_fixes = parse_post_merge_fixes(args.post_merge_fixes) if args.post_merge_fixes is not None else None
        
        # Elapsed can come from --elapsed or --elapsed-seconds
        raw_elapsed = args.elapsed_seconds if args.elapsed_seconds is not None else args.elapsed
        elapsed_s = parse_duration(raw_elapsed) if raw_elapsed is not None else None

        # Cost can come from --cost or --cost-usd
        raw_cost = args.cost_usd if args.cost_usd is not None else args.cost
        cost = parse_cost(raw_cost) if raw_cost is not None else None

        retries = parse_prompt_retries(args.prompt_retries) if args.prompt_retries is not None else None

        result = annotate_run(
            run_dir=r_dir,
            human_minutes=h_min,
            merge_outcome=args.merge_outcome,
            post_merge_fixes=p_fixes,
            elapsed_seconds=elapsed_s,
            cost_usd=cost,
            prompt_retries=retries,
            notes=args.notes,
            overwrite=args.overwrite,
        )

        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(f"Annotated archive: {r_dir}")
            print(format_single_run_summary(result))
        return 0

    except ValueError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 1


def build_parser() -> argparse.ArgumentParser:
    common_parent = argparse.ArgumentParser(add_help=False)
    common_parent.add_argument(
        "--runs-dir",
        help="Path to runs directory (default: HERDR_SWARM_RUN_DIR or ~/.herdr/runs)",
    )

    parser = argparse.ArgumentParser(
        prog="run-outcome",
        description="Annotate archived swarm runs and report outcomes/rework metrics.",
        parents=[common_parent],
    )

    subparsers = parser.add_subparsers(dest="subcommand", help="Subcommand to run")

    # Annotate subcommand
    annotate_parser = subparsers.add_parser(
        "annotate",
        help="Annotate an archived run",
        parents=[common_parent],
    )
    annotate_parser.add_argument("run", help="Run ID or path to archive (or 'latest')")
    annotate_parser.add_argument("-m", "--human-minutes", help="Human minutes spent on review/fixes")
    annotate_parser.add_argument("-o", "--merge-outcome", help="Outcome: merged, abandoned, rejected, amended, etc.")
    annotate_parser.add_argument("-f", "--post-merge-fixes", help="Count or description of fixes required after merge")
    annotate_parser.add_argument("-e", "--elapsed", help="Elapsed time to correct solution (e.g. 15m, 900s, 1:15:00)")
    annotate_parser.add_argument("--elapsed-seconds", type=float, help="Elapsed time in seconds")
    annotate_parser.add_argument("-c", "--cost", help="Known cost in USD (e.g. 0.25 or $0.25)")
    annotate_parser.add_argument("--cost-usd", help="Alias for --cost")
    annotate_parser.add_argument("-r", "--prompt-retries", help="Override prompt retries count (default: derived from trace)")
    annotate_parser.add_argument("--notes", help="Human notes regarding the outcome or fixes")
    annotate_parser.add_argument("--overwrite", action="store_true", help="Overwrite existing outcome rather than merging fields")
    annotate_parser.add_argument("--json", action="store_true", help="Output annotated record as JSON")

    # Report subcommand
    report_parser = subparsers.add_parser(
        "report",
        help="Report outcomes across archived runs",
        parents=[common_parent],
    )
    report_parser.add_argument("run", nargs="?", help="Optional run ID or path to inspect single run")
    report_parser.add_argument("--json", action="store_true", help="Output results as JSON")

    # Show subcommand
    show_parser = subparsers.add_parser(
        "show",
        help="Show details for a single archived run",
        parents=[common_parent],
    )
    show_parser.add_argument("run", help="Run ID or path to inspect (or 'latest')")
    show_parser.add_argument("--json", action="store_true", help="Output results as JSON")

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    runs_dir = Path(args.runs_dir).expanduser().resolve() if args.runs_dir else None

    if args.subcommand == "annotate":
        return run_annotate(args)
    elif args.subcommand == "report":
        return run_report(target=args.run, runs_dir=runs_dir, as_json=args.json)
    elif args.subcommand == "show":
        return run_report(target=args.run, runs_dir=runs_dir, as_json=args.json)
    else:
        # Default with no subcommand: report all archived runs
        return run_report(target=None, runs_dir=runs_dir, as_json=False)


if __name__ == "__main__":
    sys.exit(main())
