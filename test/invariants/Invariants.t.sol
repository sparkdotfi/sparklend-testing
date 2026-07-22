// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { AToken }             from "sparklend-v1-core/contracts/protocol/tokenization/AToken.sol";
import { VariableDebtToken }  from "sparklend-v1-core/contracts/protocol/tokenization/VariableDebtToken.sol";

import { InvariantsBase } from "test/invariants/InvariantsBase.t.sol";

// Global invariants for the SparkLend rounding PR, driven by LendingHandler.
//
// The backbone invariants (solvency + scaled conservation) SHOULD hold and validate that the
// harness is exercising the protocol correctly. `invariant_collateralFlagImpliesBalance` encodes
// the ghost-flag property; if the campaign finds a counterexample it reproduces that finding in
// stateful form (the dedicated PoC in test/fuzz/GhostCollateralFlag.t.sol demonstrates it
// deterministically).
contract InvariantsTest is InvariantsBase {

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

            assertGe(cash + debt, claims, "INSOLVENT: cash + debt < aToken totalSupply");
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

    function invariant_callSummary() public {
        // Visibility only; never fails.
        assertGe(handler.callCount(), 0);
    }
}
