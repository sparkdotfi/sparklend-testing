// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { Errors } from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract RepayWithATokensTestBase is SparkLendTestBase {

    address borrower = makeAddr("borrower");
    address lender   = makeAddr("lender");

    function setUp() public virtual override {
        super.setUp();

        vm.label(borrower, "borrower");

        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  5000,
            liquidationThreshold: 5000,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), true);

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);
        _supply(borrower, address(borrowAsset), 1000 ether);  // Supply to get aTokens
        _borrow(borrower, address(borrowAsset), 500 ether);
    }

}

contract RepayWithATokensFailureTests is RepayWithATokensTestBase {

    function test_repayWithATokens_whenAmountZero() public virtual {
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        pool.repayWithATokens(address(borrowAsset), 0, 2);
    }

    function test_repayWithATokens_whenNotActive() public virtual {
        _repay(borrower, address(borrowAsset), 500 ether);
        _withdraw(borrower, address(borrowAsset), 1000 ether);

        vm.prank(admin);
        poolConfigurator.setReserveActive(address(borrowAsset), false);

        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        pool.repayWithATokens(address(borrowAsset), 500 ether, 2);
    }

    function test_repayWithATokens_whenPaused() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(address(borrowAsset), true);

        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        pool.repayWithATokens(address(borrowAsset), 500 ether, 2);
    }

    function test_repayWithATokens_success_whenFrozen() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(address(borrowAsset), true);

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), 500 ether, 2);
    }

    function test_repayWithATokens_noDebt() public virtual {
        vm.expectRevert(bytes(Errors.NO_DEBT_OF_SELECTED_TYPE));
        pool.repayWithATokens(address(borrowAsset), 500 ether, 2);
    }

}

contract RepayWithATokensConcreteTests is RepayWithATokensTestBase {

    address debtToken;

    function setUp() public virtual override {
        super.setUp();
        debtToken = pool.getReserveData(address(borrowAsset)).variableDebtTokenAddress;
    }

    modifier givenNoTimeHasPassedSinceBorrow { _; }

    modifier givenSomeTimeHasPassedSinceBorrow() {
        skip(WARP_TIME);
        _;
    }

    modifier givenNotInIsolationMode { _; }

    modifier givenInIsolationMode {
        // Remove liquidity so initial DC can be set
        _repay(borrower, address(borrowAsset), 500 ether);
        _withdraw(borrower, address(collateralAsset), 1000 ether);

        vm.startPrank(admin);
        poolConfigurator.setBorrowableInIsolation(address(borrowAsset), true);
        poolConfigurator.setDebtCeiling(address(collateralAsset), 1000_00);
        vm.stopPrank();

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);  // Don't have to useAsCollateral again
        _borrow(borrower, address(borrowAsset), 500 ether);
        _;
    }

    function test_repayWithATokens_01()
        givenNotInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayMoreThanDebtNoTimePassedTest({ useMaxUint: false });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_02()
        givenNotInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayMoreThanDebtNoTimePassedTest({ useMaxUint: true });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_03()
        givenNotInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayEqualToDebtNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_04()
        givenNotInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayLessThanDebtNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_05()
        givenNotInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayMoreThanDebtSomeTimePassedTest({ useMaxUint: false });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_06()
        givenNotInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayMoreThanDebtSomeTimePassedTest({ useMaxUint: true });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_07()
        givenNotInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayEqualToDebtSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_08()
        givenNotInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _repayLessThanDebtSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_09()
        givenInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayMoreThanDebtNoTimePassedTest({ useMaxUint: false });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_10()
        givenInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayMoreThanDebtNoTimePassedTest({ useMaxUint: true });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_11()
        givenInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayEqualToDebtNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_12()
        givenInIsolationMode
        givenNoTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayLessThanDebtNoTimePassedTest();

        // NOTE: Repaid 500 ether - 1, but since repaid debt is rounded down, the
        //       isolationModeTotalDebt is 0.01 ether.
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 1);
    }

    function test_repayWithATokens_13()
        givenInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayMoreThanDebtSomeTimePassedTest({ useMaxUint: false });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_14()
        givenInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayMoreThanDebtSomeTimePassedTest({ useMaxUint: true });

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }


    function test_repayWithATokens_15()
        givenInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayEqualToDebtSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_repayWithATokens_16()
        givenInIsolationMode
        givenSomeTimeHasPassedSinceBorrow
        public
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 500_00);

        _repayLessThanDebtSomeTimePassedTest();

        // NOTE: When a user repays iso debt and debt has accrued, meaning there is more debt
        //       than whats saved in storage, they can pay back the debt between the original
        //       and the current amount, and the debt will be overwritten to zero. In this example
        //       it's paying back 501.85 of iso debt when there is 500 in storage.
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    /**********************************************************************************************/
    /*** Test running functions                                                                 ***/
    /**********************************************************************************************/

    function _repayMoreThanDebtNoTimePassedTest(bool useMaxUint) internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0.0296875e27,  // 3.125% * 95%
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.0625e27,  // 5% + 2% * (50%/80%)
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 500 ether,
            totalSupply: 500 ether
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        borrower,
            aToken:      address(aBorrowAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);

        uint256 amount = useMaxUint ? type(uint256).max : 500 ether + 1;

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), amount, 2);

        // No more outstanding debt
        poolParams.currentLiquidityRate      = 0;
        poolParams.currentVariableBorrowRate = 0.05e27;

        debtTokenParams.userBalance = 0;
        debtTokenParams.totalSupply = 0;

        aTokenParams.userBalance = 500 ether;  // Paid back 500 ether, not including +1
        aTokenParams.totalSupply = 500 ether;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);
    }

    function _repayEqualToDebtNoTimePassedTest() internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0.0296875e27,  // 3.125% * 95%
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.0625e27,  // 5% + 2% * (50%/80%)
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 500 ether,
            totalSupply: 500 ether
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        borrower,
            aToken:      address(aBorrowAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), 500 ether + 1, 2);

        // No more outstanding debt
        poolParams.currentLiquidityRate      = 0;
        poolParams.currentVariableBorrowRate = 0.05e27;

        debtTokenParams.userBalance = 0;
        debtTokenParams.totalSupply = 0;

        aTokenParams.userBalance = 500 ether;  // Paid back 500 ether
        aTokenParams.totalSupply = 500 ether;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);
    }

    function _repayLessThanDebtNoTimePassedTest() internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0.0296875e27,  // 3.125% * 95%
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.0625e27,  // 5% + 2% * (50%/80%)
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 500 ether,
            totalSupply: 500 ether
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        borrower,
            aToken:      address(aBorrowAsset),
            userBalance: 1000 ether,
            totalSupply: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), 500 ether - 1, 2);

        poolParams.currentLiquidityRate      = 1e5 * 0.95;     // 1/500e18 = 2e-21 => 2e-21 * (0.05e27 + 5e4) = 1e5 in ray
        poolParams.currentVariableBorrowRate = 0.05e27 + 5e4;  // 1/500e18 = 2e-21 => 2e-21/0.8 * 0.02 = 5e-23 = 5e4 in ray

        debtTokenParams.userBalance = 1;
        debtTokenParams.totalSupply = 1;

        aTokenParams.userBalance = 500 ether + 1;  // Paid back 500 ether - 1
        aTokenParams.totalSupply = 500 ether + 1;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);
    }

    function _repayMoreThanDebtSomeTimePassedTest(bool useMaxUint) internal {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(500 ether, 1000 ether);

        assertEq(borrowRate,    0.0625e27);
        assertEq(liquidityRate, 0.0296875e27);

        uint256 supplierYield = 0.0296875e27 * 1000 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 500 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.296875 ether);  // 1000 * 0.0296875 * 1%
        assertEq(compoundedNormalizedInterest, 1.000625195348470672890933200e27);
        assertEq(borrowerDebt,                 0.312597674235336445 ether);

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,  // 5% + 2% * (50%/80%)
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 500 ether + borrowerDebt + 1,
            totalSupply: 500 ether + borrowerDebt + 1
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        borrower,
            aToken:      address(aBorrowAsset),
            userBalance: 1000 ether + supplierYield,
            totalSupply: 1000 ether + supplierYield
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);

        uint256 amount = useMaxUint ? type(uint256).max : 500 ether + borrowerDebt + 1;

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), amount, 2);

        uint256 expectedLiquidityIndex      = 1e27 + (1e27 * liquidityRate / 100 / 1e27);  // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.000296875e27);
        assertEq(expectedVariableBorrowIndex, 1.000625195348470672890933200e27);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentLiquidityRate      = 0;
        poolParams.currentVariableBorrowRate = 0.05e27;
        poolParams.lastUpdateTimestamp       = WARP_TIME + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex;  // Scaled value

        debtTokenParams.userBalance = 0;
        debtTokenParams.totalSupply = 0;

        aTokenParams.userBalance = (1000 ether + supplierYield - 1) - (500 ether + borrowerDebt + 1);
        aTokenParams.totalSupply = (1000 ether + supplierYield - 1) - (500 ether + borrowerDebt + 1);

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);
    }

    function _repayEqualToDebtSomeTimePassedTest() internal {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(500 ether, 1000 ether);

        assertEq(borrowRate,    0.0625e27);
        assertEq(liquidityRate, 0.0296875e27);

        uint256 supplierYield = 0.0296875e27 * 1000 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 500 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.296875 ether);  // 1000 * 0.0296875 * 1%
        assertEq(compoundedNormalizedInterest, 1.000625195348470672890933200e27);
        assertEq(borrowerDebt,                 0.312597674235336445 ether);

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,  // 5% + 2% * (50%/80%)
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 500 ether + borrowerDebt + 1,  // rayMulCeil
            totalSupply: 500 ether + borrowerDebt + 1
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        borrower,
            aToken:      address(aBorrowAsset),
            userBalance: 1000 ether + supplierYield,
            totalSupply: 1000 ether + supplierYield
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), 500 ether + borrowerDebt, 2);

        uint256 expectedLiquidityIndex      = 1e27 + (1e27 * liquidityRate / 100 / 1e27);  // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.000296875e27);
        assertEq(expectedVariableBorrowIndex, 1.000625195348470672890933200e27);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        // Floor repay leaves 1 scaled unit; rates use half-up totalDebt=1
        poolParams.currentLiquidityRate      = 1e5 * 0.95;
        poolParams.currentVariableBorrowRate = 0.05e27 + 5e4;
        poolParams.lastUpdateTimestamp       = WARP_TIME + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex;  // Scaled value

        debtTokenParams.userBalance = 2;  // 1 scaled * rayMulCeil
        debtTokenParams.totalSupply = 2;

        aTokenParams.userBalance = (1000 ether + supplierYield) - (500 ether + borrowerDebt) - 1;  // rayMulFloor
        aTokenParams.totalSupply = (1000 ether + supplierYield) - (500 ether + borrowerDebt) - 1;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);
    }

    function _repayLessThanDebtSomeTimePassedTest() internal {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(500 ether, 1000 ether);

        assertEq(borrowRate,    0.0625e27);
        assertEq(liquidityRate, 0.0296875e27);

        uint256 supplierYield = 0.0296875e27 * 1000 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 500 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.296875 ether);  // 1000 * 0.0296875 * 1%
        assertEq(compoundedNormalizedInterest, 1.000625195348470672890933200e27);
        assertEq(borrowerDebt,                 0.312597674235336445 ether);

        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,  // 5% + 2% * (50%/80%)
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 500 ether + borrowerDebt + 1,  // rayMulCeil
            totalSupply: 500 ether + borrowerDebt + 1
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        borrower,
            aToken:      address(aBorrowAsset),
            userBalance: 1000 ether + supplierYield,
            totalSupply: 1000 ether + supplierYield
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);

        vm.prank(borrower);
        pool.repayWithATokens(address(borrowAsset), 500 ether + borrowerDebt - 1, 2);

        uint256 expectedLiquidityIndex      = 1e27 + (1e27 * liquidityRate / 100 / 1e27);  // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.000296875e27);
        assertEq(expectedVariableBorrowIndex, 1.000625195348470672890933200e27);

        uint256 remainingSupply = (1000 ether + supplierYield) - (500 ether + borrowerDebt - 1);

        assertEq(remainingSupply, 499.984277325764663556 ether);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(1, remainingSupply);

        liquidityRate -= 2;  // Rounding
        borrowRate    -= 1;  // Rounding

        // Diff from 500 is small enough that it rounds to clean numbers here (unlike repay tests where full utilization caused more debt)
        assertEq(borrowRate,    0.050000000000000000000050000e27);  // 1 / 499.999902325764663556e18 = 2e-21 => 2e-21/0.8 * 0.02 = 5e4 in ray (rounding)
        assertEq(liquidityRate, 0.000000000000000000000095000e27);  // 1 / 499.999902325764663556e18 = 2e-21 => 2e-21 * (0.05e27 + 5e4) = 1e5 in ray (rounding)

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentLiquidityRate      = 2e5 * 0.95;     // ~2/500e18 utilization
        poolParams.currentVariableBorrowRate = 0.05e27 + 1e5;
        poolParams.lastUpdateTimestamp       = WARP_TIME + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex;  // Scaled value

        debtTokenParams.userBalance = 3;  // 2 scaled * rayMulCeil
        debtTokenParams.totalSupply = 3;

        aTokenParams.userBalance = remainingSupply - 1;  // rayMulFloor
        aTokenParams.totalSupply = remainingSupply - 1;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertATokenState(aTokenParams);
    }

}
