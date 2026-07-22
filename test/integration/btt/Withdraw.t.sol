// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { DataTypes } from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

import { ReserveConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import { UserConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";

import { Errors } from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";
import { WadRayMath } from "sparklend-v1-core/contracts/protocol/libraries/math/WadRayMath.sol";

import { IScaledBalanceToken } from "sparklend-v1-core/contracts/interfaces/IScaledBalanceToken.sol";

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
    using WadRayMath for uint256;

    address debtToken;

    address accrualBorrower = makeAddr("accrualBorrower");
    address otherHolder     = makeAddr("otherHolder");

    uint256 accrualStartTimestamp;
    uint256 accruedTimestamp;

    uint256 constant ACCRUED_LIQUIDITY_INDEX        = 1.00002434375e27;
    uint256 constant ACCRUED_VARIABLE_BORROW_INDEX  = 1.000512631348617116930235440e27;
    uint256 constant ACCRUED_VARIABLE_DEBT          = 100.051263134861711693 ether;
    uint256 constant FULL_VISIBLE_BALANCE           = 1000.02434375 ether;
    uint256 constant SCALED_ACCRUED_TO_TREASURY     = 2_563_094_347_757_557;
    uint256 constant VISIBLE_ACCRUED_TO_TREASURY    = 0.002563156743085585 ether;
    uint256 constant VARIABLE_BORROW_RATE_BEFORE    = 0.05125e27;
    uint256 constant LIQUIDITY_RATE_BEFORE          = 0.002434375e27;
    uint256 constant VARIABLE_BORROW_RATE_AFTER_FULL = 52_501_214_247_222_600_210_652_921;
    uint256 constant LIQUIDITY_RATE_AFTER_FULL       = 4_990_037_832_722_294_508_772_975;
    uint256 constant VARIABLE_BORROW_RATE_AFTER_PARTIAL = 52_501_214_247_222_600_210_650_420;
    uint256 constant LIQUIDITY_RATE_AFTER_PARTIAL       = 4_990_037_832_722_294_508_767_747;

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

    modifier givenAccruedLiquidityIndexAboveRay {
        _initCollateral({
            asset:                address(borrowAsset),
            ltv:                  50_00,
            liquidationThreshold: 60_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);

        _supply(otherHolder, address(collateralAsset), 1000 ether);
        _supplyAndUseAsCollateral(accrualBorrower, address(borrowAsset), 1000 ether);
        _borrow(accrualBorrower, address(collateralAsset), 100 ether);

        accrualStartTimestamp = block.timestamp;
        skip(WARP_TIME);
        accruedTimestamp = block.timestamp;

        assertEq(accruedTimestamp - accrualStartTimestamp, WARP_TIME);
        assertEq(pool.getReserveNormalizedIncome(address(collateralAsset)), ACCRUED_LIQUIDITY_INDEX);
        assertGt(ACCRUED_LIQUIDITY_INDEX, 1e27);
        _;
    }

    function _assertUserAccountData(
        address account,
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 liquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) internal {
        (
            uint256 actualTotalCollateralBase,
            uint256 actualTotalDebtBase,
            uint256 actualAvailableBorrowsBase,
            uint256 actualLiquidationThreshold,
            uint256 actualLtv,
            uint256 actualHealthFactor
        ) = pool.getUserAccountData(account);

        assertEq(actualTotalCollateralBase,     totalCollateralBase,     "account.totalCollateralBase");
        assertEq(actualTotalDebtBase,           totalDebtBase,           "account.totalDebtBase");
        assertEq(actualAvailableBorrowsBase,    availableBorrowsBase,    "account.availableBorrowsBase");
        assertEq(actualLiquidationThreshold,    liquidationThreshold,    "account.liquidationThreshold");
        assertEq(actualLtv,                     ltv,                     "account.ltv");
        assertEq(actualHealthFactor,            healthFactor,            "account.healthFactor");
    }

    function _assertReserveConfigurationAndIdentity(DataTypes.ReserveData memory expected) internal {
        DataTypes.ReserveData memory actual = pool.getReserveData(address(collateralAsset));

        assertEq(actual.configuration.data,         expected.configuration.data,         "reserve.configuration");
        assertEq(actual.id,                         expected.id,                         "reserve.id");
        assertEq(actual.aTokenAddress,              expected.aTokenAddress,              "reserve.aTokenAddress");
        assertEq(actual.stableDebtTokenAddress,     expected.stableDebtTokenAddress,     "reserve.stableDebtTokenAddress");
        assertEq(actual.variableDebtTokenAddress,   expected.variableDebtTokenAddress,   "reserve.variableDebtTokenAddress");
        assertEq(actual.interestRateStrategyAddress, expected.interestRateStrategyAddress, "reserve.interestRateStrategyAddress");
        assertEq(actual.isolationModeTotalDebt,     expected.isolationModeTotalDebt,     "reserve.isolationModeTotalDebt");
    }

    function _assertReserveConfigurationPreconditions(DataTypes.ReserveData memory reserve) internal {
        ( uint256 ltv, uint256 threshold, uint256 bonus, uint256 decimals, uint256 reserveFactor, uint256 eMode )
            = reserve.configuration.getParams();
        assertEq(ltv,           50_00);
        assertEq(threshold,     60_00);
        assertEq(bonus,         100_01);
        assertEq(decimals,      18);
        assertEq(reserveFactor, 5_00);
        assertEq(eMode,         0);

        ( bool active, bool frozen, bool borrowing, bool stableBorrowing, bool paused )
            = reserve.configuration.getFlags();
        assertTrue(active);
        assertFalse(frozen);
        assertTrue(borrowing);
        assertFalse(stableBorrowing);
        assertFalse(paused);
    }

    function _deriveCompoundedInterest(uint256 rate, uint256 elapsed)
        internal pure returns (uint256 compoundedInterest)
    {
        uint256 elapsedMinusOne = elapsed - 1;
        uint256 elapsedMinusTwo = elapsed > 2 ? elapsed - 2 : 0;
        uint256 basePowerTwo = rate.rayMul(rate) / (365 days * 365 days);
        uint256 basePowerThree = basePowerTwo.rayMul(rate) / 365 days;
        uint256 secondTerm = elapsed * elapsedMinusOne * basePowerTwo / 2;
        uint256 thirdTerm = elapsed * elapsedMinusOne * elapsedMinusTwo * basePowerThree / 6;

        compoundedInterest = 1e27 + rate * elapsed / 365 days + secondTerm + thirdTerm;
    }

    function _assertAccruedMath() internal {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 2000 ether);
        uint256 elapsed = accruedTimestamp - accrualStartTimestamp;
        uint256 compoundedInterest = _deriveCompoundedInterest(borrowRate, elapsed);
        uint256 variableBorrowIndex = compoundedInterest.rayMul(1e27);
        uint256 previousVariableDebt = uint256(100 ether).rayMul(1e27);
        uint256 variableDebt = uint256(100 ether).rayMul(variableBorrowIndex);
        uint256 debtInterest = variableDebt - previousVariableDebt;
        uint256 amountToTreasury = (debtInterest * 5_00 + 5_000) / 10_000;
        uint256 scaledTreasury = amountToTreasury.rayDiv(ACCRUED_LIQUIDITY_INDEX);

        assertEq(elapsed,             WARP_TIME);
        assertEq(borrowRate,          VARIABLE_BORROW_RATE_BEFORE);
        assertEq(liquidityRate,       LIQUIDITY_RATE_BEFORE);
        assertEq(compoundedInterest,  ACCRUED_VARIABLE_BORROW_INDEX);
        assertEq(variableBorrowIndex, ACCRUED_VARIABLE_BORROW_INDEX);
        assertEq(previousVariableDebt, 100 ether);
        assertEq(variableDebt,        ACCRUED_VARIABLE_DEBT);
        assertEq(amountToTreasury,    VISIBLE_ACCRUED_TO_TREASURY);
        assertEq(scaledTreasury,      SCALED_ACCRUED_TO_TREASURY);
    }

    function _assertAccruedWithdrawStateBefore()
        internal returns (DataTypes.ReserveData memory reserveBefore)
    {
        _assertAccruedMath();

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      LIQUIDITY_RATE_BEFORE,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: VARIABLE_BORROW_RATE_BEFORE,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       accrualStartTimestamp,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory userATokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: FULL_VISIBLE_BALANCE,
            totalSupply: 2000.0486875 ether
        });

        AssertATokenStateParams memory otherATokenParams = AssertATokenStateParams({
            user:        otherHolder,
            aToken:      address(aCollateralAsset),
            userBalance: FULL_VISIBLE_BALANCE,
            totalSupply: 2000.0486875 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1900 ether
        });

        AssertDebtTokenStateParams memory debtParams = AssertDebtTokenStateParams({
            user:        accrualBorrower,
            debtToken:   debtToken,
            userBalance: ACCRUED_VARIABLE_DEBT,
            totalSupply: ACCRUED_VARIABLE_DEBT
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(userATokenParams);
        _assertATokenState(otherATokenParams);
        _assertAssetState(assetParams);
        _assertDebtTokenState(debtParams);

        assertEq(aCollateralAsset.scaledBalanceOf(user),        1000 ether);
        assertEq(aCollateralAsset.scaledBalanceOf(otherHolder), 1000 ether);
        assertEq(aCollateralAsset.scaledTotalSupply(),           2000 ether);
        assertEq(aCollateralAsset.getPreviousIndex(user),        1e27);
        assertEq(aCollateralAsset.getPreviousIndex(otherHolder), 1e27);
        assertEq(aCollateralAsset.scaledBalanceOf(treasury),     0);
        assertEq(aCollateralAsset.balanceOf(treasury),           0);
        assertEq(IScaledBalanceToken(debtToken).scaledBalanceOf(accrualBorrower), 100 ether);
        assertEq(IScaledBalanceToken(debtToken).scaledTotalSupply(),       100 ether);
        assertEq(IScaledBalanceToken(debtToken).getPreviousIndex(accrualBorrower), 1e27);
        assertEq(collateralAsset.balanceOf(accrualBorrower), 100 ether);
        assertEq(collateralAsset.balanceOf(otherHolder), 0);
        assertEq(collateralAsset.allowance(otherHolder, address(pool)), 0);

        assertEq(pool.getUserConfiguration(user).data,        2);
        assertEq(pool.getUserConfiguration(otherHolder).data, 0);
        assertEq(pool.getUserConfiguration(accrualBorrower).data, 9);
        _assertUserAccountData(user, 100_002_434_375, 0, 50_001_217_188, 60_00, 50_00, type(uint256).max);
        _assertUserAccountData(otherHolder, 0, 0, 0, 0, 0, type(uint256).max);
        _assertUserAccountData(
            accrualBorrower,
            100_000_000_000,
            10_005_126_313,
            39_994_873_687,
            60_00,
            50_00,
            5_996_925_788_137_223_690
        );

        reserveBefore = pool.getReserveData(address(collateralAsset));
        assertEq(reserveBefore.id, 0);
        assertEq(reserveBefore.isolationModeTotalDebt, 0);
        assertEq(reserveBefore.variableDebtTokenAddress, debtToken);
        assertEq(reserveBefore.aTokenAddress, address(aCollateralAsset));
        assertTrue(reserveBefore.interestRateStrategyAddress != address(0));
        _assertReserveConfigurationPreconditions(reserveBefore);
    }

    function _deriveRatesAfterWithdraw(uint256 amount)
        internal pure returns (uint256 variableBorrowRate, uint256 liquidityRate)
    {
        uint256 availableLiquidity = 1900 ether - amount;
        uint256 utilization = ACCRUED_VARIABLE_DEBT.rayDiv(availableLiquidity + ACCRUED_VARIABLE_DEBT);

        variableBorrowRate = BASE_RATE + SLOPE1.rayMul(utilization).rayDiv(OPTIMAL_RATIO);
        liquidityRate = (variableBorrowRate.rayMul(utilization) * 95_00 + 5_000) / 10_000;
    }

    function _assertAccruedWithdrawStateAfter(
        DataTypes.ReserveData memory reserveBefore,
        uint256 amount,
        uint256 remainingScaledBalance,
        bool collateralEnabled,
        uint256 expectedVariableBorrowRate,
        uint256 expectedLiquidityRate
    ) internal {
        ( uint256 derivedVariableBorrowRate, uint256 derivedLiquidityRate ) = _deriveRatesAfterWithdraw(amount);

        assertEq(derivedVariableBorrowRate, expectedVariableBorrowRate);
        assertEq(derivedLiquidityRate,      expectedLiquidityRate);

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            ACCRUED_LIQUIDITY_INDEX,
            currentLiquidityRate:      expectedLiquidityRate,
            variableBorrowIndex:       ACCRUED_VARIABLE_BORROW_INDEX,
            currentVariableBorrowRate: expectedVariableBorrowRate,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       accruedTimestamp,
            accruedToTreasury:         SCALED_ACCRUED_TO_TREASURY,
            unbacked:                  0
        });

        AssertATokenStateParams memory userATokenParams = AssertATokenStateParams({
            user:        user,
            aToken:      address(aCollateralAsset),
            userBalance: remainingScaledBalance.rayMul(ACCRUED_LIQUIDITY_INDEX),
            totalSupply: (1000 ether + remainingScaledBalance).rayMul(ACCRUED_LIQUIDITY_INDEX)
        });

        AssertATokenStateParams memory otherATokenParams = AssertATokenStateParams({
            user:        otherHolder,
            aToken:      address(aCollateralAsset),
            userBalance: FULL_VISIBLE_BALANCE,
            totalSupply: userATokenParams.totalSupply
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          user,
            asset:         address(collateralAsset),
            allowance:     0,
            userBalance:   amount,
            aTokenBalance: 1900 ether - amount
        });

        AssertDebtTokenStateParams memory debtParams = AssertDebtTokenStateParams({
            user:        accrualBorrower,
            debtToken:   debtToken,
            userBalance: ACCRUED_VARIABLE_DEBT,
            totalSupply: ACCRUED_VARIABLE_DEBT
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(userATokenParams);
        _assertATokenState(otherATokenParams);
        _assertAssetState(assetParams);
        _assertDebtTokenState(debtParams);
        _assertReserveConfigurationAndIdentity(reserveBefore);

        assertEq(pool.getReserveNormalizedIncome(address(collateralAsset)), ACCRUED_LIQUIDITY_INDEX);
        assertEq(aCollateralAsset.scaledBalanceOf(user),        remainingScaledBalance);
        assertEq(aCollateralAsset.scaledBalanceOf(otherHolder), 1000 ether);
        assertEq(aCollateralAsset.scaledTotalSupply(),           1000 ether + remainingScaledBalance);
        assertEq(aCollateralAsset.getPreviousIndex(user),        ACCRUED_LIQUIDITY_INDEX);
        assertEq(aCollateralAsset.getPreviousIndex(otherHolder), 1e27);
        assertEq(aCollateralAsset.scaledBalanceOf(treasury),     0);
        assertEq(aCollateralAsset.balanceOf(treasury),           0);
        assertEq(SCALED_ACCRUED_TO_TREASURY.rayMul(ACCRUED_LIQUIDITY_INDEX), VISIBLE_ACCRUED_TO_TREASURY);
        assertEq(IScaledBalanceToken(debtToken).scaledBalanceOf(accrualBorrower), 100 ether);
        assertEq(IScaledBalanceToken(debtToken).scaledTotalSupply(),       100 ether);
        assertEq(IScaledBalanceToken(debtToken).getPreviousIndex(accrualBorrower), 1e27);
        assertEq(collateralAsset.balanceOf(accrualBorrower), 100 ether);
        assertEq(collateralAsset.balanceOf(otherHolder), 0);
        assertEq(collateralAsset.allowance(otherHolder, address(pool)), 0);

        assertEq(pool.getUserConfiguration(user).data,        collateralEnabled ? 2 : 0);
        assertEq(pool.getUserConfiguration(otherHolder).data, 0);
        assertEq(pool.getUserConfiguration(accrualBorrower).data, 9);
        _assertUserAccountData(user, 0, 0, 0, 0, 0, type(uint256).max);
        _assertUserAccountData(otherHolder, 0, 0, 0, 0, 0, type(uint256).max);
        _assertUserAccountData(
            accrualBorrower,
            100_000_000_000,
            10_005_126_313,
            39_994_873_687,
            60_00,
            50_00,
            5_996_925_788_137_223_690
        );
        assertEq(
            pool.getUserConfiguration(user).isUsingAsCollateral(reserveBefore.id),
            collateralEnabled
        );
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

    function test_withdraw_10()
        public
        givenAccruedLiquidityIndexAboveRay
        givenUserHasActiveCollateral
    {
        DataTypes.ReserveData memory reserveBefore = _assertAccruedWithdrawStateBefore();

        assertEq(aCollateralAsset.balanceOf(user), FULL_VISIBLE_BALANCE);

        vm.prank(user);
        uint256 withdrawn = pool.withdraw(address(collateralAsset), type(uint256).max, user);

        assertEq(withdrawn, FULL_VISIBLE_BALANCE);
        _assertAccruedWithdrawStateAfter({
            reserveBefore:               reserveBefore,
            amount:                      FULL_VISIBLE_BALANCE,
            remainingScaledBalance:      0,
            collateralEnabled:           false,
            expectedVariableBorrowRate:  VARIABLE_BORROW_RATE_AFTER_FULL,
            expectedLiquidityRate:       LIQUIDITY_RATE_AFTER_FULL
        });
    }

    function test_withdraw_11()
        public
        givenAccruedLiquidityIndexAboveRay
        givenUserHasActiveCollateral
    {
        DataTypes.ReserveData memory reserveBefore = _assertAccruedWithdrawStateBefore();
        uint256 fullVisibleBalance = aCollateralAsset.scaledBalanceOf(user).rayMul(
            ACCRUED_LIQUIDITY_INDEX
        );

        assertEq(fullVisibleBalance, FULL_VISIBLE_BALANCE);
        assertEq(fullVisibleBalance, aCollateralAsset.balanceOf(user));
        assertEq(fullVisibleBalance.rayDiv(ACCRUED_LIQUIDITY_INDEX), 1000 ether);

        vm.prank(user);
        uint256 withdrawn = pool.withdraw(address(collateralAsset), fullVisibleBalance, user);

        assertEq(withdrawn, FULL_VISIBLE_BALANCE);
        _assertAccruedWithdrawStateAfter({
            reserveBefore:               reserveBefore,
            amount:                      FULL_VISIBLE_BALANCE,
            remainingScaledBalance:      0,
            collateralEnabled:           false,
            expectedVariableBorrowRate:  VARIABLE_BORROW_RATE_AFTER_FULL,
            expectedLiquidityRate:       LIQUIDITY_RATE_AFTER_FULL
        });
    }

    function test_withdraw_12()
        public
        givenAccruedLiquidityIndexAboveRay
        givenUserHasActiveCollateral
    {
        DataTypes.ReserveData memory reserveBefore = _assertAccruedWithdrawStateBefore();
        uint256 startingScaledBalance = aCollateralAsset.scaledBalanceOf(user);
        uint256 scaledAmountToBurn = startingScaledBalance - 1;
        uint256 partialAmount = scaledAmountToBurn.rayMul(ACCRUED_LIQUIDITY_INDEX);

        assertEq(startingScaledBalance, 1000 ether);
        assertEq(scaledAmountToBurn,    999_999_999_999_999_999_999);
        assertEq(partialAmount,         1000.024343749999999999 ether);
        assertEq(partialAmount,         FULL_VISIBLE_BALANCE - 1);
        assertEq(partialAmount.rayDiv(ACCRUED_LIQUIDITY_INDEX), scaledAmountToBurn);

        // TODO(core 8120e495): an adjacent near-full amount can burn all scaled balance without disabling collateral.

        vm.prank(user);
        uint256 withdrawn = pool.withdraw(address(collateralAsset), partialAmount, user);

        assertEq(withdrawn, partialAmount);
        _assertAccruedWithdrawStateAfter({
            reserveBefore:               reserveBefore,
            amount:                      partialAmount,
            remainingScaledBalance:      1,
            collateralEnabled:           true,
            expectedVariableBorrowRate:  VARIABLE_BORROW_RATE_AFTER_PARTIAL,
            expectedLiquidityRate:       LIQUIDITY_RATE_AFTER_PARTIAL
        });
    }

}
