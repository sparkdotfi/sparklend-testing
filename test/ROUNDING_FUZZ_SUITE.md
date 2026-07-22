# SC-1569 Rounding PR — Fuzz & Invariant Suite

Test suite added to review the protocol-favoring rounding backport (PR sparklend-v1-core#12,
branch `fix/sc-1569-rounding-issue`). Targets the submodule at `lib/sparklend-v1-core`.

## Run

```bash
# Everything (fast; invariant runs are modest — see foundry.toml [invariant]):
forge test --match-contract "WadRayMathRoundingTests|RoundingInvariantTests|GhostCollateralFlagTests|LiquidationFeeDoubleRoundTests|ATokenTransferFromTests|InvariantsTest"

# A real invariant campaign:
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-path "test/invariants/*"

# Include the known-violable ghost-flag invariant (expected to fail on a deep campaign until the
# upstream bug is fixed — see notes):
CHECK_GHOST_FLAG=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-path "test/invariants/*"
```

## Files

| File | Kind | What it proves |
|---|---|---|
| `fuzz/WadRayMathRounding.t.sol` | stateless property | The four new helpers (`rayMulFloor/Ceil`, `rayDivFloor/Ceil`) are exactly floor/ceil, ceil is at most floor+1, exact division never over-rounds, overflow/div-by-zero revert. Oracle is an independent `mulmod` remainder (not the implementation's formula). Also asserts the two round-trip identities that make the dropped `_burnScaled` cap safe: `ceil(floor(s·i)/i) ≤ s` and `floor(ceil(s·i)/i) == s` for `i ≥ RAY`. |
| `fuzz/RoundingInvariants.t.sol` | stateful-ish fuzz | Supply→withdraw never returns more than deposited; borrow→repay never leaves less debt than borrowed. A standing borrow is opened in `setUp` so the fuzzed warp pushes the indices above RAY — floor/ceil rounding only diverges there. |
| `fuzz/GhostCollateralFlag.t.sol` | integration regression PoCs | Reproduces the **ghost collateral flag** through BOTH entry points — `transfer` (`finalizeTransfer`'s `balanceFromBefore == amount` check) and `withdraw` (`executeWithdraw`'s `amountToWithdraw == userBalance` check): a ceil-emptying amount below `balanceOf` zeroes the scaled balance with `isUsingAsCollateral == true` left set, the flag cannot be cleared (`UNDERLYING_BALANCE_ZERO`), and the only escape is re-supplying a non-dust amount (a 1-wei re-supply itself reverts `INVALID_MINT_AMOUNT`). All three tests are **green** — they assert the current (buggy) behavior. When the bug is fixed they will start failing at the marked assertions; that is the signal to invert them. |
| `fuzz/ATokenTransferFrom.t.sol` | integration property | Pins the **v3.5-style transferFrom allowance semantics** the new core adopts: the call gates on `allowance >= amount` but consumes `min(actual indexed balance decrease, allowance)` — so the allowance can drain up to ~`index/RAY` wei faster than the nominal amounts transferred. Also: scaled ledger moves exactly `ceil(amount/index)` and is conserved; sender loses and recipient gains within `[amount, amount + index/RAY]`. |
| `fuzz/LiquidationFeeDoubleRound.t.sol` | stateless property | Proves the liquidation **two-leg ceil overshoot**: the collateral burn (ceil) and protocol-fee transfer (ceil) are rounded separately, so `ceil(a/i)+ceil(b/i)` can exceed `ceil((a+b)/i)` and the scaled balance `S`, even when `a+b ≤ balanceOf`. The live fee clamp self-heals (no revert) but short-changes the treasury by the overshoot. |
| `invariants/handlers/LendingHandler.sol` | stateful handler | Bounded, revert-tolerant actions across N actors × M reserves: supply / withdraw / **withdraw-max** / borrow / repay / **repay-max** / aToken transfer / collateral toggle / mintToTreasury / liquidation (both `receiveAToken` modes) / time warp. The `type(uint256).max` sentinel actions matter most: full-withdraw and full-repay are where the rounding-equality seams live. Per-action attempt/success counters feed `invariant_callSummary`. |
| `invariants/InvariantsBase.t.sol` | setup | Multi-actor, multi-reserve setup with seeded liquidity and an **active borrow so the indices drift above RAY** during the campaign. Fuzzing is restricted to the handler's action selectors via `targetSelector`, which is what allows `fail_on_revert = true`. |
| `invariants/Invariants.t.sol` | invariants | `aTokenSolvency` (cash + debt ≥ aToken claims **+ unminted treasury accrual**), scaled conservation for aTokens and variable debt, `collateralFlagImpliesBalance` (ghost-flag property in stateful form, env-gated), call summary logging. |

## Notes / caveats

- The `GhostCollateralFlag.t.sol` tests are **green regression PoCs**: they assert the current (buggy)
  behavior so the suite passes and documents the open finding. When the bug is fixed, the marked
  assertions flip — the failure is then the signal that the fix landed (invert the assertions).
- The stateful `invariant_collateralFlagImpliesBalance` encodes the *desired* end-state
  (`flag => scaledBalance > 0`), which the open ghost-flag bug violates. It is therefore **gated
  behind `CHECK_GHOST_FLAG=true`** so a deep campaign doesn't turn the known finding into a
  nondeterministic CI failure. Flip it to always-on once the upstream fix lands.
- The invariant campaign uses modest defaults (`runs=32, depth=40`) for a fast smoke run; raise
  runs/depth for deeper unknown-unknown search. `fail_on_revert = true` is safe because every
  handler action is try/catch-wrapped — a revert reaching the runner means a handler bug.
- All bounds are chosen so reference arithmetic (`a*b`, `a*RAY`) cannot overflow uint256; index is
  capped at `1e6 * RAY`, far above any real reserve index.
- Suggested next additions (not yet implemented): delegated variable-borrow allowance fuzzing,
  a low-decimal (USDC/WBTC-like) asset variant (needs a parameterized-decimals refactor of
  `SparkLendTestBase`), a live-pool integration repro of the liquidation fee shortfall, and a
  sequential-liquidation dust-accumulation test.
