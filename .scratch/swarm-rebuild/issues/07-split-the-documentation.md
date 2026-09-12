# 07 — Split the documentation so defining a task is findable

**What to build:** an orchestrator picking this skill up gets a thin operational
document — the operating model, the numbered flow, and a pointer from each step to the
reference it needs — instead of a single 694-line file that loads in full every time
and buries the part that matters most.

The shape of the old file is part of the original problem. Task definition lived in
three sentences at the top and one sentence beside the schema, while account swapping,
quota rules and trace mode took hundreds of lines. The most load-bearing material was
the hardest to find.

Last in the sequence, because tickets 02 to 06 each change what the references have to
say. Splitting first would mean writing them twice.

**Blocked by:** 02 — A task cannot launch without recon; 03 — The critique grades
against the pitfalls and the declared scope; 04 — Scope and size are visible before
the operator reads the diff; 05 — Verify cannot report a pass for code it never ran;
06 — A run archives its own evidence before anything is removed.

**Status:** done

- [x] The skill document is thin and operational: the operating model, the numbered
      flow, and a pointer from each step to its reference.
- [x] References cover task definition (already created in ticket 02 — extend, do not
      duplicate), models and routing, accounts and quota, the gate, and troubleshooting.
- [x] Nothing that only one step needs stays in the thin document.
- [x] Every reference is pointed at from the step that needs it, so the thin document
      stays navigable and no reference is orphaned.
- [x] Cleanup appears as an ordinary step in the flow, not an optional follow-up. The
      version of this document that shipped for months never mentioned it, and cleanup
      was done by hand as a result.
- [x] The troubleshooting reference records the traps found during this effort: the
      readiness-timeout ceiling and what herdr answers above it, prompt delivery and
      why the brief is a file, the branch a failed launch used to leave behind, the
      Windows directory lock during worktree removal, and the editable-install trap
      from ticket 05.
- [x] Model defaults follow ADR 0003, and the routing guidance matches what the code
      actually does.
- [x] The frontmatter description still states what the skill does and when to reach
      for it, since that is all the orchestrator sees before loading anything.
- [x] No behaviour changes in this ticket. It is documentation only, and the suite
      passes untouched.
