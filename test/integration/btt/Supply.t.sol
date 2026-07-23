// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { UserConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import { Errors }            from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";
import { DataTypes }         from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

import { IERC20, SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract SupplyTestBase is SparkLendTestBase {

    address supplier = makeAddr("supplier");

    uint16 reserveId;

    function setUp() public virtual override {
        super.setUp();

        reserveId = pool.getReserveData(address(collateralAsset)).id;

        vm.label(supplier, "supplier");
    }

    function _callSupply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    )
        internal virtual
    {
        vm.prank(supplier);
        pool.supply(asset, amount, onBehalfOf, referralCode);
    }

}

contract SupplyFailureTests is SupplyTestBase {

    function test_supply_whenAmountZero() public virtual {
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        _callSupply(address(collateralAsset), 0, supplier, 0);
    }

    function test_supply_whenNotActive() public {
        vm.prank(admin);
        poolConfigurator.setReserveActive(address(collateralAsset), false);

        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);
    }

    function test_supply_whenPaused() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(address(collateralAsset), true);

        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);
    }

    function test_supply_whenFrozen() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(address(collateralAsset), true);

        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);
    }

    function test_supply_amountOverSupplyCapBoundary() public virtual {
        vm.prank(admin);
        poolConfigurator.setSupplyCap(address(collateralAsset), 1000);

        // Mint enough funds for the 1000 ether supply to succeed
        collateralAsset.mint(supplier, 1000 ether);

        vm.prank(supplier);
        collateralAsset.approve(address(pool), 1000 ether);

        // Boundary is 1 wei, not 1 ether even though supply cap is
        // using units without decimals.
        vm.expectRevert(bytes(Errors.SUPPLY_CAP_EXCEEDED));
        _callSupply(address(collateralAsset), 1000 ether + 1, supplier, 0);

        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);
    }

    function test_supply_insufficientApproveBoundary() public virtual {
        collateralAsset.mint(supplier, 1000 ether);

        vm.prank(supplier);
        collateralAsset.approve(address(pool), 1000 ether - 1);

        vm.expectRevert(stdError.arithmeticError);
        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);

        vm.prank(supplier);
        collateralAsset.approve(address(pool), 1000 ether);

        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);
    }

    function test_supply_insufficientBalanceBoundary() public virtual {
        vm.startPrank(supplier);

        collateralAsset.approve(address(pool), 1000 ether);
        collateralAsset.mint(supplier, 1000 ether - 1);

        vm.stopPrank();

        vm.expectRevert(stdError.arithmeticError);
        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);

        collateralAsset.mint(supplier, 1);

        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);
    }

    function test_supply_aTokenMintNotCalledByPool() public {
        vm.expectRevert(bytes(Errors.CALLER_MUST_BE_POOL));
        aCollateralAsset.mint(address(this), address(this), 1000 ether, 1e18);
    }

    function test_supply_aTokenMintScaledInvalidAmount() public virtual {
        _initCollateral({
            asset:                address(borrowAsset),
            ltv:                  50_00,
            liquidationThreshold: 60_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);

        address user = makeAddr("user");

        // Accrue enough interest against the collateralAsset that the aToken
        // will round down to zero on a supply of 1 because of the index
        _supply(user, address(collateralAsset), 500 ether);
        _supply(user, address(borrowAsset),     1000 ether);
        _borrow(user, address(collateralAsset), 500 ether);
        vm.warp(10_000 days);

        vm.startPrank(supplier);

        collateralAsset.approve(address(pool), 1);
        collateralAsset.mint(supplier, 1);

        vm.stopPrank();

        vm.expectRevert(bytes(Errors.INVALID_MINT_AMOUNT));
        _callSupply(address(collateralAsset), 1, supplier, 0);
    }

}

contract SupplyConcreteTests is SupplyTestBase {

    using UserConfiguration for DataTypes.UserConfigurationMap;

    // NOTE: Have to use storage for these values so they can be used across modifiers.
    address otherCollateral1;
    address otherCollateral2;

    uint256 numOtherCollaterals;

    address borrower = makeAddr("borrower");

    function setUp() public virtual override {
        super.setUp();

        collateralAsset.mint(supplier, 1000 ether);

        vm.prank(supplier);
        collateralAsset.approve(address(pool), 1000 ether);

        // NOTE: Using this to give the pool a more common starting state
        //       for reserve state testing
        _supply(makeAddr("new-user"), address(collateralAsset), 500 ether);
    }

    /**********************************************************************************************/
    /*** BTT modifiers                                                                          ***/
    /**********************************************************************************************/

    modifier givenFirstUserSupply { _; }

    modifier givenIsolationModeEnabled {
        _withdraw(makeAddr("new-user"), address(collateralAsset), 500 ether);  // Avoid error

        vm.prank(admin);
        poolConfigurator.setDebtCeiling(address(collateralAsset), 1000);

        _supply(makeAddr("new-user"), address(collateralAsset), 500 ether);
        _;
    }

    modifier givenIsolationModeDisabled { _; }

    modifier givenUserHasNoIsolatedCollateralRole { _; }

    modifier givenUserDoesHaveIsolatedCollateralRole {
        vm.prank(admin);
        aclManager.grantRole(keccak256('ISOLATED_COLLATERAL_SUPPLIER'), supplier);
        _;
    }

    modifier givenLtvIsZero { _; }

    modifier givenLtvIsNotZero {
        // Set LTV to 1%
        vm.prank(admin);
        poolConfigurator.configureReserveAsCollateral(address(collateralAsset), 100, 100, 100_01);
        _;
    }

    modifier whenUserIsNotUsingOtherCollateral {
        _;
        assertEq(numOtherCollaterals, 0);
    }

    modifier whenUserIsUsingOtherCollateral {
        _;
        assertGt(numOtherCollaterals, 0);
    }

    modifier whenUserIsUsingOneOtherCollateral {
        otherCollateral1 = _setUpNewCollateral();

        numOtherCollaterals = 1;

        // NOTE: Have to set the debt ceiling to non-zero value here because once a user supplies
        //       with a zero debt ceiling it cannot be set, can be set to zero though.
        _setCollateralDebtCeiling(otherCollateral1, 1000);
        _supplyAndUseAsCollateral(supplier, otherCollateral1, 1000 ether);
        _;
    }

    modifier givenOneOtherCollateralIsInIsolationMode {
        vm.prank(admin);
        poolConfigurator.setDebtCeiling(otherCollateral1, 1000);
        _;
    }

    modifier givenOneOtherCollateralIsNotInIsolationMode {
        vm.prank(admin);
        poolConfigurator.setDebtCeiling(otherCollateral1, 0);
        _;
    }

    modifier whenUserIsUsingMultipleOtherCollaterals {
        otherCollateral1 = _setUpNewCollateral();
        otherCollateral2 = _setUpNewCollateral();

        numOtherCollaterals = 2;

        _supplyAndUseAsCollateral(supplier, otherCollateral1, 1000 ether);
        _supplyAndUseAsCollateral(supplier, otherCollateral2, 1000 ether);
        _;
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
            liquidationThreshold: 60_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);

        _supplyAndUseAsCollateral(borrower, address(borrowAsset), 1000 ether);
        _borrow(borrower, address(collateralAsset), 100 ether);
        _;
    }

    modifier givenNoTimeHasPassedAfterBorrow {
        IERC20 debtToken
            = IERC20(pool.getReserveData(address(collateralAsset)).variableDebtTokenAddress);

        assertGt(debtToken.totalSupply(), 0);
        _;
    }

    modifier givenSomeTimeHasPassedAfterBorrow() {
        IERC20 debtToken
            = IERC20(pool.getReserveData(address(collateralAsset)).variableDebtTokenAddress);

        assertGt(debtToken.totalSupply(), 0);

        skip(WARP_TIME);
        _;
    }

    /**********************************************************************************************/
    /*** BTT tests                                                                              ***/
    /**********************************************************************************************/

    function test_supply_01()
        public
        givenFirstUserSupply
        givenIsolationModeEnabled
        givenUserHasNoIsolatedCollateralRole
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_02()
        public
        givenFirstUserSupply
        givenIsolationModeEnabled
        givenUserDoesHaveIsolatedCollateralRole
        givenLtvIsZero
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_03()
        public
        givenFirstUserSupply
        givenIsolationModeEnabled
        givenUserDoesHaveIsolatedCollateralRole
        givenLtvIsNotZero
        whenUserIsNotUsingOtherCollateral
    {
        _automaticCollateralSupplyTest();
    }

    function test_supply_04()
        public
        givenFirstUserSupply
        givenIsolationModeEnabled
        givenUserDoesHaveIsolatedCollateralRole
        givenLtvIsNotZero
        whenUserIsUsingOtherCollateral
        whenUserIsUsingOneOtherCollateral
        givenOneOtherCollateralIsInIsolationMode
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_05()
        public
        givenFirstUserSupply
        givenIsolationModeEnabled
        givenUserDoesHaveIsolatedCollateralRole
        givenLtvIsNotZero
        whenUserIsUsingOtherCollateral
        whenUserIsUsingOneOtherCollateral
        givenOneOtherCollateralIsNotInIsolationMode
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_06()
        public
        givenFirstUserSupply
        givenIsolationModeEnabled
        givenUserDoesHaveIsolatedCollateralRole
        givenLtvIsNotZero
        whenUserIsUsingOtherCollateral
        whenUserIsUsingMultipleOtherCollaterals
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_07()
        public
        givenFirstUserSupply
        givenIsolationModeDisabled
        givenLtvIsZero
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_08()
        public
        givenFirstUserSupply
        givenIsolationModeDisabled
        givenLtvIsNotZero
        whenUserIsNotUsingOtherCollateral
    {
        _automaticCollateralSupplyTest();
    }

    function test_supply_09()
        public
        givenFirstUserSupply
        givenIsolationModeDisabled
        givenLtvIsNotZero
        whenUserIsUsingOtherCollateral
        whenUserIsUsingOneOtherCollateral
        givenOneOtherCollateralIsInIsolationMode
    {
        _noAutomaticCollateralSupplyTest();
    }

    function test_supply_10()
        public
        givenFirstUserSupply
        givenIsolationModeDisabled
        givenLtvIsNotZero
        whenUserIsUsingOtherCollateral
        whenUserIsUsingOneOtherCollateral
        givenOneOtherCollateralIsNotInIsolationMode
    {
        _automaticCollateralSupplyTest();
    }

    function test_supply_11()
        public
        givenFirstUserSupply
        givenIsolationModeDisabled
        givenLtvIsNotZero
        whenUserIsUsingOtherCollateral
        whenUserIsUsingMultipleOtherCollaterals
    {
        _automaticCollateralSupplyTest();
    }

    function test_supply_12()
        public
        givenNoTimeHasPassed
        givenNoActiveBorrow
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: BASE_RATE,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     1000 ether,
            userBalance:   1000 ether,
            aTokenBalance: 500 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, 1);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);

        aTokenParams.userBalance = 1000 ether;
        aTokenParams.totalSupply = 1500 ether;

        assetParams.allowance     = 0;
        assetParams.userBalance   = 0;
        assetParams.aTokenBalance = 1500 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    function test_supply_13()
        public
        givenNoTimeHasPassed
        givenActiveBorrow
        givenNoTimeHasPassedAfterBorrow
    {
        // Overwrite approve for cleaner numbers
        vm.prank(supplier);
        collateralAsset.approve(address(pool), 750 ether);

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 500 ether);

        assertEq(borrowRate,    0.055e27);
        assertEq(liquidityRate, 0.01045e27);  // 1.1% * 95%

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
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     750 ether,
            userBalance:   1000 ether,
            aTokenBalance: 400 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, 1);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        // Approving 750 instead of 1000 to get cleaner numbers
        _callSupply(address(collateralAsset), 750 ether, supplier, 0);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether, 1250 ether);

        // Both are lower because supply decreased utilization
        assertEq(borrowRate,    0.052e27);
        assertEq(liquidityRate, 0.00416e27 * 0.95);

        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.currentVariableBorrowRate = borrowRate;

        aTokenParams.userBalance = 750 ether;
        aTokenParams.totalSupply = 1250 ether;

        assetParams.allowance     = 0;
        assetParams.userBalance   = 250 ether;   // Remaining from 1000
        assetParams.aTokenBalance = 1150 ether;  // 100 borrowed

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    function test_supply_14()
        public
        givenNoTimeHasPassed
        givenActiveBorrow
        givenSomeTimeHasPassedAfterBorrow
    {
        // Overwrite approve for cleaner numbers
        vm.prank(supplier);
        collateralAsset.approve(address(pool), 750 ether);

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 500 ether);

        assertEq(borrowRate,    0.055e27);
        assertEq(liquidityRate, 0.01045e27);  // 1.1% * 95%

        uint256 supplierYield = 0.01045e27 * 500 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 100 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.055 ether * 0.95);
        assertEq(compoundedNormalizedInterest, 1.000550151275656075434506e27);
        assertEq(borrowerDebt,                 0.055015127565607543 ether);

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
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether + supplierYield
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     750 ether,
            userBalance:   1000 ether,
            aTokenBalance: 400 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, WARP_TIME + 1);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        // Approving 750 instead of 1000 to get cleaner numbers
        _callSupply(address(collateralAsset), 750 ether, supplier, 0);

        uint256 expectedLiquidityIndex      = 1e27 + (liquidityRate * 1/100);              // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.0001045e27);  // 95% of 0.00011e27
        assertEq(expectedVariableBorrowIndex, 1.000550151275656075434506e27);

        // NOTE: Utilization is based off of the totalDebt / totalLiquidityPlusDebt, this means that the
        //       totalValue of the market is based off of the DEBT OWED, not the amount of yield generated for the suppliers.
        //       These two numbers are close, but borrowerDebt is always slightly higher than supplierYield because of
        //       compounded interest.
        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether + borrowerDebt, 1250 ether + borrowerDebt);

        // // Both are lower because supply decreased utilization
        assertEq(borrowRate,    0.052001012233796670018774935e27);
        assertEq(liquidityRate, 0.004162186465985497605393897e27 * uint256(95)/100);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentVariableBorrowRate = borrowRate;
        poolParams.lastUpdateTimestamp       = WARP_TIME + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex;

        aTokenParams.userBalance = 750 ether - 1;  // Rounding
        aTokenParams.totalSupply = 1250 ether + supplierYield - 1;  // Rounding

        assetParams.allowance     = 0;
        assetParams.userBalance   = 250 ether;  // Remaining from 1000
        assetParams.aTokenBalance = 1150 ether; // 100 borrowed

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    function test_supply_15()
        public
        givenSomeTimeHasPassed
        givenNoActiveBorrow
    {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: BASE_RATE,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     1000 ether,
            userBalance:   1000 ether,
            aTokenBalance: 500 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, WARP_TIME + 1);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);

        poolParams.lastUpdateTimestamp = WARP_TIME + 1;

        aTokenParams.userBalance = 1000 ether;
        aTokenParams.totalSupply = 1500 ether;

        assetParams.allowance     = 0;
        assetParams.userBalance   = 0;
        assetParams.aTokenBalance = 1500 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    function test_supply_16()
        public
        givenSomeTimeHasPassed
        givenActiveBorrow
        givenNoTimeHasPassedAfterBorrow
    {
        // Overwrite approve for cleaner numbers
        vm.prank(supplier);
        collateralAsset.approve(address(pool), 750 ether);

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 500 ether);

        assertEq(borrowRate,    0.055e27);
        assertEq(liquidityRate, 0.01045e27);  // 1.1% * 95%

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
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     750 ether,
            userBalance:   1000 ether,
            aTokenBalance: 400 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, WARP_TIME + 1);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        // Approving 750 instead of 1000 to get cleaner numbers
        _callSupply(address(collateralAsset), 750 ether, supplier, 0);

        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether, 1250 ether);

        // Both are lower because supply decreased utilization
        assertEq(borrowRate,    0.052e27);
        assertEq(liquidityRate, 0.00416e27 * 0.95);

        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.currentVariableBorrowRate = borrowRate;

        aTokenParams.userBalance = 750 ether;
        aTokenParams.totalSupply = 1250 ether;

        assetParams.allowance     = 0;
        assetParams.userBalance   = 250 ether;   // Remaining from 1000
        assetParams.aTokenBalance = 1150 ether;  // 100 borrowed

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    function test_supply_17()
        public
        givenSomeTimeHasPassed
        givenActiveBorrow
        givenSomeTimeHasPassedAfterBorrow
    {
        // Overwrite approve for cleaner numbers
        vm.prank(supplier);
        collateralAsset.approve(address(pool), 750 ether);

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 500 ether);

        assertEq(borrowRate,    0.055e27);
        assertEq(liquidityRate, 0.01045e27);  // 1.1% * 95%

        uint256 supplierYield = 0.01045e27 * 500 ether / 100 / 1e27;  // 1% of APR

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, WARP_TIME);

        uint256 borrowerDebt = (compoundedNormalizedInterest - 1e27) * 100 ether / 1e27;

        // Borrower owes slightly more than lender has earned because of compounded interest
        assertEq(supplierYield,                0.055 ether * 0.95);
        assertEq(compoundedNormalizedInterest, 1.000550151275656075434506e27);
        assertEq(borrowerDebt,                 0.055015127565607543 ether);

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
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether + supplierYield
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     750 ether,
            userBalance:   1000 ether,
            aTokenBalance: 400 ether  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, WARP_TIME * 2 + 1);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        // Approving 750 instead of 1000 to get cleaner numbers
        _callSupply(address(collateralAsset), 750 ether, supplier, 0);

        uint256 expectedLiquidityIndex      = 1e27 + (liquidityRate * 1/100);              // Normalized yield accrues 1% of APR
        uint256 expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;  // Accrues slightly more than 1% of APR because of compounded interest

        assertEq(expectedLiquidityIndex,      1.0001045e27);  // 95% of 0.00011e27
        assertEq(expectedVariableBorrowIndex, 1.000550151275656075434506e27);

        // NOTE: Utilization is based off of the totalDebt / totalLiquidityPlusDebt, this means that the
        //       totalValue of the market is based off of the DEBT OWED, not the amount of yield generated for the suppliers.
        //       These two numbers are close, but borrowerDebt is always slightly higher than supplierYield because of
        //       compounded interest.
        ( borrowRate, liquidityRate ) = _getUpdatedRates(100 ether + borrowerDebt, 1250 ether + borrowerDebt);

        // // Both are lower because supply decreased utilization
        assertEq(borrowRate,    0.052001012233796670018774935e27);
        assertEq(liquidityRate, 0.004162186465985497605393897e27 * uint256(95)/100);

        poolParams.liquidityIndex            = expectedLiquidityIndex;
        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.variableBorrowIndex       = expectedVariableBorrowIndex;
        poolParams.currentVariableBorrowRate = borrowRate;
        poolParams.lastUpdateTimestamp       = WARP_TIME * 2 + 1;
        poolParams.accruedToTreasury         = borrowerDebt * 5/100 * 1e27 / expectedLiquidityIndex;

        aTokenParams.userBalance = 750 ether - 1;  // Rounding
        aTokenParams.totalSupply = 1250 ether + supplierYield - 1;  // Rounding

        assetParams.allowance     = 0;
        assetParams.userBalance   = 250 ether;  // Remaining from 1000
        assetParams.aTokenBalance = 1150 ether; // 100 borrowed

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    /**********************************************************************************************/
    /*** Test running functions                                                                 ***/
    /**********************************************************************************************/

    function _firstSupplyTest() internal {
        AssertPoolReserveStateParams memory poolParams = AssertPoolReserveStateParams({
            asset:                     address(collateralAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      0,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: BASE_RATE,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        AssertATokenStateParams memory aTokenParams = AssertATokenStateParams({
            user:        supplier,
            aToken:      address(aCollateralAsset),
            userBalance: 0,
            totalSupply: 500 ether
        });

        AssertAssetStateParams memory assetParams = AssertAssetStateParams({
            user:          supplier,
            asset:         address(collateralAsset),
            allowance:     1000 ether,
            userBalance:   1000 ether,
            aTokenBalance: 500 ether
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        assertEq(block.timestamp, 1);

        _callSupply(address(collateralAsset), 1000 ether, supplier, 0);

        aTokenParams.userBalance = 1000 ether;
        aTokenParams.totalSupply = 1500 ether;

        assetParams.allowance     = 0;
        assetParams.userBalance   = 0;
        assetParams.aTokenBalance = 1500 ether;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function _noAutomaticCollateralSupplyTest() internal {
        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        _firstSupplyTest();

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );
    }

    function _automaticCollateralSupplyTest() internal {
        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            false,
            "isUsingAsCollateral"
        );

        _firstSupplyTest();

        assertEq(
            pool.getUserConfiguration(supplier).isUsingAsCollateral(reserveId),
            true,
            "isUsingAsCollateral"
        );
    }

}
