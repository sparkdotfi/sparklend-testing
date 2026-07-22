// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { AToken }             from "sparklend-v1-core/contracts/protocol/tokenization/AToken.sol";
import { VariableDebtToken }  from "sparklend-v1-core/contracts/protocol/tokenization/VariableDebtToken.sol";
import { WadRayMath }         from "sparklend-v1-core/contracts/protocol/libraries/math/WadRayMath.sol";

import { InvariantsBase } from "test/invariants/InvariantsBase.t.sol";

// Global invariants for the SparkLend rounding PR, driven by LendingHandler.
//
// The backbone invariants (solvency + scaled conservation) SHOULD hold and validate that the
// harness is exercising the protocol correctly. `invariant_collateralFlagImpliesBalance` encodes
// the ghost-flag property; if the campaign finds a counterexample it reproduces that finding in
// stateful form (the dedicated PoC in test/fuzz/GhostCollateralFlag.t.sol demonstrates it
// deterministically).
contract InvariantsTest is InvariantsBase {

    using WadRayMath for uint256;

    // Closed set of every address that can hold an aToken/debt balance in this campaign:
    // all actors + bootstrap (seed liquidity) + treasury (receives liquidation protocol fees).
    function _holderSet() internal view returns (address[] memory set) {
        set = new address[](actors.length + 2);
        for (uint256 i; i < actors.length; ++i) set[i] = actors[i];
        set[actors.length]     = bootstrap;
        set[actors.length + 1] = treasury;
    }

    /**********************************************************************************************/
    /*** Solvency: backing (cash + debt) always covers aToken claims                            ***/
    /**********************************************************************************************/

    function invariant_aTokenSolvency() public {
        for (uint256 i; i < assetList.length; ++i) {
            address asset  = assetList[i];
            address aToken = pool.getReserveData(asset).aTokenAddress;
            address vDebt  = pool.getReserveData(asset).variableDebtTokenAddress;
            address sDebt  = pool.getReserveData(asset).stableDebtTokenAddress;

            uint256 cash   = IERC20(asset).balanceOf(aToken);
            uint256 debt   = IERC20(vDebt).totalSupply() + IERC20(sDebt).totalSupply();
            uint256 claims = IERC20(aToken).totalSupply();

            // The unminted treasury accrual (stored scaled) is also a claim on the reserve's
            // backing — the handler's mintToTreasury action converts it into aToken supply, so
            // solvency must hold with it counted either way.
            uint256 treasuryClaim = uint256(pool.getReserveData(asset).accruedToTreasury)
                .rayMul(pool.getReserveNormalizedIncome(asset));

            assertGe(
                cash + debt,
                claims + treasuryClaim,
                "INSOLVENT: cash + debt < aToken totalSupply + unminted treasury accrual"
            );
        }
    }

    /**********************************************************************************************/
    /*** Conservation: sum of scaled balances == scaled total supply                            ***/
    /**********************************************************************************************/

    function invariant_scaledCollateralConservation() public {
        address[] memory holders = _holderSet();
        for (uint256 i; i < assetList.length; ++i) {
            AToken aToken = AToken(pool.getReserveData(assetList[i]).aTokenAddress);
            uint256 sum;
            for (uint256 j; j < holders.length; ++j) sum += aToken.scaledBalanceOf(holders[j]);
            assertEq(sum, aToken.scaledTotalSupply(), "aToken scaled conservation broken");
        }
    }

    function invariant_scaledDebtConservation() public {
        address[] memory holders = _holderSet();
        for (uint256 i; i < assetList.length; ++i) {
            VariableDebtToken vDebt
                = VariableDebtToken(pool.getReserveData(assetList[i]).variableDebtTokenAddress);
            uint256 sum;
            for (uint256 j; j < holders.length; ++j) sum += vDebt.scaledBalanceOf(holders[j]);
            assertEq(sum, vDebt.scaledTotalSupply(), "variable debt scaled conservation broken");
        }
    }

    /**********************************************************************************************/
    /*** Ghost collateral flag: flag set => positive scaled balance                             ***/
    /**********************************************************************************************/

    function invariant_collateralFlagImpliesBalance() public {
        // KNOWN-VIOLABLE while the ghost-flag bug is open: a deep enough campaign SHOULD find a
        // counterexample (see test/fuzz/GhostCollateralFlag.t.sol for the deterministic PoC).
        // Gated off by default so raising runs/depth doesn't turn a known open finding into a
        // nondeterministic CI failure. Enable with CHECK_GHOST_FLAG=true; flip to always-on once
        // the upstream fix lands.
        if (!vm.envOr("CHECK_GHOST_FLAG", false)) return;

        address[] memory holders = _holderSet();
        for (uint256 i; i < assetList.length; ++i) {
            address asset  = assetList[i];
            AToken  aToken = AToken(pool.getReserveData(asset).aTokenAddress);
            for (uint256 j; j < holders.length; ++j) {
                ( , , , , , , , , bool usingAsCollateral )
                    = protocolDataProvider.getUserReserveData(asset, holders[j]);
                if (usingAsCollateral) {
                    assertGt(
                        aToken.scaledBalanceOf(holders[j]),
                        0,
                        "GHOST FLAG: collateral enabled on zero scaled balance"
                    );
                }
            }
        }
    }

    // Visibility only; never fails. Run with -vv to see per-action coverage — an action whose
    // success count collapses to zero means the campaign stopped reaching that path.
    function invariant_callSummary() public view {
        string[11] memory actions = [
            "supply", "withdraw", "withdrawMax", "borrow", "repay", "repayMax",
            "transferAToken", "setCollateral", "mintToTreasury", "liquidate", "warp"
        ];

        console2.log("--- call summary (successes / attempts) ---");
        for (uint256 i; i < actions.length; ++i) {
            console2.log(
                actions[i], handler.successes(actions[i]), "/", handler.attempts(actions[i])
            );
        }
    }
}
