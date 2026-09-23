# Reference: Jev decision evaluation and shadow mode

The P1 labeled evaluation set measures whether Jev's fast semantic triage can
safely auto-accept diffs without human reading. This document describes the
candidate pipeline, human labeling, shadow mode execution, and threshold analysis.

The vocabulary here — slice, pitfall, gate, critique, soundness — is defined in
[CONTEXT.md](../../CONTEXT.md) and [the-gate.md](the-gate.md).

## Rationale: uncalibrated policy vs. calibrated gate

In `scripts/critique.sh`, Jev answers bounded semantic questions (requirements,
correctness, scope, security, test preservation, regression tests, pitfalls).
If every risk signal is at or below `HERDR_SWARM_JEV_ACCEPT_MAX` (default `0.10`),
the diff bypasses generative review.

**The default `0.10` threshold is an uncalibrated policy default, not an
empirically calibrated operating point on swarm data.**

An auto-accept filter has asymmetric failure costs:
- **False reject (safe escalation):** An acceptable diff is escalated to human
  or generative review; costs reviewer time and tokens.
- **False accept (silent leak):** A defective diff is cleared and marked
  mergeable without human review; bugs reach the main branch.

Until calibrated against labeled archives, Jev must not skip human reading.

## Tooling: `scripts/jev-eval.py`

`scripts/jev-eval.py` is a stdlib-only CLI providing two commands:

```bash
# 1. Prepare candidate records from swarm archives (human labels left blank)
python scripts/jev-eval.py prepare ~/.herdr/runs -o candidates.jsonl

# 2. Evaluate labeled records at supplied threshold (text or JSON)
python scripts/jev-eval.py report -i labeled.jsonl -t 0.10
python scripts/jev-eval.py report -i labeled.jsonl -t 0.10 -f json -o report.json
```

### Denominator rule and record distinction

To avoid skewed metrics across historical runs:
- **Missing labels:** Records with no human label (`human_label: null`) are
  unlabeled and excluded. Missing labels are never treated as acceptable.
- **Unscored labeled records:** Historical archives predating Jev or runs where
  Jev failed have no signals (`risk_max: null`). They are separated and excluded
  from coverage and escalation counts so unscored diffs do not invent false
  escalations.
- **Scored denominator:** The true denominator for coverage and false accept
  rates is strictly the count of records that have both explicit human labels
  and usable Jev scores.

## Candidate and label schema

`prepare` produces JSONL candidate records:

```json
{
  "id": "20260920T120000Z:task-1",
  "run_id": "20260920T120000Z",
  "task_name": "task-1",
  "prompt": "Add rate limiter...",
  "diff_lines": 57,
  "diff_size_bucket": "small (<=100)",
  "diff": "diff --git ...",
  "jev": {
    "attempted": true,
    "risk_max": 0.04,
    "signals": {"correctness_defect": 0.04, "security_risk": 0.0}
  },
  "human_label": null
}
```

Annotators set `human_label`:
- **Clean/Acceptable:** `{"acceptable": true, "risks": [], "notes": "LGTM"}`
- **Defective:** `{"acceptable": false, "risks": ["correctness_defect"], "notes": "Off-by-one"}`

Allowed risks: `requirement_missing`, `correctness_defect`, `unrelated_change`,
`security_risk`, `check_weakened`, `regression_test_missing`, or named pitfalls.

## Shadow mode and the pending gate change

Shadow mode collects real Jev predictions without risking unreviewed diffs landing
in production.

### Alignment with pending verify soundness gate

The pending gate change (proposal P0) restricts auto-acceptance to verified runs
with confirmed soundness: `verify.status == "pass"` AND `verify.soundness == "sound"`.
Runs where soundness is `unknown`, `unsound`, or `disabled` will never auto-accept.

In shadow mode:
1. Set `HERDR_SWARM_JEV_AUTO_ACCEPT=0`.
2. `critique.sh` records `.critique.jev-response.json` and `.critique.json` into
   `.herdr-swarm/`, but all tasks fall through to generative critique and human read.
3. `scripts/lib.sh` archives these signals during cleanup.
4. Periodically run `jev-eval.py prepare` to extract candidates for labeling.

This decouples evaluation from gate enforcement, allowing the swarm to gather
empirical calibration data across varying diff sizes and risk types safely.
