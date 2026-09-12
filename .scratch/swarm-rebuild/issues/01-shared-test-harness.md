# 01 — One shared test harness for the fake binaries

**What to build:** a maintainer changing how the swarm talks to herdr fixes the fake
herdr once, not in every test file. The fake `herdr`, `agy` and `pwsh` binaries and
the assertion helpers live in a single harness that each test file sources; the
suite behaves exactly as it does today.

This is a prefactor. Every ticket after it adds assertions, and adding them to four
divergent copies of the fakes is the maintenance drag this effort is partly about —
the same argument the skill already applies to its own scripts: when herdr changes,
fix one file, not four.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] One harness provides the fake `herdr`, `agy` and `pwsh` binaries and the
      assertion helpers, and puts the fakes ahead of the real ones on `PATH`.
- [ ] A test file can override or extend a single fake for one scenario without
      copying the whole set, since the cleanup tests already swap the fake herdr
      mid-file and the critique tests need a different `agy`.
- [ ] All four existing test files source the harness and define no fakes of their
      own beyond such scenario overrides.
- [ ] Every assertion that exists today still exists, unchanged in what it asserts,
      and the whole suite passes. A changed assertion is out of scope for this
      ticket: the proof this refactor is correct is that nothing about the tests'
      meaning moved.
- [ ] The harness still isolates every run from the real machine: no real herdr, no
      real credential vault, no writes into the operator's repos or brief directory.
