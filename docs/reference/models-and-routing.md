# Reference: agent kinds, models and routing

## Agent kinds

| kind | binary | launch flags | use |
|------|--------|--------------|-----|
| `pi` | `pi` plus `pi-antigravity` | `--approve --provider antigravity` | Default Antigravity worker and reviewer. Pi tools run unattended. |
| `gemini` | `gemini` | `--yolo` | Classic Gemini CLI when explicitly requested. |
| `codex` | `codex` | `--dangerously-bypass-approvals-and-sandbox` | OpenAI Codex CLI for the Luna route or an explicit user choice. |

Herdr supports all three kinds. `kind: "agy"` is rejected; update configs to
`kind: "pi"`. Install the Pi provider with `pi install npm:pi-antigravity`,
then sign in with `/login antigravity` inside Pi.

## Worker gate

Apply this after reading the code and before writing `tasks.json`. State the
route and one piece of evidence from the code for each candidate task. A model
or harness the user chose explicitly takes precedence.

1. **Finish recon first.** Locate the affected code and callers, name expected
   files and pitfalls, and identify a command that can verify the result. A
   vague task is not a reason to start a worker.
2. **Use Pi Antigravity** for a self-contained slice: the desired behavior is
   clear, the implementation follows an existing pattern, the files are
   bounded, and one check can expose a wrong result. Prefer
   `kind: "pi"`, `model: "gemini-3.8-flash-high"`.
3. **Use Luna 6 xhigh** when the task is scoped but its correctness depends on
   comparing plausible causes, changing a shared contract across modules, or
   preserving coupled behavior through implementation and tests. Consequential
   auth, permission, schema, and data-integrity changes take this route unless
   recon shows a mechanical change with a decisive check. Set
   `kind: "codex"`, `model: "gpt-6-luna"`, `effort: "xhigh"`.
4. **Split when possible.** If only one decision is hard, give that coherent
   part to Luna and route the independent, specified follow-up slices to Pi.
   After two review-fix rounds fail on the same Pi task, send its remaining work
   to Luna with the diff, test failure, and critique attached.

Both routes use their own Herdr worktree and the same verify and critique gate.
Do not pick Luna just because an implementation changes two files, or pick Pi
because a prompt can be made short. The test is whether the worker has enough
evidence to finish the task without making a new design decision.

For example, updating one parser and its existing tests after identifying the
format rule goes to Pi. A session bug that could originate in cookies, token
refresh, or middleware order goes to Luna for one coherent diagnosis and fix.

[OpenAI's model guidance](https://developers.openai.com/api/docs/guides/model-selection)
describes Luna at extra-high effort for problems with clear constraints. The
rules above are this repository's routing policy, not a model guarantee.

## Models

Pi exposes public Antigravity model IDs. Inspect the current account with
`/antigravity.models` in Pi. Task configs can use the public ID and `effort`
(`low`, `medium`, or `high`), for example:

```json
{"kind":"pi","model":"gemini-3.8-flash","effort":"high"}
```

For existing configs, `launch.sh` converts `gemini-3.8-flash-high` to
`--model gemini-3.8-flash --thinking high`, `gemini-3.1-pro-high` to
`gemini-3.1-pro` with high thinking, and `claude-opus-4-6-thinking` to
`claude-opus-4-6` with high thinking. An explicit `effort` overrides the
suffix. Pi tasks with no model use `gemini-3.8-flash` at high thinking.

Within the Pi route, use Flash for ordinary scoped work and Pro when the task
needs more context.
Claude and GPT models use the scarcer Antigravity quota group. The user may
choose any model their account offers. See [ADR 0003](../adr/0003-flash-high-is-the-default.md)
for the Flash default.

## Reviewer

`critique.sh` first tries Jev automatic acceptance when its preconditions and
credentials are present. Other diffs are reviewed through Pi on the
Antigravity provider. It selects `gemini-3.1-pro-high` when the worker used
the default `gemini-3.8-flash-high`, avoiding the same model reviewing itself.
Pi runs the review in print mode with an ephemeral session.
