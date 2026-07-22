# SC-1569 Rounding PR — Fuzz & Invariant Suite

Test suite added to review the protocol-favoring rounding backport (PR sparklend-v1-core#12,
branch `fix/sc-1569-rounding-issue`). Targets the submodule at `lib/sparklend-v1-core`.

## Run

```bash
# Everything (fast; invariant runs are modest — see foundry.toml [invariant]):
forge test --match-contract "WadRayMathRoundingTests|GhostCollateralFlagTests|LiquidationFeeDoubleRoundTests|InvariantsTest"

# A real invariant campaign:
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-path "test/invariants/*"
```

## Files

| File | Kind | What it proves |
|---|---|---|
| `fuzz/WadRayMathRounding.t.sol` | stateless property | The four new helpers (`rayMulFloor/Ceil`, `rayDivFloor/Ceil`) are exactly floor/ceil, ceil is at most floor+1, exact division never over-rounds, overflow/div-by-zero revert. Oracle is an independent `mulmod` remainder (not the implementation's formula). Also asserts the two round-trip identities that make the dropped `_burnScaled` cap safe: `ceil(floor(s·i)/i) ≤ s` and `floor(ceil(s·i)/i) == s` for `i ≥ RAY`. |
| `fuzz/GhostCollateralFlag.t.sol` | integration regression PoCs | Reproduces the **ghost collateral flag**: a transfer that ceil-empties the scaled balance while `amount != floor(balanceOf)` leaves `isUsingAsCollateral == true` on a zero balance, that flag cannot be cleared (`UNDERLYING_BALANCE_ZERO`), and the only escape is re-supplying a non-dust amount (a 1-wei re-supply itself reverts `INVALID_MINT_AMOUNT`). All three tests are **green** — they assert the current (buggy) behavior. When the bug is fixed they will start failing at the marked assertions; that is the signal to invert them. |
| `fuzz/LiquidationFeeDoubleRound.t.sol` | stateless property | Proves the liquidation **two-leg ceil overshoot**: the collateral burn (ceil) and protocol-fee transfer (ceil) are rounded separately, so `ceil(a/i)+ceil(b/i)` can exceed `ceil((a+b)/i)` and the scaled balance `S`, even when `a+b ≤ balanceOf`. The live fee clamp self-heals (no revert) but short-changes the treasury by the overshoot. |
| `invariants/handlers/LendingHandler.sol` | stateful handler | Bounded, revert-tolerant actions: supply / withdraw / borrow / repay / aToken transfer / liquidation / time warp across N actors × M reserves. |
| `invariants/InvariantsBase.t.sol` | setup | Multi-actor, multi-reserve setup with seeded liquidity and an **active borrow so the indices drift above RAY** during the campaign (the pre-existing `fuzz/RoundingInvariants.t.sol` runs entirely at `index == RAY`, where floor/ceil never diverge — this harness deliberately does not). |
| `invariants/Invariants.t.sol` | invariants | `aTokenSolvency` (cash + debt ≥ aToken claims), scaled conservation for aTokens and variable debt, `collateralFlagImpliesBalance` (ghost-flag property in stateful form), call summary. |

## Notes / caveats

- The `GhostCollateralFlag.t.sol` tests are **green regression PoCs**: they assert the current (buggy)
  behavior so the suite passes and documents the open finding. When the bug is fixed, the marked
  assertions flip — the failure is then the signal that the fix landed (invert the assertions).
- The stateful `invariant_collateralFlagImpliesBalance` encodes the *desired* end-state
  (`flag => scaledBalance > 0`). It passes the modest smoke campaign; a sufficiently deep campaign may
  surface the known ghost-flag violation — that is expected until the bug is fixed, not a regression.
- The invariant campaign uses modest defaults (`runs=32, depth=40`) for a fast smoke run. The ghost-flag
  window is narrow; a short campaign may not hit it — the dedicated PoC covers it deterministically.
  Raise runs/depth for deeper unknown-unknown search.
- All bounds are chosen so reference arithmetic (`a*b`, `a*RAY`) cannot overflow uint256; index is
  capped at `1e6 * RAY`, far above any real reserve index.
- Suggested next additions (not yet implemented): delegated variable-borrow allowance fuzzing,
  `AToken.transferFrom` allowance-consumption fuzzing, an 8-decimal (WBTC-like) asset variant, and a
  live-pool integration repro of the liquidation fee shortfall.
```
