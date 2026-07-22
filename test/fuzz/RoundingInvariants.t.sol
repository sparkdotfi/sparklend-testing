// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract RoundingInvariantTests is SparkLendTestBase {

    address user         = makeAddr("user");
    address lender       = makeAddr("lender");
    address seedBorrower = makeAddr("seedBorrower");

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

        // Open a standing borrow so the fuzzed warp actually accrues interest and pushes the
        // liquidity/borrow indices above RAY — floor/ceil rounding only diverges there. Without
        // this the reserve has zero utilization and every test runs at index == RAY.
        _supplyAndUseAsCollateral(seedBorrower, address(collateralAsset), 1_000_000 ether);
        _borrow(seedBorrower, address(borrowAsset), 400_000 ether);
    }

    function testFuzz_depositWithdraw_neverReturnsMoreThanDeposited(
        uint256 warpTime,
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        warpTime = bound(warpTime, 0, 50 * 365 days);

        vm.warp(block.timestamp + warpTime);

        // At index > RAY a supply below index/RAY floors its scaled mint to zero and reverts
        // (INVALID_MINT_AMOUNT) — a documented dust behavior, not the rounding property under
        // test — so bound deposits above that threshold.
        uint256 index = pool.getReserveNormalizedIncome(address(borrowAsset));
        depositAmount = bound(depositAmount, index / 1e27 + 1, 1_000_000 ether);

        _supply(user, address(borrowAsset), depositAmount);

        // balanceOf floors, so it can sit a few wei below depositAmount — withdrawing more than
        // it reverts (NOT_ENOUGH_AVAILABLE_USER_BALANCE). Bound to the readable balance.
        withdrawAmount = bound(withdrawAmount, 1, aBorrowAsset.balanceOf(user));

        _withdraw(user, address(borrowAsset), withdrawAmount);

        uint256 aTokenBalance = aBorrowAsset.balanceOf(user);

        assertLe(aTokenBalance + withdrawAmount, depositAmount);
    }

    function testFuzz_borrowRepay_neverLeavesLessDebtThanBorrowed(
        uint256 warpTime,
        uint256 borrowAmount,
        uint256 repayAmount
    ) public {
        warpTime = bound(warpTime, 0, 50 * 365 days);

        vm.warp(block.timestamp + warpTime);

        // At index > RAY a repay below index/RAY floors its scaled debt burn to zero and reverts
        // (INVALID_BURN_AMOUNT) — a documented dust behavior, not the rounding property under
        // test — so bound both amounts above that threshold.
        uint256 index = pool.getReserveNormalizedVariableDebt(address(borrowAsset));
        borrowAmount  = bound(borrowAmount, index / 1e27 + 1, 400_000 ether);
        repayAmount   = bound(repayAmount, index / 1e27 + 1, borrowAmount);

        _borrow(user, address(borrowAsset), borrowAmount);

        _repay(user, address(borrowAsset), repayAmount);

        uint256 debtBalance = IERC20(
            pool.getReserveData(address(borrowAsset)).variableDebtTokenAddress
        ).balanceOf(user);

        assertGe(debtBalance + repayAmount, borrowAmount);
    }

}
