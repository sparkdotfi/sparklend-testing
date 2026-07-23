// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract RoundingInvariantTests is SparkLendTestBase {

    address borrower = makeAddr("borrower");
    address lender   = makeAddr("lender");
    address user     = makeAddr("user");

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

        _supplyAndUseAsCollateral(user, address(collateralAsset), 1_000_000e18);
        _supply(lender, address(borrowAsset), 1_000_000e18);

        // Open a standing borrow so the fuzzed warp actually accrues interest and pushes the
        // liquidity/borrow indices above RAY — floor/ceil rounding only diverges there.
        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1_000_000e18);
        _borrow(borrower, address(borrowAsset), 400_000e18);
    }

    function testFuzz_depositWithdraw_neverReturnsMoreThanDeposited(
        uint256 warpTime,
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        warpTime = _bound(warpTime, 0, 500 * 365 days);

        vm.warp(block.timestamp + warpTime);

        uint256 index = pool.getReserveNormalizedIncome(address(borrowAsset));

        // At index > RAY a supply below index/RAY floors its scaled mint to zero and reverts.
        depositAmount = _bound(depositAmount, index / 1e27 + 1, 1_000_000e18);

        _supply(user, address(borrowAsset), depositAmount);

        // balanceOf floors, so it can sit a few wei below depositAmount — withdrawing more than
        // it reverts (NOT_ENOUGH_AVAILABLE_USER_BALANCE). Bound to the readable balance.
        withdrawAmount = _bound(withdrawAmount, 1, aBorrowAsset.balanceOf(user));

        _withdraw(user, address(borrowAsset), withdrawAmount);

        uint256 aTokenBalance = aBorrowAsset.balanceOf(user);

        assertLe(aTokenBalance + withdrawAmount, depositAmount);
    }

    function testFuzz_borrowRepay_neverLeavesLessDebtThanBorrowed(
        uint256 warpTime,
        uint256 borrowAmount,
        uint256 repayAmount
    ) public {
        warpTime = _bound(warpTime, 0, 500 * 365 days);

        vm.warp(block.timestamp + warpTime);

        // At index > RAY a repay below index/RAY floors its scaled debt burn to zero and reverts.
        uint256 index = pool.getReserveNormalizedVariableDebt(address(borrowAsset));

        borrowAmount = _bound(borrowAmount, index / 1e27 + 1, 400_000e18);
        repayAmount  = _bound(repayAmount,  index / 1e27 + 1, borrowAmount);

        _borrow(user, address(borrowAsset), borrowAmount);

        _repay(user, address(borrowAsset), repayAmount);

        uint256 debtBalance = IERC20(
            pool.getReserveData(address(borrowAsset)).variableDebtTokenAddress
        ).balanceOf(user);

        assertGe(debtBalance + repayAmount, borrowAmount);
    }

}
