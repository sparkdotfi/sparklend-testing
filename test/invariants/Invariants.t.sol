// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { AToken }            from "../../lib/sparklend-v1-core/contracts/protocol/tokenization/AToken.sol";
import { VariableDebtToken } from "../../lib/sparklend-v1-core/contracts/protocol/tokenization/VariableDebtToken.sol";
import { WadRayMath }        from "../../lib/sparklend-v1-core/contracts/protocol/libraries/math/WadRayMath.sol";

import { SparkLendTestBase } from "../SparkLendTestBase.sol";

import { PoolHandler } from "./handlers/PoolHandler.sol";

interface IERC20Like {

    function balanceOf(address) external view returns (uint256);

    function totalSupply() external view returns (uint256);

}

contract Invariants is SparkLendTestBase {

    using WadRayMath for uint256;

    address internal handler;

    address[] internal actors;
    address[] internal assets;
    address[] internal holders;

    address internal bootstrap = makeAddr("bootstrap");

    function setUp() public virtual override {
        super.setUp();

        // Both reserves usable as collateral and borrowable.
        _initCollateral(address(collateralAsset), 70_00, 75_00, 105_00);
        _initCollateral(address(borrowAsset),     70_00, 75_00, 105_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset),    true);
        poolConfigurator.setReserveBorrowing(address(borrowAsset),        true);
        poolConfigurator.setReserveFlashLoaning(address(collateralAsset), true);
        poolConfigurator.setReserveFlashLoaning(address(borrowAsset),     true);
        vm.stopPrank();

        assets.push(address(collateralAsset));
        assets.push(address(borrowAsset));

        for (uint256 i; i < 10; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }

        _populateHolders();

        // Seed deep liquidity and open a real borrow so indices move over time.
        _supplyAndUseAsCollateral(bootstrap, address(collateralAsset), 5_000_000e18);
        _supplyAndUseAsCollateral(bootstrap, address(borrowAsset),     5_000_000e18);

        vm.startPrank(bootstrap);
        pool.borrow(address(collateralAsset), 500_000e18, 2, 0, bootstrap);
        pool.borrow(address(borrowAsset),     500_000e18, 2, 0, bootstrap);
        vm.stopPrank();

        // Give every actor starting collateral so borrows can succeed during the campaign.
        for (uint256 i; i < actors.length; ++i) {
            _supplyAndUseAsCollateral(actors[i], address(collateralAsset), 100_000e18);
        }

        handler = address(new PoolHandler(address(pool), actors, assets));

        // Define the handler functions to fuzz and their relative weights.

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = PoolHandler.warp.selector;
        selectors[1] = PoolHandler.supply.selector;
        selectors[2] = PoolHandler.withdraw.selector;
        selectors[3] = PoolHandler.borrow.selector;
        selectors[4] = PoolHandler.repay.selector;
        selectors[5] = PoolHandler.transfer.selector;
        selectors[6] = PoolHandler.setCollateral.selector;
        selectors[7] = PoolHandler.mintToTreasury.selector;
        selectors[8] = PoolHandler.liquidate.selector;
        selectors[9] = PoolHandler.flashLoan.selector;
        selectors[10] = PoolHandler.flashLoanSimple.selector;

        uint8[] memory weights = new uint8[](11);
        weights[0] = 20;
        weights[1] = 10;
        weights[2] = 10;
        weights[3] = 40;
        weights[4] = 10;
        weights[5] = 10;
        weights[6] = 20;
        weights[7] = 5;
        weights[8] = 30;
        weights[9] = 10;
        weights[10] = 10;

        targetContract(handler);
        targetSelector(FuzzSelector({ addr: handler, selectors: _generateSelectors(selectors, weights) }));
    }

    function invariant_full() external {
        for (uint256 i; i < assets.length; ++i) {
            address asset  = assets[i];

            address aToken = pool.getReserveData(asset).aTokenAddress;
            address vDebt  = pool.getReserveData(asset).variableDebtTokenAddress;
            address sDebt  = pool.getReserveData(asset).stableDebtTokenAddress;

            uint256 cash   = IERC20Like(asset).balanceOf(aToken);
            uint256 debt   = IERC20Like(vDebt).totalSupply() + IERC20Like(sDebt).totalSupply();
            uint256 claims = IERC20Like(aToken).totalSupply();

            // The unminted treasury accrual (stored scaled) is also a claim on the reserve's
            // backing — the handler's mintToTreasury action converts it into aToken supply, so
            // solvency must hold with it counted either way.
            uint256 treasuryClaim =
                uint256(pool.getReserveData(asset).accruedToTreasury)
                .rayMul(pool.getReserveNormalizedIncome(asset));

            assertGe(
                cash + debt,
                claims + treasuryClaim,
                "INSOLVENT: cash + debt < aToken totalSupply + unminted treasury accrual"
            );

            uint256 sumOfScaledBalances;
            uint256 sumOfScaledDebt;

            for (uint256 j; j < holders.length; ++j) {
                uint256 aTokenBalance = AToken(aToken).scaledBalanceOf(holders[j]);

                ( , , , , , , , , bool usingAsCollateral ) = protocolDataProvider.getUserReserveData(asset, holders[j]);

                assertTrue(
                    !usingAsCollateral || aTokenBalance > 0,
                    "GHOST FLAG: collateral enabled on zero scaled balance"
                );

                sumOfScaledBalances += aTokenBalance;
                sumOfScaledDebt     += VariableDebtToken(vDebt).scaledBalanceOf(holders[j]);
            }

            assertEq(
                sumOfScaledBalances,
                AToken(aToken).scaledTotalSupply(),
                "aToken scaled conservation broken"
            );

            assertEq(
                sumOfScaledDebt,
                VariableDebtToken(vDebt).scaledTotalSupply(),
                "variable debt scaled conservation broken"
            );
        }
    }

    // Closed set of every address that can hold an aToken/debt balance in this campaign:
    // all actors + bootstrap (seed liquidity) + treasury (receives liquidation protocol fees).
    function _populateHolders() internal {
        for (uint256 i; i < actors.length; ++i) {
            holders.push(actors[i]);
        }

        holders.push(bootstrap);
        holders.push(treasury);
    }

    function _generateSelectors(bytes4[] memory input, uint8[] memory weights) internal returns (bytes4[] memory output) {
        uint256 totalWeight;

        for (uint256 i; i < weights.length; ++i) {
            totalWeight += weights[i];
        }

        output = new bytes4[](totalWeight);

        uint256 index;

        for (uint256 i; i < weights.length; ++i) {
            for (uint256 j; j < weights[i]; ++j) {
                output[index++] = input[i];
            }
        }
    }

}
