// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract RoundingInvariantTests is SparkLendTestBase {

    address user   = makeAddr("user");
    address lender = makeAddr("lender");

    function setUp() public override {
        super.setUp();

        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), true);

        _supplyAndUseAsCollateral(user, address(collateralAsset), 1_000_000 ether);
        _supply(lender, address(borrowAsset), 1_000_000 ether);
    }

    function testFuzz_depositWithdraw_neverReturnsMoreThanDeposited(
        uint256 warpTime,
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        warpTime       = bound(warpTime, 0, 50 * 365 days);
        depositAmount  = bound(depositAmount, 1, 1_000_000 ether);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.warp(block.timestamp + warpTime);

        _supply(user, address(borrowAsset), depositAmount);

        _withdraw(user, address(borrowAsset), withdrawAmount);

        uint256 aTokenBalance = aBorrowAsset.balanceOf(user);

        assertLe(aTokenBalance + withdrawAmount, depositAmount);
    }

    function testFuzz_borrowRepay_neverLeavesLessDebtThanBorrowed(
        uint256 warpTime,
        uint256 borrowAmount,
        uint256 repayAmount
    ) public {
        warpTime     = bound(warpTime, 0, 50 * 365 days);
        borrowAmount = bound(borrowAmount, 1, 400_000 ether);
        repayAmount  = bound(repayAmount, 1, borrowAmount);

        vm.warp(block.timestamp + warpTime);

        _borrow(user, address(borrowAsset), borrowAmount);

        _repay(user, address(borrowAsset), repayAmount);

        uint256 debtBalance = IERC20(
            pool.getReserveData(address(borrowAsset)).variableDebtTokenAddress
        ).balanceOf(user);

        assertGe(debtBalance + repayAmount, borrowAmount);
    }

}
