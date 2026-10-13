# Jev archive study, 2026-09-25

Prepared with `python scripts/jev-eval.py prepare ~/.herdr/runs -o ~/.herdr/jev-candidates.jsonl`.
The committed index is [evals/jev/index.jsonl](../../evals/jev/index.jsonl). It has
the same 33 task ids and omits prompts and diffs, because those diffs belong to
other repositories and this one is public.

This is not a calibration. `human_label` is null on every record. A missing label
is not an acceptable diff. Generative critique verdicts are not human labels
either: 15 of 26 critique files are `unparseable` because the reviewer did not
return JSON.

## What the archive contains

| fact | count |
| --- | ---: |
| archived tasks with `state.json` | 33 |
| human labels | 0 |
| critique files | 26 |
| verify files | 29 |
| Jev HTTP responses | 2 |
| Jev-scored records (`risk_max` present) | 2 |
| records eligible for auto-accept (`pass` and `sound`) | 0 |
| records that would auto-accept at `0.10` | 0 |

Verify status: 23 skipped, 5 pass, 1 fail, 4 missing. Soundness: 24 unknown, 5
disabled, 4 missing, 0 sound. Diff size: 4 small, 9 medium, 9 large, 11 oversized.
Worker models: 26 `gemini-3.8-flash-high`, 3 `gpt-6-luna`, 3
`openrouter/stealth/space-bunny-alpha`, 1 `gemini-3.8-flash`.

## The only two Jev scores

Both are from `20260919T161853Z`, model `jev-1.13.0`, route `typesafe`. Verify
passed only because `HERDR_SWARM_NO_SOUNDNESS=1`, so soundness is `disabled`.
Current `critique.sh` would not call Jev on either diff, and neither would
auto-accept.

| task | risk_max | generative verdict | signals above 0.10 |
| --- | ---: | --- | --- |
| `czajka-testset` | 0.60 | pass | `pitfall_5` 0.60, `correctness_defect` 0.34, `requirement_missing` 0.28, `regression_test_missing` 0.20, `pitfall_3` 0.16, `pitfall_1` 0.11 |
| `router-testset` | 0.87 | pass | `requirement_missing` 0.87, `correctness_defect` 0.59, `pitfall_1` 0.54, `regression_test_missing` 0.21, `pitfall_3` 0.17 |

The trace shows an earlier `czajka-testset` call at `risk_max` 0.68 as well. The
archived verdict kept the later 0.60 response. Both calls escalated. The
generative reviewer then said pass. That disagreement is not a false accept and
not a human judgment. It is one reason a person still has to label these two
diffs before anyone treats `0.10` as safe.

## Why later shadow runs did not score

Fourteen critiques from 2026-09-23 and 2026-09-25 record `mode: shadow`,
`attempted: false`, and empty signals. The trace for `kb-contracts` says why:
`verify status=skipped soundness=unknown; automatic acceptance requires pass and
soundness sound`. The five passes in the later set are all `soundness: disabled`.
Shadow mode therefore did not collect the signal vectors the calibration needs.
It recorded a skip.

## What this does not justify

- Do not lower or raise `HERDR_SWARM_JEV_ACCEPT_MAX`. There is no labeled
  denominator.
- Do not turn on automatic acceptance from this study. Zero archived diffs are
  both sound and scored.
- Do not count a generative `pass` over a high Jev signal as evidence that Jev
  was wrong.
- Do not fill `human_label` from the critique summary.

## What would make the next study usable

1. A person labels the two scored diffs, and any new sound diffs, with
   `acceptable` plus named risks. `scripts/jev-eval.py report` can then compute
   false accepts. Until then its scored denominator is zero.
2. New runs need `soundness: sound` before Jev is even called. Bash-only verifies
   currently land on `unknown` or `disabled`, so they never enter the set.
3. Shadow mode now scores diffs that cannot auto-accept, except a truncated
   diff or a protected path. That change does not relabel this archive and does
   not calibrate `0.10`.
