// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IVariableDebtToken } from "sparklend-v1-core/contracts/interfaces/IVariableDebtToken.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

// Asserts the account-data valuation rounding from the SC-1569 mitigation: collateral is valued
// with rayMulFloor and a truncating base-currency division, debt with rayMulCeil and a ceiling
// base-currency division, so a position is never valued richer than it is.
contract AccountDataValuationTests is SparkLendTestBase {

    address user   = makeAddr("user");
    address whale  = makeAddr("whale");
    address lender = makeAddr("lender");

    address debtToken;

    function setUp() public override {
        super.setUp();

        _initCollateral(address(collateralAsset), 50_00, 50_00, 101_00);
        _initCollateral(address(borrowAsset),     50_00, 50_00, 101_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);
        poolConfigurator.setReserveBorrowing(address(borrowAsset),     true);
        vm.stopPrank();

        debtToken = pool.getReserveData(address(borrowAsset)).variableDebtTokenAddress;

        // Odd amounts so the index products carry dust below 1e27 and 1e10 (with round figures
        // the modulo terms vanish and the floor/ceil steps would be vacuous).
        _supplyAndUseAsCollateral(user, address(collateralAsset), 1_000_000.123456789012345678 ether);

        // Whale borrows the collateral asset so the user's collateral index grows above 1.0.
        _supplyAndUseAsCollateral(whale, address(borrowAsset), 10_000_000 ether);

        vm.prank(whale);
        pool.borrow(address(collateralAsset), 234_567.891234567890123456 ether, 2, 0, whale);

        vm.prank(user);
        pool.borrow(address(borrowAsset), 98_765.432109876543210987 ether, 2, 0, user);

        vm.warp(block.timestamp + 365 days);
    }

    function test_accountData_collateralFloorsAndDebtCeils() public {
        uint256 income    = pool.getReserveNormalizedIncome(address(collateralAsset));
        uint256 debtIndex = pool.getReserveNormalizedVariableDebt(address(borrowAsset));

        assertGt(income,    1e27);
        assertGt(debtIndex, 1e27);

        uint256 scaledCollateral = aCollateralAsset.scaledBalanceOf(user);
        uint256 scaledDebt       = IVariableDebtToken(debtToken).scaledBalanceOf(user);

        // Prove both rounding steps actually discard dust in this scenario.
        assertGt(scaledCollateral * income % 1e27, 0);
        assertGt(scaledDebt * debtIndex % 1e27,    0);

        // Collateral is valued with rayMulFloor, then truncated into 1e8 base units.
        uint256 rebasedCollateral  = scaledCollateral * income / 1e27;
        uint256 expectedCollateral = rebasedCollateral * 1e8 / 1e18;

        assertGt(rebasedCollateral * 1e8 % 1e18, 0);

        // Debt is valued with rayMulCeil, then ceil-divided into 1e8 base units.
        uint256 rebasedDebt  = (scaledDebt * debtIndex - 1) / 1e27 + 1;
        uint256 expectedDebt = (rebasedDebt * 1e8 - 1) / 1e18 + 1;

        assertGt(rebasedDebt * 1e8 % 1e18, 0);

        ( uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 healthFactor )
            = pool.getUserAccountData(user);

        assertEq(totalCollateralBase, expectedCollateral);
        assertEq(totalDebtBase,       expectedDebt);

        assertEq(totalCollateralBase, 1_012_448.87289955e8);
        assertEq(totalDebtBase,       103_854.83442887e8);

        // HF reproduces percentMul (half-up) and wadDiv (half-up) over the rounded bases.
        uint256 weightedCollateral = (totalCollateralBase * 50_00 + 5_000) / 10_000;
        uint256 expectedHF         = (weightedCollateral * 1e18 + totalDebtBase / 2) / totalDebtBase;

        assertEq(healthFactor, expectedHF);
        assertEq(healthFactor, 4.874346381982749760e18);  // ~1,012,449 * 50% / 103,855
    }

}
