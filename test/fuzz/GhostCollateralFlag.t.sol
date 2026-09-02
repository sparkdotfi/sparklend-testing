// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { WadRayMathWrapper } from "sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

// Documents the "ghost collateral flag" issue from the SC-1569 rounding change.
//
// When the liquidity index is above 1.0, a transfer/withdraw burns scaled balance with rayDivCeil
// (up) while the flag-clear compares underlying amounts (balanceFromBefore == amount,
// amountToWithdraw == userBalance, both read with rayMulFloor). An amount just below balanceOf can
// empty the scaled balance while that equality reads false, leaving isUsingAsCollateral == true on
// a zero balance.
//
// The stale flag itself is a known, accepted issue that will NOT be fixed; these tests exist to
// document it and assert its current behavior. Since the zero-balance check moved to the enable
// path only (Certora recommendation fix #29), the ghost flag can be cleared directly with
// setUserUseReserveAsCollateral(asset, false).

contract GhostCollateralFlagTests is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address victim    = makeAddr("victim");
    address borrower  = makeAddr("borrower");
    address recipient = makeAddr("recipient");
    address lp        = makeAddr("lp");

    uint256 ghostAmount;

    function setUp() public override {
        super.setUp();

        // Step 1 : Initialize the collateral and borrow assets with 50% LTV, 50% LT, and 101% liquidation bonus.

        _initCollateral(address(collateralAsset), 50_00, 50_00, 101_00);
        _initCollateral(address(borrowAsset),     50_00, 50_00, 101_00);

        // Step 2 : Set the collateral and borrow assets as borrowable.
        //          So borrowers can borrow and rise the index above 1.0.

        vm.startPrank(admin);

        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);
        poolConfigurator.setReserveBorrowing(address(borrowAsset),     true);

        vm.stopPrank();

        // Step 3 : Victim supplies and uses the collateral asset as collateral.

        _supplyAndUseAsCollateral(victim, address(collateralAsset), 1_000_000 ether);

        // Step 4 : Grow the index above RAY by having a borrower borrow it.

        _growCollateralIndex();

        // Step 5 : Ghost amount that can be transferred to the recipient without clearing the flag.
        ghostAmount = aCollateralAsset.balanceOf(victim) - 1;
    }

    function test_ghostFlag_transfer_leavesFlagOnZeroBalance() public {
        assertEq(aCollateralAsset.scaledBalanceOf(victim),        1_000_000 ether);
        assertEq(_isCollateral(address(collateralAsset), victim), true);

        vm.prank(victim);
        aCollateralAsset.transfer(recipient, ghostAmount);

        // Scaled balance is emptied, but the flag is still set.
        assertEq(aCollateralAsset.scaledBalanceOf(victim),        0);
        assertEq(_isCollateral(address(collateralAsset), victim), true);
    }

    function test_ghostFlag_withdraw_leavesFlagOnZeroBalance() public {
        // Extra collateralAsset cash so the victim's full-balance withdraw is covered even with 
        // the borrow outstanding.
        _supply(lp, address(collateralAsset), 3_000_000 ether);

        assertEq(aCollateralAsset.scaledBalanceOf(victim),        1_000_000 ether);
        assertEq(_isCollateral(address(collateralAsset), victim), true);

        vm.prank(victim);
        pool.withdraw(address(collateralAsset), ghostAmount, victim);

        // Scaled balance is emptied, but the flag is still set.
        assertEq(aCollateralAsset.scaledBalanceOf(victim),        0);
        assertEq(_isCollateral(address(collateralAsset), victim), true);
    }

    function test_ghostFlag_isClearableDirectly() public {
        assertEq(aCollateralAsset.scaledBalanceOf(victim),        1_000_000 ether);
        assertEq(_isCollateral(address(collateralAsset), victim), true);

        vm.prank(victim);
        aCollateralAsset.transfer(recipient, ghostAmount);

        // Scaled balance is emptied, but the flag is still set.
        assertEq(aCollateralAsset.scaledBalanceOf(victim),        0);
        assertEq(_isCollateral(address(collateralAsset), victim), true);

        // The zero-balance check only applies when enabling, so the flag clears directly.
        vm.prank(victim);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);

        assertEq(_isCollateral(address(collateralAsset), victim), false);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _isCollateral(address asset, address user) internal view returns (bool enabled) {
        ( , , , , , , , , enabled) = protocolDataProvider.getUserReserveData(asset, user);
    }

    function _growCollateralIndex() internal {
        _supplyAndUseAsCollateral(borrower, address(borrowAsset), 10_000_000 ether);

        vm.prank(borrower);
        pool.borrow(address(collateralAsset), 200_000 ether, 2, 0, borrower);

        vm.warp(block.timestamp + 3650 days); // Warp 10 years so interest accrues.

        _supply(borrower, address(collateralAsset), 1 ether); // Update the reserve state.
    }

}
