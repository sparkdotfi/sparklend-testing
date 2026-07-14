// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { IAToken } from "sparklend-v1-core/contracts/interfaces/IAToken.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract MintToTreasuryTests is SparkLendTestBase {

    address borrower = makeAddr("borrower");

    address borrowAsset1;
    address borrowAsset2;

    function setUp() public override {
        super.setUp();

        borrowAsset1 = _setUpNewReserve();
        borrowAsset2 = _setUpNewReserve();

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(borrowAsset1, true);
        poolConfigurator.setReserveBorrowing(borrowAsset2, true);
        poolConfigurator.setReserveFactor(borrowAsset1, 5_00);
        poolConfigurator.setReserveFactor(borrowAsset2, 5_00);
        vm.stopPrank();

        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);
        _supply(borrower, borrowAsset1, 500 ether);
        _supply(borrower, borrowAsset2, 500 ether);
        _borrow(borrower, borrowAsset1, 100 ether);
        _borrow(borrower, borrowAsset2, 100 ether);
    }

    modifier whenReservesHaveAccruedValue {
        vm.warp(1 + WARP_TIME);  // Using warp so multiple assets can be tested with this

        _;
    }

    modifier whenAccruedToTreasuryHasNotBeenUpdated(address borrowAsset_) {
        _;
        assertEq(pool.getReserveData(borrowAsset_).accruedToTreasury, 0);
    }

    modifier whenAccruedToTreasuryHasBeenUpdated(address borrowAsset_) {
        // Update reserve state without updating reserve value
        _supply(borrower, borrowAsset_, 1 ether);
        _withdraw(borrower, borrowAsset_, 1 ether);

        assertGt(pool.getReserveData(borrowAsset_).accruedToTreasury, 0);

        _;
    }

    modifier whenNoTimeHasPassed {
        _;
    }

    modifier whenSomeTimeHasPassed {
        vm.warp(1 + WARP_TIME * 2);  // Using warp so multiple assets can be tested with this

        _;
    }

    function test_mintToTreasury_01() public proveNoOp {
        address[] memory assets = new address[](1);
        assets[0] = makeAddr("invalid-asset");

        vm.startStateDiffRecording();
        pool.mintToTreasury(assets);
    }

    function test_mintToTreasury_02() public proveNoOp {
        _repay(borrower, borrowAsset1, 100 ether);
        _withdraw(borrower, borrowAsset1, 500 ether);

        vm.prank(admin);
        poolConfigurator.setReserveActive(borrowAsset1, false);

        address[] memory assets = new address[](1);
        assets[0] = borrowAsset1;

        vm.startStateDiffRecording();
        pool.mintToTreasury(assets);
    }

    function test_mintToTreasury_03() public proveNoOp {
        address[] memory assets = new address[](1);
        assets[0] = borrowAsset1;

        vm.startStateDiffRecording();
        pool.mintToTreasury(assets);
    }

    function test_mintToTreasury_04()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasNotBeenUpdated(borrowAsset1)
        proveNoOp
    {
        address[] memory assets = new address[](1);
        assets[0] = borrowAsset1;

        vm.startStateDiffRecording();
        pool.mintToTreasury(assets);
    }

    function test_mintToTreasury_05()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
        whenNoTimeHasPassed
    {
        ( uint256 scaledAccruedToTreasury, uint256 liquidityIndex, uint256 supplierYield )
            = _noTimePassedTestBefore(borrowAsset1);

        address[] memory assets = new address[](1);
        assets[0] = borrowAsset1;
        pool.mintToTreasury(assets);

        _noTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury,
            liquidityIndex,
            supplierYield
        );
    }

    function test_mintToTreasury_06()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
        whenSomeTimeHasPassed
    {
        ( uint256 scaledAccruedToTreasury, uint256 liquidityIndex2, uint256 supplierYield )
            = _someTimePassedTestBefore(borrowAsset1);

        address[] memory assets = new address[](1);
        assets[0] = borrowAsset1;
        pool.mintToTreasury(assets);

        _someTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury,
            liquidityIndex2,
            supplierYield
        );
    }

    function test_mintToTreasury_07()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
    {
        ( uint256 scaledAccruedToTreasury, uint256 liquidityIndex, uint256 supplierYield )
            = _noTimePassedTestBefore(borrowAsset1);

        IERC20 aBorrowAsset2 = IERC20(pool.getReserveData(borrowAsset2).aTokenAddress);

        uint256 totalSupplyBefore = aBorrowAsset2.totalSupply();

        address[] memory assets = new address[](2);
        assets[0] = borrowAsset1;
        assets[1] = makeAddr("invalid-asset");
        pool.mintToTreasury(assets);

        _noTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury,
            liquidityIndex,
            supplierYield
        );

        // Total supply check considered sufficient because of no-op assertions before
        assertEq(aBorrowAsset2.totalSupply(), totalSupplyBefore);
    }

    function test_mintToTreasury_08()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
    {
        // NOTE: In order to set a reserve inactive, both totalSupply and accruedToTreasury have to
        //       be zero. Withdrawing sets totalSupply to zero, but increases accruedToTreasury.
        //       To get accruedToTreasury to zero, we have to mint to treasury first, which
        //       increases totalSupply, so a withdraw is done from treasury to get
        //       totalSupply to zero.

        IERC20 debtToken     = IERC20(pool.getReserveData(borrowAsset2).variableDebtTokenAddress);
        IERC20 aBorrowAsset2 = IERC20(pool.getReserveData(borrowAsset2).aTokenAddress);

        _repay(borrower, borrowAsset2, debtToken.balanceOf(borrower));
        _withdraw(borrower, borrowAsset2, aBorrowAsset2.balanceOf(borrower));

        assertGt(pool.getReserveData(borrowAsset2).accruedToTreasury, 0);
        assertEq(aBorrowAsset2.totalSupply(),                         0);

        address[] memory assets = new address[](1);
        assets[0] = borrowAsset2;
        pool.mintToTreasury(assets);

        assertEq(pool.getReserveData(borrowAsset2).accruedToTreasury, 0);
        assertGt(aBorrowAsset2.totalSupply(),                         0);

        _withdraw(treasury, borrowAsset2, aBorrowAsset2.balanceOf(treasury));

        assertEq(aBorrowAsset2.totalSupply(), 0);

        vm.prank(admin);
        poolConfigurator.setReserveActive(borrowAsset2, false);

        ( uint256 scaledAccruedToTreasury, uint256 liquidityIndex, uint256 supplierYield )
            = _noTimePassedTestBefore(borrowAsset1);

        uint256 totalSupplyBefore = aBorrowAsset2.totalSupply();

        assets = new address[](2);
        assets[0] = borrowAsset1;
        assets[1] = borrowAsset2;
        pool.mintToTreasury(assets);

        _noTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury,
            liquidityIndex,
            supplierYield
        );

        // Total supply check considered sufficient because of no-op assertions before
        assertEq(aBorrowAsset2.totalSupply(), totalSupplyBefore);
    }

    function test_mintToTreasury_09()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
        whenAccruedToTreasuryHasNotBeenUpdated(borrowAsset2)
    {
        ( uint256 scaledAccruedToTreasury, uint256 liquidityIndex, uint256 supplierYield )
            = _noTimePassedTestBefore(borrowAsset1);

        IERC20 aBorrowAsset2 = IERC20(pool.getReserveData(borrowAsset2).aTokenAddress);

        uint256 totalSupplyBefore = aBorrowAsset2.totalSupply();

        address[] memory assets = new address[](2);
        assets[0] = borrowAsset1;
        assets[1] = borrowAsset2;
        pool.mintToTreasury(assets);

        _noTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury,
            liquidityIndex,
            supplierYield
        );

        // Total supply check considered sufficient because of no-op assertions before
        assertEq(aBorrowAsset2.totalSupply(), totalSupplyBefore);
    }

    function test_mintToTreasury_10()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset2)
        whenNoTimeHasPassed
    {
        ( uint256 scaledAccruedToTreasury1, uint256 liquidityIndex1, uint256 supplierYield1 )
        = _noTimePassedTestBefore(borrowAsset1);

        ( uint256 scaledAccruedToTreasury2, uint256 liquidityIndex2, uint256 supplierYield2 )
            = _noTimePassedTestBefore(borrowAsset2);

        address[] memory assets = new address[](2);
        assets[0] = borrowAsset1;
        assets[1] = borrowAsset2;
        pool.mintToTreasury(assets);

        _noTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury1,
            liquidityIndex1,
            supplierYield1
        );

        _noTimePassedTestAfter(
            borrowAsset2,
            scaledAccruedToTreasury2,
            liquidityIndex2,
            supplierYield2
        );
    }

    function test_mintToTreasury_11()
        public
        whenReservesHaveAccruedValue
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset1)
        whenAccruedToTreasuryHasBeenUpdated(borrowAsset2)
        whenSomeTimeHasPassed
    {
        ( uint256 scaledAccruedToTreasury1, uint256 liquidityIndex1, uint256 supplierYield1 )
            = _someTimePassedTestBefore(borrowAsset1);

        ( uint256 scaledAccruedToTreasury2, uint256 liquidityIndex2, uint256 supplierYield2 )
            = _someTimePassedTestBefore(borrowAsset2);

        address[] memory assets = new address[](2);
        assets[0] = borrowAsset1;
        assets[1] = borrowAsset2;
        pool.mintToTreasury(assets);

        _someTimePassedTestAfter(
            borrowAsset1,
            scaledAccruedToTreasury1,
            liquidityIndex1,
            supplierYield1
        );

        _someTimePassedTestAfter(
            borrowAsset2,
            scaledAccruedToTreasury2,
            liquidityIndex2,
            supplierYield2
        );
    }

    function _noTimePassedTestBefore(address borrowAsset_)
        internal returns (
            uint256 scaledAccruedToTreasury,
            uint256 liquidityIndex,
            uint256 supplierYield
        )
    {
        // borrowRate * utilization * (1 - reserveFactor)
        uint256 liquidityRate = 0.055e27 * 20/100 * 95/100;

        supplierYield  = 500 ether * liquidityRate / 100 / 1e27;  // 1% of a year has passed
        liquidityIndex = 1e27 + (liquidityRate * 1/100);

        uint256 borrowerInterest = _getAccruedInterest(0.055e27, WARP_TIME, 100 ether);

        scaledAccruedToTreasury = borrowerInterest * 5/100 * 1e27 / liquidityIndex;

        assertEq(supplierYield,           0.05225 ether);
        assertEq(borrowerInterest,        0.055015127565607543 ether);  // 5.5% compounded
        assertEq(scaledAccruedToTreasury, 0.002750468954274655 ether);  // 5% of borrowerInterest

        IAToken aBorrowAsset_ = IAToken(pool.getReserveData(borrowAsset_).aTokenAddress);

        assertApproxEqAbs(aBorrowAsset_.totalSupply(), 500 ether + supplierYield, 2);

        assertEq(aBorrowAsset_.balanceOf(treasury),       0);
        assertEq(aBorrowAsset_.scaledBalanceOf(treasury), 0);

        assertEq(pool.getReserveData(borrowAsset_).accruedToTreasury, scaledAccruedToTreasury);
    }

    function _noTimePassedTestAfter(
        address borrowAsset_,
        uint256 scaledAccruedToTreasury,
        uint256 liquidityIndex,
        uint256 supplierYield
    ) internal {
        // Pool mints with rayMul (half-up); balanceOf reads back with rayMulFloor
        uint256 amountMinted    = scaledAccruedToTreasury * liquidityIndex / 1e27 + 1;  // rayMul
        uint256 treasuryBalance = scaledAccruedToTreasury * liquidityIndex / 1e27;      // rayMulFloor

        assertEq(amountMinted,    0.002750756378280377 ether);
        assertEq(treasuryBalance, 0.002750756378280376 ether);

        IAToken aBorrowAsset_ = IAToken(pool.getReserveData(borrowAsset_).aTokenAddress);

        assertApproxEqAbs(aBorrowAsset_.totalSupply(), 500 ether + supplierYield + amountMinted, 2);

        assertEq(aBorrowAsset_.balanceOf(treasury),       treasuryBalance);
        assertEq(aBorrowAsset_.scaledBalanceOf(treasury), scaledAccruedToTreasury);

        assertEq(pool.getReserveData(borrowAsset_).accruedToTreasury, 0);
    }

    function _someTimePassedTestBefore(address borrowAsset_)
        internal returns (
            uint256 scaledAccruedToTreasury,
            uint256 liquidityIndex2,
            uint256 supplierYield
        )
    {
        // These values were updated at last supply/withdraw which was at WARP_TIME
        // borrowRate * utilization * (1 - reserveFactor)
        uint256 liquidityRate1  = 0.055e27 * 20/100 * 95/100;
        uint256 liquidityIndex1 = 1e27 + (liquidityRate1 * 1/100);  // 1% of a year has passed

        uint256 totalInterest = _getAccruedInterest(0.055e27, WARP_TIME, 100 ether);

        ( , uint256 liquidityRate2 )
            = _getUpdatedRates(100 ether + totalInterest, 500 ether + totalInterest);

        liquidityRate2 += 1;  // Rounding

        liquidityIndex2 = (1e27 + (liquidityRate2 * 1/100)) * liquidityIndex1 / 1e27;  // 1% of a year has passed
        supplierYield   = 500 ether * liquidityIndex2 / 1e27 - 500 ether;

        scaledAccruedToTreasury = totalInterest * 5/100 * 1e27 / liquidityIndex1;

        assertEq(pool.getReserveData(borrowAsset_).liquidityIndex,       liquidityIndex1);
        assertEq(pool.getReserveNormalizedIncome(borrowAsset_),          liquidityIndex2);
        assertEq(pool.getReserveData(borrowAsset_).currentLiquidityRate, liquidityRate2);

        // Rates increase because of the accrued interest increasing utilization
        assertEq(liquidityRate1,  0.01045e27);
        assertEq(liquidityRate2,  0.010455017011611857160935024e27);
        assertEq(liquidityIndex1, 1.0001045e27);
        assertEq(liquidityIndex2, 1.000209061095608895706000083e27);
        assertEq(totalInterest,   0.055015127565607543 ether);
        assertEq(supplierYield,   0.104530547804447853 ether);

        assertEq(scaledAccruedToTreasury, 0.002750468954274655 ether);

        IAToken aBorrowAsset_ = IAToken(pool.getReserveData(borrowAsset_).aTokenAddress);

        assertApproxEqAbs(aBorrowAsset_.totalSupply(), 500 ether + supplierYield, 2);

        assertEq(aBorrowAsset_.balanceOf(treasury),       0);
        assertEq(aBorrowAsset_.scaledBalanceOf(treasury), 0);

        assertEq(pool.getReserveData(borrowAsset_).accruedToTreasury, scaledAccruedToTreasury);
    }

    function _someTimePassedTestAfter(
        address borrowAsset_,
        uint256 scaledAccruedToTreasury,
        uint256 liquidityIndex,
        uint256 supplierYield
    ) internal {
        // Pool mints with rayMul (half-up); balanceOf reads back with rayMulFloor
        uint256 amountMinted    = scaledAccruedToTreasury * liquidityIndex / 1e27 + 1;  // rayMul
        uint256 treasuryBalance = scaledAccruedToTreasury * liquidityIndex / 1e27;      // rayMulFloor

        assertEq(amountMinted,    0.002751043970327674 ether);
        assertEq(treasuryBalance, 0.002751043970327673 ether);

        IAToken aBorrowAsset_ = IAToken(pool.getReserveData(borrowAsset_).aTokenAddress);

        // Total supply is higher than the last test, but the treasury balance is the same
        // Treasury balance only increases when `updateState` is called on pool interactions
        assertApproxEqAbs(aBorrowAsset_.totalSupply(), 500 ether + supplierYield + amountMinted, 2);

        assertEq(aBorrowAsset_.balanceOf(treasury),       treasuryBalance);
        assertEq(aBorrowAsset_.scaledBalanceOf(treasury), scaledAccruedToTreasury);

        assertEq(pool.getReserveData(borrowAsset_).accruedToTreasury, 0);
    }

    // TODO: Try to think of weird edge cases where indexes haven't been updated before minting
    //       Update index/accrued, warp, mint, update index, check accrued

}
