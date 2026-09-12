# 03 — The critique grades against the pitfalls and the declared scope

**What to build:** the cheap reviewer stops judging a diff on overall impression. It
receives each declared pitfall as a criterion and the declared file list as a scope
criterion, and its verdict records which pitfalls it actually examined — so a `pass`
tells the operator what was checked instead of being a bare word.

The reason this matters is on record: a diff where a translated comment stopped
describing the code one line below it came back `pass` with `confidence: high` and
the justification "completely and correctly implemented". The reviewer had nothing
specific to look for. Naming the traps gives it something measurable.

Nothing here changes what the gate *means*. It filters; it does not approve.

**Blocked by:** 02 — A task cannot launch without recon.

**Status:** done

- [x] The reviewer's brief lists each declared pitfall as a criterion to judge the
      diff against.
- [x] The reviewer's brief states the declared scope and asks it to flag every change
      outside it, saying for each whether it was necessary.
- [x] The verdict records which pitfalls were examined, so a later reader can tell a
      thorough pass from a shallow one.
- [x] A diff that ignores a named pitfall produces a verdict that says which one.
- [x] The existing verdict fields and the truncation behaviour for large diffs keep
      working, and a truncated diff still lowers confidence rather than silently
      grading on what fitted.
- [x] The rule that the critique never approves a merge is unchanged in both the code
      and the documentation.
- [x] Tests assert that the pitfalls and the scope reach the reviewer, and that the
      verdict records the pitfalls examined.
