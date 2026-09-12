# 05 — Verify cannot report a pass for code it never ran

**What to build:** the deterministic half of the gate stops being able to pass a diff
it never executed. After the verify command runs, verify establishes that the code
under test resolved inside the task's worktree. Resolved elsewhere is a failure, not
a pass. Undeterminable is `skipped`, never a pass.

The trap is real and was hit by hand: an editable install pins imports to a fixed
path, so running the tests inside a worktree can exercise the code from `main`. On the
run where this was found, a `pythonpath` line in the project config happened to save
it — by accident, not by design. In a project without that line the gate would have
tested the wrong tree and gone green on a diff it never touched, which is worse than
having no gate at all.

**Blocked by:** 01 — One shared test harness for the fake binaries.

**Status:** ready-for-agent

- [ ] After the verify command runs, verify establishes where the code under test
      resolved from.
- [ ] Resolution outside the worktree is reported as `fail`, not a warning.
- [ ] The failure message names the module and the path it resolved from, so an
      editable-install problem is distinguishable from a genuine test failure.
- [ ] A project where soundness cannot be established reports `skipped`, and never a
      false `pass`. Treat the detection mechanism as provisional: only one Python
      project is in evidence, and the requirement is the guarantee, not the technique.
- [ ] An environment variable disables the check, for projects where it makes no
      sense, and the disabled state is visible in the result rather than silent.
- [ ] The existing outcomes still hold: `pass` and `skipped` move a task on to the
      critique, `fail` sends it back to the agent, and the result stays cached for the
      status view.
- [ ] Verify gets its first test file, covering a sound run, an unsound one, an
      undeterminable one, and the escape hatch.
