# Anti-Patterns From The SC-1569 History

These examples are historical warnings, not current master files. Attribution matters: `44d0db15`, `b7abd0db`, and `8358783a` form a chain based on `64d735ef`, not directly on master. The snippets below are compact excerpts from those commits.

## Defects And Assurance Regressions

### Making a known safety violation green

Commit `44d0db15`, `test/fuzz/GhostCollateralFlag.t.sol`:

```solidity
assertEq(aCollateralAsset.scaledBalanceOf(victim), 0);
assertTrue(_isCollateral(address(collateralAsset), victim));
```

This inverts the regression oracle: unsafe behavior passes and a protocol fix fails. A known-bug reproducer may be an audit artifact, but a green acceptance test must assert intended behavior. The master pattern is [`Withdraw.tree` cases 07-09](../../../../test/integration/btt/Withdraw.tree) with complete state and collateral-bit assertions in [`Withdraw.t.sol`](../../../../test/integration/btt/Withdraw.t.sol).

Selecting only inputs on the green side of a scaled-to-visible collapse boundary is the same oracle failure. Seek deterministic examples on both sides; when the safety claim fails against the pinned core, surface the protocol blocker instead of narrowing inputs, gating the check, or blessing the defect.

### Disabling the safety property

Commit `b7abd0db`, `test/invariants/Invariants.t.sol`:

```solidity
if (!vm.envOr("CHECK_GHOST_FLAG", false)) return;
```

The principal invariant disappears from normal runs. A central safety property must be always on; fix the behavior, maintain a separately identified expected-failure reproducer, or fail the campaign. Master action tests such as [`Withdraw.t.sol`](../../../../test/integration/btt/Withdraw.t.sol) always check collateral-bit outcomes.

### Treating logs as invariant coverage

Commit `b7abd0db`, `test/invariants/Invariants.t.sol`:

```solidity
console2.log(actions[i], handler.successes(actions[i]), "/", handler.attempts(actions[i]));
```

The handler also catches protocol reverts, so critical actions can have zero successes while the campaign stays green. Require minimum successful action coverage and fail on unexpected reverts. Deterministic master BTT leaves, for example [`LiquidationCall.t.sol`](../../../../test/integration/btt/LiquidationCall.t.sol), prove successful reachability before stateful exploration.

### Asserting a non-universal bound

Commit `b7abd0db`, `test/fuzz/ATokenTransferFrom.t.sol`:

```solidity
assertLe(senderLoss, transferAmount + index / RAY);
```

The same historical core had a counterexample at `index = 1.6 RAY`, `amount = 2`: sender loss was `4`, above the asserted bound `3`. The integration fixture explored only low indexes, hiding the defect. Derive a bound over the actual domain, include explicit fractional and high-index examples, and anchor them independently. [`ReserveLogic.t.sol`](../../../../test/fuzz/ReserveLogic.t.sol) grows the index repeatedly and scales a proven tolerance with index magnitude.

### Claiming integration behavior from pure arithmetic

Commit `44d0db15`, `test/fuzz/LiquidationFeeDoubleRound.t.sol`:

```solidity
uint256 scaledA = w.rayDivCeil(a, I);
uint256 scaledB = w.rayDivCeil(b, I);
assertGt(scaledA + scaledB, S);
```

This is useful arithmetic evidence, but it does not prove that `Pool.liquidationCall` reaches the state, applies a clamp, succeeds, transfers the claimed fee, or updates configuration correctly. Put action claims in the matching BTT tree and execute the live Pool path. [`LiquidationCall.t.sol`](../../../../test/integration/btt/LiquidationCall.t.sol) asserts reserve, token, asset, treasury, debt, health-factor, and user-bit state for both receipt modes.

### Hiding runner and handler defects

Commit `44d0db15`, `foundry.toml`:

```toml
[invariant]
runs = 32
depth = 40
fail_on_revert = false
```

Combined with targeting the whole handler, this can discard out-of-range getters and harness failures in a shallow campaign. Explicitly target action selectors and keep runner-level reverts fatal. `b7abd0db` correctly made both changes, although its action-level catch-all behavior and unenforced success counters remained inadequate.

### Using tautologies and incomplete liabilities

Commit `44d0db15`, `test/invariants/Invariants.t.sol`:

```solidity
assertGe(handler.callCount(), 0);
assertGe(cash + debt, claims);
```

The first cannot fail for `uint256`; the second omitted unminted scaled treasury accrual despite the nonzero reserve factor. Assertions must exclude a real bad state and include all claims under their accounting definition. [`MintToTreasury.t.sol`](../../../../test/integration/btt/MintToTreasury.t.sol) separately checks reserve accrual, treasury balance, and supply; `b7abd0db` genuinely added pending treasury entitlement to the invariant.

The same defect occurs when setup creates a secondary debtor or holder but before/after assertions cover only the primary actor, or when an assertion helper compares caller-supplied expectations without reading actual state. Include every setup-created claim and affected account data, and audit helper bodies rather than trusting their names.

### Flattening behavioral axes

A tree branch that compresses several setup modifiers into one node no longer explains which precondition creates the leaf or whether modifier execution matches the specified path. Keep tree nodes and modifiers one-to-one and in the same order; use separate nodes for separate observable axes.

### Rewriting ordered arithmetic or time

Algebraically equivalent formulas can round differently when the protocol truncates between operations, and a familiar fixture helper can encode a different order. Preserve literal source order and audit helper arithmetic. Likewise, derive elapsed-time changes from the fixture timestamp so a new test does not silently replace repository baseline assumptions with a hard-coded absolute time.

### Replacing deterministic boundaries with fuzz probability

Commit `8358783a` removed these named cases from `test/fuzz/WadRayMathRounding.t.sol`:

```solidity
assertEq(w.rayMulCeil(0, b), 0);
assertEq(w.rayDivCeil(0, b), 0);
```

A broad property may mathematically subsume zero, but a finite fuzz campaign need not select it. Keep named zero, first-valid, last-valid, and first-reverting examples beside properties. Master BTT trees such as [`Supply.tree`](../../../../test/integration/btt/Supply.tree) preserve explicit zero and one-unit boundaries.

### Serializing failure and recovery

Commit `8358783a`, `test/fuzz/GhostCollateralFlag.t.sol` merged two tests into:

```solidity
function test_ghostFlag_isUnclearableUntilResupply() public { ... }
```

If the expected failure changes, the later recovery is no longer executed, reducing independent coverage and diagnosis. Keep rejecting and successful lifecycle leaves separate, as master BTT suites do throughout [`test/integration/btt/`](../../../../test/integration/btt/).

### Duplicating numeric error payloads

Commit `44d0db15`, `test/fuzz/GhostCollateralFlag.t.sol`:

```solidity
vm.expectRevert(bytes("43"));
```

Numeric strings obscure intent and can drift from the pinned core. Import `Errors` and use `vm.expectRevert(bytes(Errors.UNDERLYING_BALANCE_ZERO))`, following [`Supply.t.sol`](../../../../test/integration/btt/Supply.t.sol) and other master BTT suites.

## Genuine Improvements In The Audited Chain

Do not report every historical edit as a defect.

- `b7abd0db` synchronized the lock revision with its already-changed gitlink, enabled `fail_on_revert`, targeted action selectors, accrued indexes above RAY, added max sentinels and action counters, included pending treasury entitlement, covered both liquidation receipt modes, and made a split-rounding property non-vacuous. These improved reproducibility and harness quality, even though counters were not enforced and central oracle problems remained.
- `b7abd0db` added transferFrom coverage. The addition was useful; the claimed universal bound and missing allowance boundaries were the defects.
- `8358783a` removed ordering assertions already implied by an exact floor/ceil identity and corrected stale documentation. Those removals were reasonable. Removing named zero boundaries and merging independent scenarios reduced assurance.

## Inherited Pre-Audit Changes

Do not attribute cumulative `master..8358783a` changes solely to the three audited commits.

- `44d0db15` has parent `64d735ef`, after five commits beyond master.
- Existing BTT rounding expectation rewrites, broad helper tolerances, `foundry.lock`, and `test/fuzz/RoundingInvariants.t.sol` were introduced in `master..64d735ef` before `44d0db15`.
- The cumulative core move is master `8120e495` to historical tip `22bab066`. `44d0db15` itself moved the gitlink only from inherited `14ff0dc9` to `22bab066`; substantive rounding behavior was already present in the inherited core line.
- Therefore broad BTT tolerance changes are relevant review risks at the historical tip, but not authored defects of `44d0db15`, `b7abd0db`, or `8358783a`.

The transferable rule is to inspect ancestry, individual commit diffs, and the parent-to-master range before assigning provenance.
