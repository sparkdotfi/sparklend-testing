# Invariant Suite Review — `test/invariants/`

**Scope:** correctness of `Invariants.t.sol` + `handlers/PoolHandler.sol` (working tree), and comprehensiveness
measured against the proposed upgrade: `lib/sparklend-v1-core` `v1.0.0 → dev` (commit `52c367b8`,
"Fix: Rounding Issue (SC-1569)").

**Method:** every helper was verified line-by-line against the dev-commit protocol source
(`GenericLogic`, `ValidationLogic`, `LiquidationLogic`, `SupplyLogic`, `PoolLogic`, `ReserveConfiguration`,
tokenization contracts). The suite was executed at default config (48×100) and extended (150×200);
both pass with 0 reverts across ~32,000 handler calls.

**Upgrade blast radius (what the suite must be able to break):**
directional rounding on aToken mint (scaled ⌊⌋) / burn (⌈⌉) / `balanceOf`+`totalSupply` (⌊⌋);
variable debt mint (⌈⌉) / burn (⌊⌋) / `balanceOf`+`totalSupply` (⌈⌉); scaled transfer (⌈⌉);
rewritten aToken `approve`/`transferFrom`/`_spendAllowance` (consumes actual balance decrease, capped);
index-aware credit-delegation `_decreaseBorrowAllowance`; HF math rounding against the user in
`GenericLogic` (collateral ⌊⌋, debt ⌈⌉ + `_divCeil`); reordered collateral-flag clear and
`rayDivCeil`/`rayMulFloor` protocol-fee guard in `LiquidationLogic`; `mintToTreasury` dust guard in
`PoolLogic`; `executeWithdraw` balance ⌊⌋; contract revision bumps.

---

## High — helper bugs that can fail the suite spuriously (`fail_on_revert = true`)

### H-1. `_getMaxWithdrawable` floors the minimum-collateral division; must ceil
`PoolHandler.sol:416` — `minCollateralRequiredBase = (totalDebtBase * 10_000) / currentLiquidationThreshold`
rounds **down**, underestimating required collateral. The protocol's post-withdraw check
(`SupplyLogic.executeWithdraw` → `validateHFAndLtv` → `validateHealthFactor`, ValidationLogic.sol:571)
requires HF ≥ 1e18 where debt is now valued with `rayMulCeil` + `_divCeil` and collateral with
`rayMulFloor` (GenericLogic.sol:232, 237, 256–263). A max-value withdraw can therefore overshoot the
true HF = 1 point by ~1 base unit and revert with error 35, killing the campaign. Foundry's `_bound`
is edge-biased, so `amount == maxWithdrawable` is drawn with real probability. Empirically 0 hits in
~5,400 withdraw+transfer calls, but the exposure is structural.
**Fix:** ceil the division and subtract a ~2-base-unit margin for burn-⌈⌉/floor-valuation slippage —
or compute the max `w` such that `percentMul(C − w·price, avgLT) ≥ D` directly.
**Propagates to `transfer`** (`PoolHandler.sol:242`): `executeFinalizeTransfer` runs the identical check.
Also used by `_drainLiquidity` (`Invariants.t.sol:240`), so `afterInvariant` shares the exposure.

### H-2. `borrow` and `_getMaxWithdrawable` never bound by reserve cash
`PoolHandler.sol:162–166` bounds only by `availableBorrowsBase` (user-side); `PoolHandler.sol:404`
bounds only by balance/HF. Neither caps at `IERC20(asset).balanceOf(aTokenAddress)`. If actors'
aggregate borrows/withdrawals drain a reserve past the 5M bootstrap seed, the underlying transfer
underflows in MockERC20 → campaign failure. Low probability at current weights (supply keeps adding
cash; 0 hits empirically), but it is the one realistic `fail_on_revert` gap left open and it gates any
future re-weighting toward a high-utilization regime — which is exactly the regime where index growth
makes rounding interesting. **Fix:** `min(candidate, cash)` in both places (as `_drainLiquidity` already
does at `Invariants.t.sol:242`).

## High — comprehensiveness gaps vs the upgrade

### G-1. Rewritten aToken allowance machinery never exercised
`AToken.transferFrom` / `approve` / `increaseAllowance` / `decreaseAllowance` / `_spendAllowance`
(AToken.sol, dev) are entirely new code — allowance consumption is measured from the owner's **actual
rebased balance decrease** (which exceeds the requested amount under ⌈⌉ scaled-transfer rounding) and
capped at the current allowance. The handler only calls `transfer`. No fuzz pressure at all on:
allowance-consumed vs balance-moved consistency, the cap branch, `ERC20InsufficientAllowance`
boundaries, infinite-allowance behavior (note: dev has **no** `type(uint256).max` skip — a max
allowance is decremented). **Add a `transferFrom` action** with an `approve`d spender actor and assert
`allowanceBefore − allowanceAfter == senderBalanceDecrease` (capped), plus the same ±wei bounds as
`transfer`.

### G-2. Credit delegation (`borrow` onBehalfOf) never exercised
`VariableDebtToken._decreaseBorrowAllowance` (dev) is new index-aware logic mirroring G-1 on the debt
side (consumes the delegator's actual rebased debt increase, capped). Every handler borrow is
self-borrow (`PoolHandler.sol:174`). The new `test/integration/DelegationWithSig.t.sol` covers the
happy path, but the rounding interaction under a moving index is precisely invariant-suite territory.
**Add a delegated-borrow action** (`approveDelegation` + borrow with `onBehalfOf != msg.sender`).

### G-3. Liquidation protocol fee is 0 → changed fee lines are dead code
`SparkLendTestBase` never calls `setLiquidationProtocolFee` (grep: no hits), so
`LiquidationLogic.sol:205–212` — the upgrade's `rayDivCeil(fee, index)` / `rayMulFloor` clamp against
the user's scaled balance, and the `transferOnLiquidation` to treasury — **never execute** in this
suite. The clamp exists precisely to fix a 1-wei-imprecision revert; it is unreachable here.
**Fix:** configure a nonzero fee (e.g. 10_00) in setUp. The treasury is already in the holder set
(`Invariants.t.sol:297`), so conservation invariants keep working.

### G-4. Same-asset liquidation explicitly excluded
`PoolHandler.sol:316` — `vm.assume(collateralAsset != debtAsset)`. The upgrade moved the
collateral-flag clear from before `_burnDebtTokens` + `updateInterestRates` to after
(LiquidationLogic.sol:166–195 diff). The interaction between debt-side state changes and
collateral-side flag/rate state is tightest when both reserves are the same one. Excluding it removes
the scenario most sensitive to the reorder. **Fix:** drop the assume (users borrowing their own
collateral asset is a valid SparkLend state) and let `_getTopPositions` return equal assets.

## Medium

### M-1. LTV boundary structurally unreachable in `borrow`
`PoolHandler.sol:164–166` — `vm.assume(maxBorrowable >= 100e18)` plus a `−10e18` buffer leaves ≥10
whole tokens (10e8 base units) of headroom. The interesting edge — `percentDiv(debt + amount, ltv) <=
collateral` (ValidationLogic.sol:260–266) not being an exact inverse of `percentMul` in
`calculateAvailableBorrows` — can differ by ~1 base unit, and the buffer is 9 orders of magnitude
larger. For a rounding-upgrade suite this is the wrong trade. **Fix:** shrink the buffer to a few base
units (~2e10 asset wei) and lower the 100e18 floor, accepting occasional discards.

### M-2. Full-liquidation equality branch and `liquidate` post-state unasserted
The moved branch fires only when `actualCollateralToLiquidate + fee == userCollateralBalance`
(LiquidationLogic.sol:186–193). With fee = 0 and the handler capping `amount` by
`_getMaxDebtToCover` (collateral-affordability), full-collateral seizure is hit only via the 10%
overshoot branch and never verified. `liquidate` (`PoolHandler.sol:303`) asserts **nothing**:
no bounds on collateral seized vs `debt·price·bonus`, debt burned vs amount, HF direction, or the
collateral-flag clear. Given liquidation is the most state-heavy action and got the ordering change,
add: seized-collateral ±wei bounds, debt-token burn bounds (mirroring `repay`), and
`isUsingAsCollateral == false` iff balance hit zero.

### M-3. Solvency invariant blind to ≤ ~2 wei/asset of insolvency
`Invariants.t.sol:135–139` compares rebased view values: variable-debt `totalSupply` now rounds **⌈⌉**
(overstating assets by <1 wei) and aToken `totalSupply` rounds **⌊⌋** (understating claims by <1 wei),
plus half-up `rayMul` on the treasury claim. A steady-state leak of 1–2 wei per asset — exactly the
magnitude this upgrade manipulates — passes forever. **Fix:** also assert solvency in scaled terms,
e.g. `cash ≥ scaledClaims.rayMulCeil(liqIndex) + treasuryClaimCeil − scaledDebt.rayMulFloor(borrowIndex)`,
so every rounding direction is adversarial to the protocol.

### M-4. `repayWithATokens` not covered
`Pool.sol:305` exists in this version and composes both changed burn paths in one call
(aToken burn ⌈⌉ + debt burn ⌊⌋ against the same actor, no underlying transfer). Cheap to add and a
natural place for rounding asymmetry to net against the protocol.

### M-5. Only 18-decimal assets
`SparkLendTestBase.sol:173–174`. Production SparkLend lists 6- and 8-decimal reserves (USDC, USDT,
WBTC), and the upgrade's `_divCeil` in `GenericLogic` operates per base unit — dust significance
scales with `assetUnit`. Handler math hardcodes `1e18` throughout (`PoolHandler.sol:162, 425, 451,
523, 538, 579`), so this is a structural limitation, not a tweak. Reasonable to defer, but note that a
6-decimal reserve is where 1-wei base-currency rounding is most valuable relative to position size.

### M-6. `_getMaxWithdrawable` ignores the collateral flag → dead coverage
`SupplyLogic.executeWithdraw` only runs the HF check when the asset is enabled as collateral **and**
the user borrows (SupplyLogic.sol:132, 146). After `setCollateral(disable)` (weight 20, so common),
the full balance is withdrawable regardless of debt — but the helper still clamps to account-level
excess, so the "withdraw everything of a non-collateral asset while indebted" path is never exercised.
Same for `transfer`.

## Low / latent (inert under current config — document or fix before config changes)

- **L-1. Index ≤ 5e27 tolerance assumption unenforced.** The ±5-wei bounds
  (`PoolHandler.sol:117, 153, 183, 231, 276`) assume `index ≤ 5e27`. Realized campaigns reach
  ~2.1e27 (≈1.7 sim-years at ≤37% APR), but the tail (~8 sim-years) reaches ~20e27. Assert
  `liquidityIndex/variableBorrowIndex ≤ 5e27` in `invariant_full`, or scale tolerances by
  `index / 1e27`, so a breach surfaces as the assumption failing rather than a mystery wei flake.
- **L-2. `afterInvariant` treasury assert protected only incidentally.** The dev-commit dust guard
  (`PoolLogic.sol:104–106`) skips minting iff `accruedToTreasury == 1` scaled wei and
  `index mod 1e27 ∈ (0, 0.5e27)` — leaving it nonzero and failing `Invariants.t.sol:193`. It passes
  today only because `_repayAllDebt` re-books a large reserve-factor cut off bootstrap's ≥500k debt
  before the final mint. If the bootstrap borrow shrinks, this becomes a coin-flip flake. Use
  `assertLe(accrued, 1)` or comment the dependency.
- **L-3. Flash-loan receivers depend on premium = 0.** `MockReceiverBasic` holds no funds and only
  approves; `_flashLoanPremiumTotal` defaults to 0 and is never set. Any future nonzero premium makes
  every flash loan revert. The flash-loan actions also assert nothing (premium accrual to
  `accruedToTreasury` untested). Worth a comment + funding the receivers.
- **L-4. `_getMaxWithdrawable` treats avg liquidation threshold as constant.** Correct only because
  both assets share LT = 75_00; with heterogeneous LTs, withdrawing the high-LT asset lowers the
  average and the helper over-permits → revert. Fix before adding a third asset.
- **L-5. `_canDisableCollateral` latent edges.** `assetLiquidationThreshold == 0 → true`
  (`PoolHandler.sol:444`) is wrong for an underwater user (the disable path always runs
  `validateHFAndLtv`); strict `>` at `PoolHandler.sol:473` means the HF-exactly-1.0 disable — a prime
  rounding boundary — is never attempted (protocol accepts `>=`, ValidationLogic.sol:571); no check
  that the asset is currently enabled (disable of a disabled asset is a valid no-op, currently
  discarded). None can fail the suite today.
- **L-6. Price clamp [0.7e8, 1.3e8] in ±10% steps** (`PoolHandler.sol:385`) precludes crash scenarios
  and deep bad debt; combined with G-4's assume, post-liquidation residual-dust states are mild.
  Acceptable for a rounding campaign, but worth knowing when interpreting "suite passes".
- **L-7. Uncovered minor entry points:** `withdraw(to != self)`, `supply`/`repay` `onBehalfOf`,
  `supplyWithPermit`/`repayWithPermit`, eMode (`setUserEMode` — SparkLend mainnet has an active ETH
  eMode and the `GenericLogic` rounding changes apply under eMode pricing), stable-rate actions
  (`swapBorrowRateMode`, `rebalanceStableBorrowRate` — acceptable: stable borrowing is disabled on
  SparkLend, but the invariant already reads stable-debt supply, which is fine).

## Verified correct (checked against dev-commit source; no action)

- **Rounding-tolerance assertions** in `supply`/`withdraw`/`borrow`/`repay`/`transfer`: directions and
  ±5 bounds all re-derived and correct under the **new** rounding modes (mint ⌊⌋ / burn ⌈⌉ / debt mint
  ⌈⌉ / debt burn ⌊⌋ / transfer ⌈⌉, balances ⌊⌋ aToken, ⌈⌉ debt), given index ≤ 5e27 (see L-1).
- **`_getMaxDebtToCover`:** close-factor threshold and strict `>` match
  `LiquidationLogic.sol:375–377` exactly (0.95e18 / 5_000 / 10_000); stable+variable debt inclusion
  matches `_calculateDebt`; collateral-affordability formula is the exact inverse of
  LiquidationLogic.sol:500–503 at equal 18 decimals; ignoring the protocol fee is correct (fee is
  carved from the liquidator's collateral, not `debtAmountNeeded`); rounding slack is harmless because
  `liquidationCall` clamps oversized `debtToCover` rather than reverting.
- **Bit extraction:** LT bits 16–31 and bonus bits 32–47 match `ReserveConfiguration.sol:14–15`.
- **`_getTopPositions` / `_getAssetStatus`:** bitmap decoding via `reserve.id` +
  `UserConfiguration` is exactly the protocol's own scheme; `isCollateral` requirement matches
  `validateLiquidationCall`.
- **`_canDisableCollateral` core math:** `balanceOf·price/1e18` floor exactly matches
  `_getUserBalanceInBaseCurrency` (aToken `balanceOf` now floors identically); never returns a false
  "yes" (floor + strict `>` ⇒ protocol HF' > 1e18).
- **`borrow` post-assert `HF ≥ 1e18`:** safe in this config (LT/LTV = 7500/7000 forces post-borrow
  HF ≳ 1.07e18); note it is config-dependent — with LT == LTV and no buffer it could legitimately fail
  by one rounding unit.
- **`setPrice` bounds:** `min > max` unreachable; price never 0.
- **`deal` on MockERC20**, closed holder set (actors + bootstrap + treasury; flash receivers and
  handler never hold aTokens), `withdraw`-max / `repay`-max branches, `_generateSelectors` weighting,
  monotone-index checks and the `afterInvariant` wind-down sequence (drain → repay → mint → full exit)
  are all sound. `aToken.balanceOf` as the withdraw upper bound is exact — it floors identically to
  the `userBalance` that `executeWithdraw` validates against (`SupplyLogic.sol:118–120`).

## Post-review addendum — deep campaign result (2026-08-07)

After landing H-1, H-2, M-1, G-1, G-3, G-4, and L-1, a 1000×200 campaign **violated the solvency
invariant** (~139e18 shortfall), shrunk to `supply → borrow → withdraw → liquidate`. Diagnosis in
`Repro.t.sol`: a **same-asset liquidation** (enabled by G-4) runs `updateInterestRates` twice on the
same reserve; the second call (`_burnCollateralATokens`, LiquidationLogic.sol:258) omits the
`actualDebtToLiquidate` repayment inflow (transferred only afterwards, LiquidationLogic.sol:221), so
the stored liquidity rate overpays suppliers until the next rate update. Reproduced **identically on
v1.0.0** — pre-existing, not an SC-1569 regression, so it does not block the upgrade; it should be
assessed and reported separately. Same-asset borrow-against-collateral is a live state on production
SparkLend, and the leak recurs on every same-asset liquidation (size scales with reserve debt and
the time until the reserve's next rate update).

**Correction to M-3:** the proposed scaled-terms solvency assert is withdrawn. Per-user collectible
debt (sum of per-holder ⌈⌉) exceeds the ⌈⌉ of the total, and per-user payable claims (sum of ⌊⌋)
are below the ⌊⌋ of the total, so the existing view-based check is already *stricter* than
operational solvency — as the campaign result demonstrates, it detects real leaks.

## Suggested priority

1. H-1 (ceil fix — one line, removes the main spurious-failure risk)
2. H-2 (cash caps — two lines)
3. G-3 (nonzero liquidation protocol fee — makes dead upgrade code live)
4. G-1, G-2 (transferFrom + delegated-borrow actions — the largest untested new surface)
5. G-4 (drop same-asset assume), M-2 (liquidation assertions), M-3 (scaled solvency)
6. M-1 (borrow boundary), L-1/L-2 (tolerance + treasury-assert hardening)
