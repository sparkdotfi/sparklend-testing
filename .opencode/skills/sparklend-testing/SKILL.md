---
name: sparklend-testing
description: Author, debug, or review SparkLend Foundry tests in this repository, including BTT action suites, fuzz and invariant campaigns, ACL and fork tests, exact protocol reverts, indexed accounting, and rounding-sensitive assertions. Use whenever work changes or evaluates tests, fixtures, mocks, or test-facing helpers for SparkLend behavior.
---

# SparkLend Test Authoring

Treat this repository as an assurance harness for the protocol revision pinned under `lib/`, not as a place to patch protocol behavior until a test passes.

## Required Reading

Before authoring, read:

- [Repository principles](references/repository-principles.md)
- [Authoring workflow](references/authoring-workflow.md)

When reviewing or revising an existing test, also read:

- [Anti-patterns](references/anti-patterns.md)
- [Review rubric](references/review-rubric.md)

## Operating Rules

1. Start with the matching `.tree`; map each behavioral node one-to-one to setup modifiers in the same order rather than flattening composite axes.
2. Trace the pinned source in literal execution order from the Pool entry point through action, validation, reserve accounting, token accounting, math, and named errors.
3. Specify both sides of every meaningful boundary, including scaled-to-visible collapse boundaries, and the exact first reachable revert.
4. For every stateful success, assert complete relevant state before and after the call, including account data and every secondary debtor, holder, or treasury claim created by setup.
5. Derive financial expectations in literal protocol operation and rounding order, audit fixture helpers instead of assuming equivalence, and pin representative results independently. Prefer equality; prove and localize any tolerance.
6. Ensure assertion helpers read and compare actual state; caller-supplied expected values cannot validate one another.
7. Derive time deltas from the fixture timestamp while preserving the repository baseline unless the behavior intentionally changes it.
8. Audit inherited equivalent entry points and empty overrides whenever a shared base suite changes.
9. Keep fuzz properties narrow and deterministic boundaries explicit. Require invariant actions and safety properties to execute meaningfully rather than pass vacuously.
10. Verify from narrow to broad and report exactly what ran.

Do not modify protocol code, submodule gitlinks, dependency metadata, or global test configuration as a workaround for a test. If the intended safety property fails on the pinned core, surface the protocol blocker; do not choose only green inputs, gate the property, or assert the defect as expected behavior. A different protocol revision is a separate protocol/dependency change.
