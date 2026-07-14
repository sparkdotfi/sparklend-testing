// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { UserConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import { Errors }            from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";
import { DataTypes }         from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

import { MockOracleSentinel } from "test/mocks/MockOracleSentinel.sol";

contract BorrowTestBase is SparkLendTestBase {

    address borrower = makeAddr("borrower");
    address lender   = makeAddr("lender");

    function setUp() public virtual override {
        super.setUp();

        vm.label(borrower, "borrower");

        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), true);

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);
        _supply(lender, address(borrowAsset), 1000 ether);
    }

}

contract BorrowFailureTests is BorrowTestBase {

    function test_borrow_whenAmountZero() public {
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        pool.borrow(address(borrowAsset), 0, 2, 0, borrower);
    }

    function test_borrow_whenNotActive() public {
        _withdraw(lender, address(borrowAsset), 1000 ether);

        vm.prank(admin);
        poolConfigurator.setReserveActive(address(borrowAsset), false);

        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_whenPaused() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(address(borrowAsset), true);

        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_whenFrozen() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(address(borrowAsset), true);

        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_whenBorrowNotEnabled() public {
        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), false);

        vm.expectRevert(bytes(Errors.BORROWING_NOT_ENABLED));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_whenOracleSentinelNotBorrowAllowed() public {
        vm.startPrank(admin);
        poolAddressesProvider.setPriceOracleSentinel(address(new MockOracleSentinel()));
        vm.stopPrank();

        vm.expectRevert(bytes(Errors.PRICE_ORACLE_SENTINEL_CHECK_FAILED));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_invalidBorrowType() public {
        vm.expectRevert(bytes(Errors.INVALID_INTEREST_RATE_MODE_SELECTED));
        pool.borrow(address(borrowAsset), 500 ether, 0, 0, borrower);
    }

    function test_borrow_borrowCapExceededBoundary() public {
        vm.prank(admin);
        poolConfigurator.setBorrowCap(address(borrowAsset), 500);

        vm.startPrank(borrower);

        vm.expectRevert(bytes(Errors.BORROW_CAP_EXCEEDED));
        pool.borrow(address(borrowAsset), 500 ether + 1, 2, 0, borrower);

        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_userInIsolationModeAssetIsNot() external {
        // Remove liquidity so initial DC can be set
        _withdraw(borrower, address(collateralAsset), 1000 ether);

        vm.prank(admin);
        poolConfigurator.setDebtCeiling(address(collateralAsset), 500);  // Activate isolation mode

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);

        vm.expectRevert(bytes(Errors.ASSET_NOT_BORROWABLE_IN_ISOLATION));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_isolationModeDebtCeilingSurpassedBoundary() external {
        // Remove liquidity so initial DC can be set
        _withdraw(borrower, address(collateralAsset), 1000 ether);

        vm.startPrank(admin);
        poolConfigurator.setDebtCeiling(address(collateralAsset), 400_00);  // Activate isolation mode
        poolConfigurator.setBorrowableInIsolation(address(borrowAsset), true);
        vm.stopPrank();

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);

        vm.startPrank(borrower);

        // NOTE: Setting DC to 400 so LTV isn't exceeded on boundary
        vm.expectRevert(bytes(Errors.DEBT_CEILING_EXCEEDED));
        pool.borrow(address(borrowAsset), 400.01 ether, 2, 0, borrower);

        // Rounds down to 400.00 here so boundary is 400.01 ether - 1
        pool.borrow(address(borrowAsset), 400.01 ether - 1, 2, 0, borrower);
    }

    function test_borrow_emodeCategoryMismatch() external {
        vm.startPrank(admin);
        poolConfigurator.setEModeCategory({
            categoryId:           1,
            ltv:                  50_00,
            liquidationThreshold: 60_00,
            liquidationBonus:     101_00,
            oracle:               address(0),
            label:                "emode1"
        });

        poolConfigurator.setAssetEModeCategory(address(collateralAsset), 1);

        vm.stopPrank();
        vm.startPrank(borrower);

        pool.setUserEMode(1);

        vm.expectRevert(bytes(Errors.INCONSISTENT_EMODE_CATEGORY));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_userHasZeroCollateral() public {
        _withdraw(borrower, address(collateralAsset), 1000 ether);

        vm.prank(borrower);
        vm.expectRevert(bytes(Errors.COLLATERAL_BALANCE_IS_ZERO));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_userHasZeroLtv() public {
        vm.prank(admin);
        poolConfigurator.configureReserveAsCollateral(address(collateralAsset), 0, 50_00, 101_00);

        vm.prank(borrower);
        vm.expectRevert(bytes(Errors.LTV_VALIDATION_FAILED));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_userHasHealthFactorBelowZero() public {
        vm.startPrank(borrower);
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);

        vm.warp(365 days);

        vm.expectRevert(bytes(Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD));
        pool.borrow(address(borrowAsset), 1, 2, 0, borrower);
    }

    function test_borrow_userPutsPositionBelowLtvBoundary() public {
        vm.startPrank(borrower);
        vm.expectRevert(bytes(Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW));
        pool.borrow(address(borrowAsset), 500 ether + 1e10, 2, 0, borrower);

        // Rounds down to 500e8 here so boundary is 500 ether - 1e10
        pool.borrow(address(borrowAsset), 500 ether + 1e10 - 1, 2, 0, borrower);
    }

    function test_borrow_userChoosesStableBorrow() public {
        vm.startPrank(borrower);
        vm.expectRevert(bytes(Errors.STABLE_BORROWING_NOT_ENABLED));
        pool.borrow(address(borrowAsset), 500 ether, 1, 0, borrower);
    }

    function test_borrow_userSiloedAndTryingToBorrowNonSiloed() public {
        _initCollateral({
            asset:                address(borrowAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);
        poolConfigurator.setSiloedBorrowing(address(collateralAsset), true);
        vm.stopPrank();

        // Supply and borrow with the opposite assets so user is siloed borrowing
        // with collateralAsset
        _supplyAndUseAsCollateral(borrower, address(borrowAsset), 1000 ether);
        _borrow(borrower, address(collateralAsset), 500 ether);

        vm.expectRevert(bytes(Errors.SILOED_BORROWING_VIOLATION));
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);
    }

    function test_borrow_userBorrowingNonSiloedAndTryingToBorrowSiloed() public {
        address siloAsset = _setUpNewReserve();

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(siloAsset, true);
        poolConfigurator.setSiloedBorrowing(siloAsset, true);
        vm.stopPrank();

        _supply(makeAddr("supplier"), address(borrowAsset), 1 ether);
        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);
        _borrow(borrower, address(borrowAsset), 1 ether);

        vm.expectRevert(bytes(Errors.SILOED_BORROWING_VIOLATION));
        pool.borrow(siloAsset, 1 ether, 2, 0, borrower);
    }

}

contract BorrowConcreteTests is BorrowTestBase {

    using UserConfiguration for DataTypes.UserConfigurationMap;

    address debtToken;

    function setUp() public virtual override {
        super.setUp();
        debtToken = pool.getReserveData(address(borrowAsset)).variableDebtTokenAddress;
    }

    modifier whenUserIsDoingRegularBorrow { _; }

    modifier whenUserIsDoingSiloedBorrow {
        vm.prank(admin);
        poolConfigurator.setSiloedBorrowing(address(borrowAsset), true);
        _;
    }

    modifier whenUserIsDoingEModeBorrow {
        vm.startPrank(admin);
        poolConfigurator.setEModeCategory({
            categoryId:           1,
            ltv:                  50_00,
            liquidationThreshold: 60_00,
            liquidationBonus:     101_00,
            oracle:               address(0),
            label:                "emode1"
        });

        poolConfigurator.setAssetEModeCategory(address(collateralAsset), 1);
        poolConfigurator.setAssetEModeCategory(address(borrowAsset),     1);

        vm.stopPrank();

        vm.prank(borrower);
        pool.setUserEMode(1);
        _;
    }

    modifier whenUserIsDoingIsolationModeBorrow {
        // Remove liquidity so initial DC can be set
        _withdraw(borrower, address(collateralAsset), 1000 ether);

        vm.startPrank(admin);
        poolConfigurator.setDebtCeiling(address(collateralAsset), 1000_00);  // Activate isolation mode
        poolConfigurator.setBorrowableInIsolation(address(borrowAsset), true);
        vm.stopPrank();

        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);
        _;
    }

    modifier whenItIsUsersFirstBorrow { _; }

    modifier whenThereIsAnExistingBorrow {
        address borrower2 = makeAddr("borrower2");

        _supplyAndUseAsCollateral(borrower2, address(collateralAsset), 1000 ether);
        _borrow(borrower2, address(borrowAsset), 100 ether);
        _;
    }

    modifier whenNoTimeHasPassedSinceLastBorrow { _; }

    modifier whenSomeTimeHasPassedSinceLastBorrow {
        skip(WARP_TIME);
        _;
    }

    function test_borrow_01()
        public
        whenItIsUsersFirstBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _usersFirstBorrowTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    // NOTE: All `whenThereIsAnExistingBorrow` are below the borrow type modifiers
    //       because the tests won't work unless the existing borrow is made after
    //       that borrow configuration is set up.

    function test_borrow_02()
        public
        whenUserIsDoingRegularBorrow
        whenThereIsAnExistingBorrow
        whenNoTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _existingBorrowNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_borrow_03()
        public
        whenUserIsDoingRegularBorrow
        whenThereIsAnExistingBorrow
        whenSomeTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _existingBorrowSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_borrow_04()
        public
        whenUserIsDoingSiloedBorrow
        whenThereIsAnExistingBorrow
        whenNoTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _existingBorrowNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_borrow_05()
        public
        whenUserIsDoingSiloedBorrow
        whenThereIsAnExistingBorrow
        whenSomeTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _existingBorrowSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_borrow_06()
        public
        whenUserIsDoingEModeBorrow
        whenThereIsAnExistingBorrow
        whenNoTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _existingBorrowNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_borrow_07()
        public
        whenUserIsDoingEModeBorrow
        whenThereIsAnExistingBorrow
        whenSomeTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);

        _existingBorrowSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 0);
    }

    function test_borrow_08()
        public
        whenUserIsDoingIsolationModeBorrow
        whenThereIsAnExistingBorrow
        whenNoTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 100_00);

        _existingBorrowNoTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 600_00);
    }

    function test_borrow_09()
        public
        whenUserIsDoingIsolationModeBorrow
        whenThereIsAnExistingBorrow
        whenSomeTimeHasPassedSinceLastBorrow
    {
        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 100_00);

        _existingBorrowSomeTimePassedTest();

        assertEq(pool.getReserveData(address(collateralAsset)).isolationModeTotalDebt, 600_00);
    }

    /**********************************************************************************************/
    /*** Test running functions                                                                 ***/
    /**********************************************************************************************/

    function _usersFirstBorrowTest() internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.05e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 0,
            totalSupply: 0
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          borrower,
            asset:         address(borrowAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 1000 ether
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertAssetState(assetParams);

        assertEq(pool.getUserConfiguration(borrower).isBorrowingAny(), false);

        vm.prank(borrower);
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);

        poolParams.currentLiquidityRate      = 0.03125e27 * 0.95;  // 50% utilized: 6.25% * 50% * (1 - reserveFactor) = 3.125% * 95%
        poolParams.currentVariableBorrowRate = 0.0625e27;          // 50% utilized: 5% + 50%/80% * 2% = 6.25%

        debtTokenParams.userBalance = 500 ether;
        debtTokenParams.totalSupply = 500 ether;

        assetParams.aTokenBalance = 500 ether;
        assetParams.userBalance   = 500 ether;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertAssetState(assetParams);

        assertEq(pool.getUserConfiguration(borrower).isBorrowingAny(), true);
    }

    function _existingBorrowNoTimePassedTest() internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0.00525e27 * 0.95,  // 10% utilized: 5% * 10% * (1 - reserveFactor) = 0.525% * 95%
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.0525e27,  // 10% utilized: 5% + 10%/80% * 2% = 5.25%
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 0,
            totalSupply: 100 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          borrower,
            asset:         address(borrowAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 900 ether
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertAssetState(assetParams);

        vm.prank(borrower);
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);

        poolParams.currentLiquidityRate      = 0.039e27 * 0.95;  // 60% utilized: 60% * 6.5% * (1 - reserveFactor)= 3.9% * 95%
        poolParams.currentVariableBorrowRate = 0.065e27;         // 60% utilized: 5% + 60%/80% * 2% = 6.5%

        debtTokenParams.userBalance = 500 ether;
        debtTokenParams.totalSupply = 600 ether;

        assetParams.aTokenBalance = 400 ether;
        assetParams.userBalance   = 500 ether;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertAssetState(assetParams);
    }

    function _existingBorrowSomeTimePassedTest() internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0.00525e27 * 0.95,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: 0.0525e27,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        uint256 compoundedNormalizedInterest
            = _getCompoundedNormalizedInterest(0.0525e27, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 100 ether / 1e27;

        assertEq(borrowerDebt,                 0.052513783297156325 ether);
        assertEq(compoundedNormalizedInterest, 1.000525137832971563250670960e27);

        AssertDebtTokenStateParams memory debtTokenParams = AssertDebtTokenStateParams({
            user:        borrower,
            debtToken:   debtToken,
            userBalance: 0,
            totalSupply: 100 ether + borrowerDebt + 1  // Rounding error
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          borrower,
            asset:         address(borrowAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: 900 ether
        });

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertAssetState(assetParams);

        vm.prank(borrower);
        pool.borrow(address(borrowAsset), 500 ether, 2, 0, borrower);

        ( uint256 borrowRate, uint256 liquidityRate )
            = _getUpdatedRates(600 ether + borrowerDebt + 1, 1000 ether + borrowerDebt + 1);  // +1 from debt token rounding

        assertEq(borrowRate,    0.065000525110257445296663721e27);  // ~60% utilized: 5% + 60%/80% * 2% = ~6.5%
        assertEq(liquidityRate, 0.037051596345660783435879811e27);  // ~60% utilized: 60% * ~6.5% * (1 - reserveFactor) = ~3.9% * 95%

        uint256 expectedLiquidityIndex      = 1e27 + (1e27 * 0.00525e27 * 95/100 / 100 / 1e27);  // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;        // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.000049875e27);
        assertEq(expectedVariableBorrowIndex, compoundedNormalizedInterest);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.currentLiquidityRate      = liquidityRate + 1;  // Rounding
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentVariableBorrowRate = borrowRate;
        poolParams.lastUpdateTimestamp       = WARP_TIME + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex + 1;  // Scaled value

        // Borrower debt only accrued against existing borrow
        debtTokenParams.userBalance = 500 ether + 1;  // Rounding
        debtTokenParams.totalSupply = 600 ether + borrowerDebt + 1;  // Rounding

        assetParams.aTokenBalance = 400 ether;
        assetParams.userBalance   = 500 ether;

        _assertPoolReserveState(poolParams);
        _assertDebtTokenState(debtTokenParams);
        _assertAssetState(assetParams);
    }

}
