# Authoring Workflow

## 1. Establish The Target

1. Read the request and identify whether it is test-only, test plus fixture, or an explicit protocol qualification task.
2. Run `git status --short` and `git submodule status`. Record the active core pin and preserve unrelated worktree changes.
3. Reject protocol/gitlink workarounds. Do not edit `lib/`, a submodule pin, dependency metadata, `foundry.toml`, or production source merely to compile or green a test. Surface a revision mismatch as a separate change.
4. Decide local, fork, ACL, focused fuzz, stateful invariant, or BTT integration placement from the observable claim. Stateful Pool action behavior belongs in BTT, even if fuzz inputs supplement it.

## 2. Design The Tree First

1. Open the matching `.tree` and adjacent suite.
2. Add or revise the tree branch before Solidity. Preserve rejecting branches first and success leaves second.
3. Mirror the protocol's exact revert order, not a convenient test order. Keep each failure leaf tied to the first reachable failure along the actual call path.
4. Enumerate meaningful axes and boundaries: zero, first valid, just below/at/above limits, explicit full amount, `type(uint256).max`, same block versus elapsed time, caller versus beneficiary, fee/receipt mode, and relevant reserve flags.
5. Keep an expected revert and subsequent successful recovery as independent leaves. Keep stable numeric labels unless the tree changes.
6. Give each behavioral axis its own tree node and matching modifier in the same execution order. Do not flatten several modifier-controlled preconditions into one composite node.

## 3. Trace Source Semantics

For each leaf, write a short scratch trace before implementing:

1. Tree and existing suite setup/modifiers.
2. Fixture actors, assets, prices, rates, timestamp, helper implementations, and side effects.
3. Pool entry point, including permit or receiver work before dispatch and caller/account parameter wiring.
4. Action library in execution order: cache, update state, validate, token operation, user bits, rates, transfer, and event.
5. Every reached `ValidationLogic` check in literal order to establish exact revert precedence.
6. Reserve cache, lazy indexes, treasury accrual, and rate inputs.
7. Data/configuration units and omitted helper fields.
8. Token scaled storage versus normalized visible values and only-Pool boundaries.
9. Named `Errors` constant or justified panic/opaque revert.
10. Math operations in literal source order, including every intermediate rounding step; do not replace them with algebraic simplifications or assumed-equivalent fixture helpers.

Do not implement until the expected caller, error, units, state transitions, and rounding direction are explicit.

## 4. Build The Scenario

1. Reuse `SparkLendTestBase` and existing modifiers where they express the tree path clearly.
2. Respect modifier order. Use setup that reaches the branch without accidentally triggering an earlier guard.
3. Avoid `_supply` and `_repay` when replacement-by-`deal` would destroy the balance or allowance condition under test.
4. Make index, price, decimal, utilization, role, and time preconditions observable with assertions. A rounding test must move away from identity at `RAY` when required.
5. Use local fixtures for controlled exhaustive accounting. Keep fork tests pinned and isolate state between cases.
6. Derive elapsed-time warps from the fixture timestamp and preserve the repository baseline unless the leaf intentionally varies that baseline.

## 5. Specify Full Before/After State

For every successful stateful test:

1. Construct expected reserve, underlying asset, aToken, debt token, and actor state. Include every secondary debtor or holder created by setup and every minted or pending treasury claim.
2. Assert complete relevant state before the action.
3. Assert user configuration, account data for every affected actor, isolation debt, treasury, or other fields omitted by shared helpers.
4. Execute one behaviorally meaningful action.
5. Mutate only fields expected to change.
6. Assert the same complete state afterward, including unchanged fields.
7. Add event checks only as supplementary evidence and target the proxy emitter; never replace accounting assertions with events.
8. Audit assertion helpers to confirm they query actual protocol state. Never let a helper compare only expectations supplied by its caller.

For a revert, assert the exact error and prove preservation of every state item the attempted call could have touched.

## 6. Anchor Arithmetic

1. Label units at each step: token decimals, `1e8` price, basis points, wad, ray, or debt-ceiling precision.
2. Derive expected values independently from scenario inputs while preserving each protocol operation and intermediate rounding in literal order; audit existing fixture helpers before reusing their arithmetic.
3. Assert representative derived results against hard-coded constants. A helper-derived value alone can repeat the implementation's bug; a constant alone is hard to audit.
4. Prefer exact equality.
5. If approximation is unavoidable, enumerate each rounding source, prove the maximum cumulative deviation, use the smallest bound, and apply it only to affected assertions. Never pass a broad helper-wide tolerance for convenience.

## 7. Add Fuzz Or Invariants Deliberately

For fuzz tests:

- Keep named deterministic zero, identity, boundary, overflow, and counterexample cases.
- Bound inputs to meaningful protocol domains, including non-identity index phases, relevant decimals/prices, and both sides of scaled-to-visible collapse boundaries.
- Use an independent oracle and hard-coded examples. Do not generalize a fixture observation into a universal bound.
- If the intended property fails on the pinned core, preserve the counterexample and report a protocol blocker. Do not constrain it away, gate it off, or redefine the unsafe result as expected.

For invariant tests:

- Define always-on properties that can fail.
- Prove holder/debtor sets are closed across transfers, treasury, and liquidation recipients.
- Make critical actions deterministically reachable and enforce minimum successful counts.
- Separate expected protocol rejection from unexpected handler or runner failure; do not swallow all reverts.
- Include max sentinels and multi-action sequences deliberately.
- Use sufficient CI depth/runs only after deterministic reachability; deep optional campaigns supplement rather than define assurance.

## 8. Audit Inheritance

Whenever a base BTT suite or virtual call seam changes:

1. Search for every inheritor and override.
2. Inspect `Deposit.t.sol`, permit variants, flash-loan equivalence suites, and any other matching subclasses.
3. Review empty overrides: a previously inapplicable base test may now need entry-point-specific behavior.
4. Confirm inherited modifiers, setup, caller semantics, and names remain correct.
5. Run inherited contracts, not only the edited base contract.

## 9. Verify Narrow To Broad

Run the smallest useful command first, then expand as available:

```bash
forge test --match-test test_name
forge test --match-contract ContractName
forge test --match-path 'test/integration/btt/Action*.t.sol'
forge build --sizes
forge test
```

Use the repository's actual affected globs and inherited suite names. Run fork tests separately only when an archive-capable `MAINNET_RPC_URL` is available. Do not hide failures by changing protocol pins, exclusions, tolerances, or runner settings.

Before reporting:

- Inspect `git diff --check`, `git diff`, and `git status --short`.
- Confirm only intended files changed and no gitlink moved.
- State every command run, result, skipped fork/environment-dependent suite, and unresolved semantic concern.
