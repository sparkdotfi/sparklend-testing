# Adversarial Review Rubric

Review the test as an executable behavioral specification, not as evidence that the implementation happened to pass once. Findings come first, ordered by severity, with file and line references.

## Critical

Reject the change when any item is true:

- It changes protocol source, a submodule gitlink, lock/dependency metadata, or global configuration to make a nominally test-only patch pass.
- A green test asserts a known unsafe state as expected or avoids a pinned-core counterexample instead of reporting the protocol blocker.
- The test targets a different core revision than the repository pin or imports an API absent from the pin.
- A central safety invariant is disabled, environment-gated, tautological, or capable of passing without executing the relevant behavior.
- A stateful Pool behavior claim is supported only by pure/library arithmetic and never calls the live entry point.

Adversarial questions: What implementation defect would still pass? Would fixing the known bug make this test fail? Did the test patch silently redefine the production target?

## High

Request changes for any material false-negative or false-positive risk:

- The `.tree` is missing, stale, or inconsistent with the Solidity leaf.
- Tree nodes flatten composite setup axes or do not correspond one-to-one with modifiers in execution order.
- Revert precedence was guessed rather than traced through pre-dispatch work, action, and `ValidationLogic` in exact order.
- A success test omits complete before/after reserve, token, asset, treasury, account-data, or configuration state, including any secondary debtor, holder, or treasury claim created by setup.
- A revert does not prove state preservation or uses a bare/numeric error despite an available named exact error.
- Derived arithmetic lacks an independent hard-coded anchor, changes literal operation or rounding order, assumes a fixture helper is exact without auditing it, or confuses scaled, stored-index, normalized, and visible values.
- An assertion helper compares caller-supplied expectations without reading and checking actual protocol state.
- A tolerance has no proven source/maximum, is wider than needed, or is applied helper-wide to unrelated fields.
- Fuzz bounds omit the phase that activates the behavior, such as an index above RAY, meaningful decimals/prices, or both sides of a scaled-to-visible collapse boundary.
- An invariant swallows unexpected reverts, leaves critical success counts unenforced, or uses an unproven open holder/debtor set.
- A base-suite change was not audited across inherited entry points and empty overrides.
- A comment makes a materially false or overbroad safety, range, rounding, public-reachability, or historical claim that misstates the behavior or test scope.

Adversarial questions: Can an earlier guard mask the expected error? Can one unintended storage field change without detection? Is the oracle independent or a restatement of production code? Can every critical action have zero successes?

## Medium

Request correction unless the limitation is explicit and justified:

- Zero, first-valid, last-valid, first-reverting, max sentinel, or just-below/above cases rely on fuzz probability rather than deterministic tests.
- Failure and later recovery are serialized in one test, so the second behavior is skipped if the first changes.
- Fixture helpers based on `deal` erase pre-existing balance or allowance conditions.
- Modifier order, timestamp assumptions, reserve-factor effects, cap precision, or debt-ceiling units are implicit; elapsed time is hard-coded instead of derived from the repository fixture baseline.
- Proxy/implementation addresses, caller/owner/on-behalf semantics, or event emitter addresses are confused.
- A local test implies low-decimal or mainnet coverage while using only default 18-decimal, one-dollar mocks.
- Invariant runs/depth are shallow without deterministic reachability and focused regression tests.
- Unrelated cleanup enlarges a behavioral test patch.

Adversarial questions: Would changing the fuzzer seed remove the only boundary hit? Does one fixture default make the property vacuous? Does the test name claim a larger domain than setup covers?

## Low

Suggest improvements for maintainability and diagnosis:

- Names do not follow descriptive failure or stable numbered-success conventions.
- Comments narrate syntax rather than explain a non-obvious unit, rounding source, or unreachable branch.
- Duplicate setup should use an existing clear modifier or call seam.
- Verification reporting omits exact commands or environment-dependent skips.
- Historical attribution conflates an individual commit with inherited parent-range changes.

## Comment Review

Apply these checks to every added or changed comment; grade a failure by its semantic impact rather than treating all comment defects as low severity:

- Compare adjacent team-authored tests. Require a comment only where the reason is non-obvious: fixture/test-only seams, synthetic state, proxy/delegatecall or storage rebinding, units or rounding sources, packed configuration or bitmap constants, magic boundaries/indexes, fuzz-domain bounds, unreachable branches, or scope/public-reachability limitations.
- Verify each claim against the pinned source and exact configured domain. Challenge words such as `safe`, `always`, `above`, `below`, `cannot`, and `no public path`; a fixture observation must not become a universal range or rounding claim.
- Trace public reachability through all relevant exposed entry points before accepting a reachability claim. If the test only isolates recovery from state creation, require the comment to say that and no more.
- Check that packed constants decode the pinned layout, numeric comments identify units and actual rounding sources, fuzz-bound comments explain the retained/excluded behavior, and unreachable-branch comments name the earlier guard.
- Reject narration of syntax, names, tree prose, formulas, assertions, direct forwards, getters, and routine setup. Prefer removal when code already explains why.
- Keep historical explanations only when provenance is necessary and verified; prefer stable current-mechanism rationale.

## Acceptance Gate

A test is merge-ready only when all are true:

- The tree and test state the same externally observable behavior.
- Source tracing establishes exact caller wiring, validation/revert order, accounting transitions, units, and named error.
- Both sides of meaningful boundaries are deterministic.
- Stateful calls have complete before/after assertions, including unchanged fields, helper omissions, all setup-created claims, and affected actors' account data.
- Financial derivations preserve literal operation and rounding order, audit reused helpers, and have hard-coded anchors; tolerances are local and proven.
- Tree nodes and modifiers correspond one-to-one in execution order, and assertion helpers compare actual state.
- Time deltas preserve fixture baselines, and any pinned-core safety failure is reported as a protocol blocker rather than normalized into a green test.
- Inheritance and equivalent entry points are audited and exercised.
- Fuzz/invariant evidence is non-vacuous and complements deterministic behavior tests.
- Narrow affected tests, inherited suites, build, and broader tests were run as available, with skips explicit.
- The diff is focused and no production, dependency, configuration, or gitlink workaround is present.
- Comments are necessary why-comments, accurate for the pinned revision and stated domain, and no broader than the evidence.

If no findings remain, state that explicitly and identify residual risks such as unavailable fork RPC, unrun broad tests, or behavior outside the pinned revision.
