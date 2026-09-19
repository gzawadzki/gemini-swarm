# Reference: agent kinds, models and routing

Which binary runs a task, which model it runs on, and why the answer is almost
always a Gemini Flash slug.

## The three agent kinds

| kind | binary | auto-approve flag | notes |
|------|--------|-------------------|-------|
| `gemini` | `gemini` | `--yolo` (or `--approval-mode yolo`) | Classic Gemini CLI. Google sunset this for Free/Pro/Ultra users on 2026-06-18 in favour of Antigravity CLI, so it may not be installed. Check `command -v gemini` before assuming it exists. |
| `agy` | `agy` | `--dangerously-skip-permissions` | Antigravity CLI, the successor. That is the flag name Google ships; treat it as seriously as it sounds. |
| `codex` | `codex` | `--dangerously-bypass-approvals-and-sandbox` | OpenAI Codex CLI. Used when the user asks for it by name, and as the last-resort fallback once both Antigravity accounts are empty. See [accounts and quota](accounts-and-quota.md). |

All three are valid `--kind` values for `herdr agent start`, so no manual pane
handling is needed. If the user says "Gemini" but only `agy` is installed, ask
once which they mean rather than silently swapping binaries.

## The model menu

`agy` exposes several models through `--model`, each with a real cost, speed and
quality tradeoff. Classic `gemini` has no model menu, so `model` and `effort`
apply to `kind: "agy"` and `kind: "codex"` only; `launch.sh` warns and ignores
them on a `gemini` task.

Most agy slugs bake the reasoning effort into the name, so
`gemini-3.8-flash-low` and `gemini-3.8-flash-high` are separate slugs. A
`--effort` flag (`low|medium|high`) exists as well. Confirmed with Antigravity
CLI 1.1.27:

| Model slug | Use it for |
|------------|------------|
| `gemini-3.8-flash-low`, `-medium`, `-high` | Cheap and fast. Formatting, boilerplate, mechanical fixes, and — at `-high` — most ordinary work. Newest Flash generation; prefer it over the 3.7 and 3.6 slugs. |
| `gemini-3.1-pro-low`, `gemini-3.1-pro-high` | 1M context, steady on big repos. The step up when a task genuinely needs more context, or when flash-high already produced a bad diff for it. |
| `claude-sonnet-4-6` | Step-by-step reasoning without Opus pricing. Draws on the scarce pool. |
| `claude-opus-4-6-thinking` | The heaviest model here. Security review, nasty bugs, architecture. Expensive, and on the scarce pool. |
| `gpt-oss-120b-medium` | Open-weight, 400K context, generally below Gemini Pro and Opus at coding. A second opinion, rarely a first pick. |

Older slugs (`gemini-3.7-flash-*`, `gemini-3.6-flash-*`) still work. Google adds
a Flash generation faster than this file gets updated, so run `agy models` on the
target machine: if it shows a higher number than this table does, trust `agy
models`.

## Routing: default to the Gemini pool

Antigravity meters two pools separately. **Gemini Models** is the large one the
user pays for; **Claude and GPT models** is scarce. Routing swarm work into the
scarce pool drains it fast and duplicates reasoning the orchestrator already
provides, so the default is:

1. Mechanical, low-risk, well-defined → `gemini-3.8-flash-medium`.
2. **Everything else** — ordinary features, bugfixes, refactors, reviews →
   `gemini-3.8-flash-high`. This is the default for almost every task.
3. `gemini-3.1-pro-high` when the task needs the bigger context, or when
   flash-high already produced a bad diff for it once. Both are on the Gemini
   pool, so this costs nothing scarce.
4. A `claude-*` or `gpt-*` slug **only when the user names it**, or when a task
   genuinely failed on Gemini Pro twice. Say so when you do, because it spends
   the scarce pool.

The measurement behind step 2 is in
[ADR 0003](../adr/0003-flash-high-is-the-default.md): a four-part ticket
(per-country seed offsets, CLI help derived from a profile cycle, comment
translation, golden tests off limits) landed on flash-high in 9.5 minutes with
zero bounces, because the task named the traps up front. A well-specified slice
does not need Pro, and a vague one is not rescued by it. Sharpening the task is
the cheaper move than upgrading the model — see
[defining a task](task-definition.md).

If the user names a model outright, use it and skip the heuristic.

## The critique reviewer

`critique.sh` first uses Jev for typed risk scoring when a TypeSafe or OpenRouter
key is available and the diff satisfies the automatic-acceptance preconditions.
Anything Jev cannot clear falls through to `gemini-3.8-flash-high`, which swaps
to `gemini-3.1-pro-high` when that would mean a model reviewing its own output.
The full rules are in [the gate](the-gate.md#stage-2-critique-the-judgement-half).
