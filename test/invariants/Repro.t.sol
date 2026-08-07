// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { Invariants, IERC20Like } from "./Invariants.t.sol";

import { PoolHandler } from "./handlers/PoolHandler.sol";

// Deterministic reproduction of the solvency violation found by the deep invariant campaign
// (seed 0xcfd0fee6d1b30c6857be18e0ebe7126d4166fb7aedbe4b8e5cefeb5b2dac7c78, shrunk to 4 calls).
//
// Diagnosis: a SAME-ASSET liquidation (collateralAsset == debtAsset) runs updateInterestRates
// twice on the same reserve. The second call, in _burnCollateralATokens (LiquidationLogic.sol:258),
// passes liquidityAdded = 0 even though the actualDebtToLiquidate repayment has not been
// transferred in yet, so the final stored rates are computed with the repayment inflow missing.
// Utilization is overstated, the liquidity rate is set too high, and suppliers accrue more than
// borrowers pay until the next rate update on the reserve. The banked over-accrual is permanent:
// claims end up exceeding cash + debt (~139e18 here) once the pending treasury cut is booked.
//
// Reproduces identically on v1.0.0 (8120e495) and dev (52c367b8): pre-existing, NOT an SC-1569
// regression. This test logs solvency per phase; the assertion failure is reproduced by
// `forge test --rerun` on the persisted invariant failure.
contract Repro is Invariants {

    function test_repro() external {
        PoolHandler h = PoolHandler(handler);

        _logSolvency("setup");

        h.supply(1482, 3310320825693834878031106126994747573156740734305952437150468478, 115792089237316195423570985008687907853269984665640564039457584007913129639933);
        _logSolvency("supply");

        h.borrow(2, 385185075447232183695393360103624760, 115792089237316195423570985008687907853269984665640564039457584007913129639932);
        _logSolvency("borrow");

        h.withdraw(12, 12932, 13);
        _logSolvency("withdraw");

        h.liquidate(19080357301781217307366360897142665269091278952487306711008511969021706590707, 611602966, 6, false);
        _logSolvency("liquidate");

        // Mirror afterInvariant() step by step to find where solvency breaks.
        skip(30 days);
        _logSolvency("skip-a");

        pool.mintToTreasury(assets);
        _logSolvency("mint-1");

        skip(30 days);
        _logSolvency("skip-b");

        _drainLiquidity();
        _logSolvency("drain");

        skip(30 days);
        _logSolvency("skip-c");

        _repayAllDebt();
        _logSolvency("repay");

        skip(30 days);
        _logSolvency("skip-d");
    }

    function _logSolvency(string memory label) internal view {
        for (uint256 i; i < assets.length; ++i) {
            address asset  = assets[i];
            address aToken = pool.getReserveData(asset).aTokenAddress;
            address vDebt  = pool.getReserveData(asset).variableDebtTokenAddress;

            uint256 cash    = IERC20Like(asset).balanceOf(aToken);
            uint256 debt    = IERC20Like(vDebt).totalSupply();
            uint256 claims  = IERC20Like(aToken).totalSupply();
            uint256 accrued = uint256(pool.getReserveData(asset).accruedToTreasury);

            console.log(label, i, cash + debt);
            console.log("   claims / accruedScaled", claims, accrued);
        }
    }

}
