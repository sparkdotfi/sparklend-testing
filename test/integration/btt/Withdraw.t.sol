// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { DataTypes } from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

import { ReserveConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import { UserConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";

import { Errors } from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";

import { IERC20, SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract WithdrawTestBase is SparkLendTestBase {

    address user = makeAddr("user");

    function setUp() public virtual override {
        super.setUp();

        _supply(user, address(collateralAsset), 1000 ether);

        vm.label(user, "user");
    }

}

contract WithdrawFailureTests is WithdrawTestBase {

    function test_withdraw_amountZero() public {
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        pool.withdraw(address(collateralAsset), 0, user);
    }

    function test_withdraw_amountGtBalanceBoundary() public {
        vm.startPrank(user);
        vm.expectRevert(bytes(Errors.NOT_ENOUGH_AVAILABLE_USER_BALANCE));
        pool.withdraw(address(collateralAsset), 1000 ether + 1, user);

        pool.withdraw(address(collateralAsset), 1000 ether, user);
    }

    // TODO: Unreachable code - setReserveActive reverts with RESERVE_LIQUIDITY_NOT_ZERO, can't withdraw without liquidity
    // function test_withdraw_whenNotActive() public {
    //     vm.prank(admin);
    //     poolConfigurator.setReserveActive(address(collateralAsset), false);

    //     vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
    //     pool.withdraw(address(collateralAsset), 1000 ether, user);
    // }

    function test_withdraw_whenPaused() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(address(collateralAsset), true);

        vm.prank(user);
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        pool.withdraw(address(collateralAsset), 1000 ether, user);
    }

    // TODO: Extra test, determine convention for this
    function test_withdraw_success_whenFrozen() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(address(collateralAsset), true);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 1000 ether, user);
    }

    function test_withdraw_healthFactorBelowThresholdBoundary() public {
        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), true);

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), true);

        _supply(makeAddr("supplier"), address(borrowAsset), 250 ether);
        _borrow(user, address(borrowAsset), 250 ether);

        // NOTE: 1e10 used for boundary since HF calculations are done in 1e8 precision
        vm.startPrank(user);

        vm.expectRevert(bytes(Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD));
        pool.withdraw(address(collateralAsset), 500 ether + 1e10 + 1, user);

        pool.withdraw(address(collateralAsset), 500 ether + 1e10, user);
    }

    function test_withdraw_amountGtLiquidityBoundary() public {
        vm.startPrank(user);

        deal(address(collateralAsset), address(aCollateralAsset), 1000 ether - 1);

        vm.expectRevert(stdError.arithmeticError);
        pool.withdraw(address(collateralAsset), 1000 ether, user);

        deal(address(collateralAsset), address(aCollateralAsset), 1000 ether);

        pool.withdraw(address(collateralAsset), 1000 ether, user);
    }

    // TODO: Believe that this code is unreachable because the LTV is checked in two places
    //       and this only fails if one is zero and the other is not.
    // function test_withdraw_LtvValidationFailed() {}

}

contract WithdrawConcreteTests is WithdrawTestBase {

    using UserConfiguration for DataTypes.UserConfigurationMap;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    address debtToken;

    function setUp() public virtual override {
        super.setUp();
        debtToken = pool.getReserveData(address(collateralAsset)).variableDebtTokenAddress;
    }

    modifier givenNoTimeHasPassed { _; }

    modifier givenSomeTimeHasPassed() {
        skip(WARP_TIME);
        _;
    }

    modifier givenNoActiveBorrow { _; }

    modifier givenActiveBorrow {
        // Allow borrowAsset to be collateral to demo collateralAsset accruing interest
        _initCollateral({
            asset:                address(borrowAsset),
            ltv:                  50_00,
            liquidationThreshold: 6000,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);

        address borrower = makeAddr("borrower");
        _supplyAndUseAsCollateral(borrower, address(borrowAsset), 1000 ether);
        _borrow(borrower, address(collateralAsset), 100 ether);
        _;
    }

    modifier givenNoTimeHasPassedAfterBorrow {
        assertGt(IERC20(debtToken).totalSupply(), 0);
        _;
    }

    modifier givenSomeTimeHasPassedAfterBorrow {
        assertGt(IERC20(debtToken).totalSupply(), 0);
        skip(WARP_TIME);
        _;
    }

    modifier givenUserHasActiveCollateral {
        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 60_00,
            liquidationBonus:     100_01
        });

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), true);
        _;
    }

    function test_withdraw_01()
        givenNoTimeHasPassed
        givenNoActiveBorrow
        public
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.05e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 1000 ether, user);

        aTokenParams.userBalance = 0;
        aTokenParams.totalSupply = 0;

        assetParams.userBalance   = 1000 ether;
        assetParams.aTokenBalance = 0;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_02()
        givenNoTimeHasPassed
        givenActiveBorrow
        givenNoTimeHasPassedAfterBorrow
        public
    {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1000 ether);

        assertEq(borrowRate,    0.0525e27);     // 5% + 10%/80% of 2% = 5.25%
        assertEq(liquidityRate, 0.0049875e27);  // 10% of 5.25%

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 900 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 800 ether, user);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether, 200 ether);

        assertEq(borrowRate,    0.0625e27);          // 5% + 50%/80% of 2% = 6.25%
        assertEq(liquidityRate, 0.03125e27 * 0.95);  // 50% of 6.25% = 3.125%

        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.currentVariableBorrowRate = borrowRate;

        aTokenParams.userBalance = 200 ether;
        aTokenParams.totalSupply = 200 ether;

        assetParams.userBalance   = 800 ether;
        assetParams.aTokenBalance = 100 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_03()
        givenNoTimeHasPassed
        givenActiveBorrow
        givenSomeTimeHasPassedAfterBorrow
        public
    {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1000 ether);

        assertEq(borrowRate,    0.0525e27);     // 5% + 10%/80% of 2% = 5.25%
        assertEq(liquidityRate, 0.0049875e27);  // 10% of 5.25%

        uint256 supplierYield = 0.0049875e27 * 1000 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 100 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.049875 ether);
        assertEq(compoundedNormalizedInterest, 1.00052513783297156325067096e27);
        assertEq(borrowerDebt,                 0.052513783297156325 ether);

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether + supplierYield,
            totalSupply: 1000 ether + supplierYield
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 900 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 800 ether, user);

        // Update indexes using old rates info
        uint256 expectedLiquidityIndex      = 1e27 + (liquidityRate * 1/100);              // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.000049875e27);
        assertEq(expectedVariableBorrowIndex, 1.000525137832971563250670960e27);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether + borrowerDebt, 200 ether + borrowerDebt);

        // Slightly higher now because utilization is higher (last test was 5% + 50%/80% of 2% = 6.25%)
        assertEq(borrowRate,    0.062503281249901840824889794e27);
        assertEq(liquidityRate, 0.031259844180369559207886302e27 * uint256(95)/100);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.currentLiquidityRate      = liquidityRate + 2;  // Rounding
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentVariableBorrowRate = borrowRate + 1;  // Rounding
        poolParams.lastUpdateTimestamp       = WARP_TIME + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex + 1;  // Rounding

        aTokenParams.userBalance = 200 ether + supplierYield;
        aTokenParams.totalSupply = 200 ether + supplierYield;

        assetParams.userBalance   = 800 ether;
        assetParams.aTokenBalance = 100 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_04()
        givenSomeTimeHasPassed
        givenNoActiveBorrow
        public
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.05e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 1000 ether, user);

        poolParams.lastUpdateTimestamp = WARP_TIME + 1;

        aTokenParams.userBalance = 0;
        aTokenParams.totalSupply = 0;

        assetParams.userBalance   = 1000 ether;
        assetParams.aTokenBalance = 0;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_05()
        givenSomeTimeHasPassed
        givenActiveBorrow
        givenNoTimeHasPassedAfterBorrow
        public
    {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1000 ether);

        assertEq(borrowRate,    0.0525e27);     // 5% + 10%/80% of 2% = 5.25%
        assertEq(liquidityRate, 0.0049875e27);  // 10% of 5.25% * 95%

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       WARP_TIME + 1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 900 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 800 ether, user);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether, 200 ether);

        assertEq(borrowRate,    0.0625e27);          // 5% + 50%/80% of 2% = 6.25%
        assertEq(liquidityRate, 0.03125e27 * 0.95);  // 50% of 6.25% = 3.125%

        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.currentVariableBorrowRate = borrowRate;

        aTokenParams.userBalance = 200 ether;
        aTokenParams.totalSupply = 200 ether;

        assetParams.userBalance   = 800 ether;
        assetParams.aTokenBalance = 100 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_06()
        givenSomeTimeHasPassed
        givenActiveBorrow
        givenSomeTimeHasPassedAfterBorrow
        public
    {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1000 ether);

        assertEq(borrowRate,    0.0525e27);     // 5% + 10%/80% of 2% = 5.25%
        assertEq(liquidityRate, 0.0049875e27);  // 10% of 5.25% * 95%

        uint256 supplierYield = 0.0049875e27 * 1000 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 100 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.049875 ether);  // 95% of 0.0525
        assertEq(compoundedNormalizedInterest, 1.00052513783297156325067096e27);
        assertEq(borrowerDebt,                 0.052513783297156325 ether);

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       WARP_TIME + 1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether + supplierYield,
            totalSupply: 1000 ether + supplierYield
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 900 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 800 ether, user);

        // Update indexes using old rates info
        uint256 expectedLiquidityIndex      = 1e27 + (liquidityRate * 1/100);              // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.000049875e27);
        assertEq(expectedVariableBorrowIndex, 1.000525137832971563250670960e27);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether + borrowerDebt, 200 ether + borrowerDebt);

        // Slightly higher now because utilization is higher (last test was 5% + 50%/80% of 2% = 6.25%)
        assertEq(borrowRate,    0.062503281249901840824889794e27);
        assertEq(liquidityRate, 0.031259844180369559207886302e27 * uint256(95)/100);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.currentLiquidityRate      = liquidityRate + 2;  // Rounding
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentVariableBorrowRate = borrowRate + 1;  // Rounding
        poolParams.lastUpdateTimestamp       = WARP_TIME * 2 + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex + 1;  // Rounding

        aTokenParams.userBalance = 200 ether + supplierYield;
        aTokenParams.totalSupply = 200 ether + supplierYield;

        assetParams.userBalance   = 800 ether;
        assetParams.aTokenBalance = 100 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_07()
        public
        givenUserHasActiveCollateral
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.05e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(0), true);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), type(uint256).max, user);

        aTokenParams.userBalance = 0;
        aTokenParams.totalSupply = 0;

        assetParams.userBalance   = 1000 ether;
        assetParams.aTokenBalance = 0;

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(0), false);

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_08()
        public
        givenUserHasActiveCollateral
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.05e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(0), true);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 1000 ether, user);

        aTokenParams.userBalance = 0;
        aTokenParams.totalSupply = 0;

        assetParams.userBalance   = 1000 ether;
        assetParams.aTokenBalance = 0;

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(0), false);

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_withdraw_09()
        public
        givenUserHasActiveCollateral
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.05e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(0), true);

        vm.prank(user);
        pool.withdraw(address(collateralAsset), 1000 ether - 1, user);

        aTokenParams.userBalance = 1;
        aTokenParams.totalSupply = 1;

        assetParams.userBalance   = 1000 ether - 1;
        assetParams.aTokenBalance = 1;

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(0), true);

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

}
