# Reference: worker permissions and sandboxing boundary

This document details the threat model for background worker sub-agents
orchestrated by `gemini-swarm`, the sandbox reality of the execution platform,
and the fail-closed permission boundary enforced at launch time.

The vocabulary here — worker, slice, gate, worktree — is defined in
[CONTEXT.md](../../CONTEXT.md).

## Concrete threat model

`gemini-swarm` launches unattended worker sub-agents (`pi`, `codex`, `gemini`)
inside background `herdr` terminal panes. Each worker executes tools autonomously
to complete its assigned slice. Because workers run without interactive human
confirmation prompts per tool invocation, their access profile represents a
critical security boundary.

### 1. Host filesystem access

- **Arbitrary file access:** Workers have access to shell tools (`bash`) or
  native file tools. A worker process runs with the ambient privileges of the
  local user account.
- **Access beyond the repository:** An agent can read and modify files anywhere
  the user has permissions: the user home directory (`~/.ssh`, `~/.aws`,
  `~/.config`, `~/.gnupg`), system directories, global environment settings,
  and checkouts of unrelated repositories.
- **Git worktrees are not OS isolation:** A git worktree is a git-level
  convenience that provides a dedicated working tree and branch pointing to the
  same git repository object store. It provides zero process, memory, or
  filesystem isolation. Any command executed inside a worktree can access
  parent directories, traversal paths (`../..`), or absolute paths across the
  entire host filesystem.
- **`pi --tools` is not OS isolation:** Pi's `--tools` option restricts the list
  of tool specifications presented in the model's schema (e.g. bash, read,
  write, edit). It is a prompt-level tool filter, not an OS sandbox. Once the
  model invokes `bash`, the spawned shell process possesses complete host access.
- **`pi --approve` is not OS isolation:** Pi's `--approve` flag automatically
  approves tool confirmation for project-relative operations. It does not
  sandbox the spawned subprocesses or prevent shell commands from accessing host
  files outside the project tree.

### 2. Network access

- **Outbound network calls:** Worker processes can initiate arbitrary outbound
  network connections via `curl`, `wget`, `python`, `node`, package managers
  (`npm`, `pip`, `cargo`), or raw sockets.
- **Data exfiltration:** Malicious or hallucinated code execution could exfiltrate
  source code, internal architectural details, or sensitive files to external
  endpoints.
- **Untrusted payload retrieval:** Workers may fetch untrusted third-party
  binaries or unpinned dependencies during build or test execution.
- **Internal network exposure:** Workers have network access to localhost and
  local network services (e.g. databases, local web services, internal APIs, or
  cloud provider metadata endpoints).

### 3. Secrets and credential exposure

- **Environment variables:** Worker panes inherit environment variables from the
  parent shell session, including API tokens (such as `TYPESAFE_API_KEY`,
  `OPENROUTER_API_KEY`, cloud keys, or internal tokens).
- **Filesystem credentials:** Private keys in `~/.ssh/id_*`, cloud credentials in
  `~/.aws/credentials`, Git credential caches, Docker configs, and local `.env`
  files across checkouts are readable by the worker process.
- **Codex configuration:** Unsandboxed execution flags or trust configurations
  must not permanently alter global configuration in `~/.codex/config.toml`.

## Sandboxing reality on this platform

An enforceable sandbox requires OS-level containment primitives (such as Linux
namespaces, cgroups, `seccomp`, bubblewrap, or dedicated Windows container
isolators) capable of restricting filesystem view, network routing, and process
privileges.

- **Platform limitations:** On Windows with Git Bash, neither `herdr` nor the
  underlying operating system environment provides a transparent, enforceable
  OS sandbox driver for arbitrary interactive terminal panes.
- **Codex workspace-write limitation:** OpenAI Codex provides a `--sandbox`
  mechanism (e.g., `workspace-write`), but worker completion protocol requires
  writing the result JSON (`<name>.result.json`) into the swarm state directory
  (`.herdr-swarm/`), which resides outside the task's worktree checkout.
  Enabling workspace-write alone restricts writes strictly to the worktree and
  breaks the required last action of the worker.
- **Reality:** Worker execution in this swarm is **unsandboxed**. Neither git
  worktrees, nor Pi `--tools`, nor Pi `--approve` provide sandbox isolation.

## The fail-closed permission boundary

Because background workers run unattended and unsandboxed, `scripts/launch.sh`
**fails closed by default**.

1. **Explicit operator opt-in required:**
   Workers will not launch unless the operator explicitly permits unsandboxed
   execution for that run using either:
   - CLI flag: `scripts/launch.sh --allow-unsandboxed tasks.json`
   - Session environment variable: `HERDR_SWARM_ALLOW_UNSANDBOXED=1 scripts/launch.sh tasks.json`

2. **Refusal before side effects:**
   If the operator has not explicitly opted in, `launch.sh` immediately aborts
   with an error message and non-zero exit code (1). This refusal occurs
   **before** creating git worktrees, before creating pane workspaces, before
   spawning agent processes, and before writing run or task state.

3. **Visible announcement and permanent archiving:**
   - When the operator chooses unsandboxed execution, `launch.sh` prints a clear
     notice to the console acknowledging that unsandboxed worker execution is
     active and host files, network, and secrets are accessible.
   - The decision is recorded in `.herdr-swarm/run.json` with
     `"worker_isolation": "unsandboxed"` and `"allow_unsandboxed": true`.
   - When `cleanup.sh` archives the run, this metadata is permanently preserved
     in the run archive (`~/.herdr/runs/<run-id>/run.json`).

4. **Scoped override without silent global bypasses:**
   - The unsandboxed override is strictly scoped to the worker launch invocation.
   - It does not silently enable Codex's bypass flag globally or alter
     `~/.codex/config.toml`.
   - For Codex workers, `--dangerously-bypass-approvals-and-sandbox` is passed
     explicitly on the command line only when the run-level unsandboxed override
     has been chosen, and its usage is announced.
