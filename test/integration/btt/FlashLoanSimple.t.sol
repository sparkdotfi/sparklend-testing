// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { Errors } from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";

import {
    MockReceiverSimpleBasic,
    MockReceiverSimpleReturnFalse,
    MockReceiverSimpleInsufficientApprove,
    MockReceiverSimpleInsufficientBalance,
    MockReceiverSimpleMintPremium
} from "test/mocks/MockReceiverSimple.sol";

import { IERC20, SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract FlashLoanSimpleTestBase is SparkLendTestBase {

    address borrower = makeAddr("borrower");
    address supplier = makeAddr("supplier");

    address receiver;

    function setUp() public virtual override {
        super.setUp();

        receiver = address(new MockReceiverSimpleBasic(address(poolConfigurator), address(pool)));

        // Set up necessary conditions for success
        _supply(supplier, address(borrowAsset), 1000 ether);

        vm.prank(admin);
        poolConfigurator.setReserveFlashLoaning(address(borrowAsset), true);
    }

}

contract FlashLoanSimpleFailureTests is FlashLoanSimpleTestBase {

    function test_flashLoanSimple_whenNotActive() public {
        // Avoid RESERVE_LIQUIDITY_NOT_ZERO error when deactivating
        _withdraw(supplier, address(borrowAsset), 1000 ether);

        vm.prank(admin);
        poolConfigurator.setReserveActive(address(borrowAsset), false);

        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_whenPaused() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(address(borrowAsset), true);

        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_whenFrozen() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(address(borrowAsset), true);

        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_flashLoanNotEnabled() public {
        vm.prank(admin);
        poolConfigurator.setReserveFlashLoaning(address(borrowAsset), false);

        vm.expectRevert(bytes(Errors.FLASHLOAN_DISABLED));
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_insufficientLiquidityBoundary() public {
        vm.expectRevert(stdError.arithmeticError);
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether + 1, new bytes(0), 0);

        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_receiverReturnsFalse() public {
        receiver = address(new MockReceiverSimpleReturnFalse(address(poolConfigurator), address(pool)));

        vm.expectRevert(bytes(Errors.INVALID_FLASHLOAN_EXECUTOR_RETURN));
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_receiverInsufficientApprovalBoundary() public {
        receiver = address(new MockReceiverSimpleInsufficientApprove(address(poolConfigurator), address(pool)));

        vm.expectRevert(stdError.arithmeticError);
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);

        receiver = address(new MockReceiverSimpleBasic(address(poolConfigurator), address(pool)));

        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

    function test_flashLoanSimple_receiverInsufficientBalanceBoundary() public {
        receiver = address(new MockReceiverSimpleInsufficientBalance(address(poolConfigurator), address(pool)));

        vm.expectRevert(stdError.arithmeticError);
        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);

        receiver = address(new MockReceiverSimpleBasic(address(poolConfigurator), address(pool)));

        pool.flashLoanSimple(receiver, address(borrowAsset), 1000 ether, new bytes(0), 0);
    }

}

contract FlashLoanSimpleSuccessTests is FlashLoanSimpleTestBase {

    uint256 amount;  // Amount to set in the modifier

    function setUp() public virtual override {
        super.setUp();

        // Mint the premium to allow for successful flashloans with premiums
        receiver = address(new MockReceiverSimpleMintPremium(address(poolConfigurator), address(pool)));

        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 60_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), true);

        // Set up an active borrow to make rates changes more realistic
        _supplyAndUseAsCollateral(borrower, address(collateralAsset), 1000 ether);
        _borrow(borrower, address(borrowAsset), 100 ether);

        vm.prank(admin);
        poolConfigurator.setReserveFlashLoaning(address(borrowAsset), true);
    }

    /**********************************************************************************************/
    /*** Virtual functions (overridden in flashLoan tests to prove equivalence)                 ***/
    /**********************************************************************************************/

    function _callFlashLoan() internal virtual {
        pool.flashLoanSimple(receiver, address(borrowAsset), amount, new bytes(0), 0);
    }

    /**********************************************************************************************/
    /*** Modifiers                                                                              ***/
    /**********************************************************************************************/

    modifier whenNoTimeHasPassed { _; }

    modifier whenSomeTimeHasPassed {
        skip(WARP_TIME);
        _;
    }

    modifier whenAmountIsZero {
        amount = 0;
        _;
    }

    modifier whenAmountIsNotZero {
        amount = 100 ether;
        _;
    }

    modifier givenTotalPremiumIsZero { _; }

    modifier givenTotalPremiumIsNotZero {
        vm.prank(admin);
        poolConfigurator.updateFlashloanPremiumTotal(10_00);  // 10%
        _;
    }

    modifier givenFlashLoanPremiumToProtocolIsZero { _; }

    modifier givenFlashLoanPremiumToProtocolIsNotZero {
        vm.prank(admin);
        poolConfigurator.updateFlashloanPremiumToProtocol(5_00);  // 5%
        _;
    }

    /**********************************************************************************************/
    /*** BTT tests                                                                              ***/
    /**********************************************************************************************/

    function test_flashLoanSimple_01()
        whenNoTimeHasPassed
        whenAmountIsZero
        public
    {
        _noStateChangeTest();
    }

    function test_flashLoanSimple_02()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        _noStateChangeTest();
    }

    function test_flashLoanSimple_03()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        // No premium to protocol when total premium is still zero
        _noStateChangeTest();
    }

    function test_flashLoanSimple_04()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            ,
            ,
        ) = _loadStartingParamsAndAssertState(0);

        _callFlashLoan();

        aTokenParams.userBalance = 1010 ether;  // 100 flashborrow * 10% premium
        aTokenParams.totalSupply = 1010 ether;  // 100 flashborrow * 10% premium

        assetParams.aTokenBalance = 910 ether;  // 100 flashborrow * 10% premium

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1010 ether);

        // Utilization rate has decreased because of premium being added to the pool
        assertLt(borrowRate,    0.0525e27);
        assertLt(liquidityRate, 0.0049875e27);
        assertEq(borrowRate,    0.052475247524752475247524752e27);
        assertEq(liquidityRate, 0.004935790608763846681697872e27);

        poolParams.currentLiquidityRate      = liquidityRate + 1;  // Rounding
        poolParams.currentVariableBorrowRate = borrowRate + 1;     // Rounding

        // 1e27 + 10% of 100 borrow = 1.01e27 - Note that this was updated WITHOUT time passing
        // Also note that the borrowIndex does not update because they do not owe any more interest
        poolParams.liquidityIndex = 1.01e27;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_flashLoanSimple_05()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            ,
            ,
        ) = _loadStartingParamsAndAssertState(0);

        _callFlashLoan();

        aTokenParams.userBalance = 1009.5 ether;  // 100 + 9.5% premium (5% of 10% to protocol)
        aTokenParams.totalSupply = 1009.5 ether;  // 100 + 9.5% premium (5% of 10% to protocol)

        // 100 + full 10% premium (0.5% protocol fee accounted with accruedToTreasury)
        assetParams.aTokenBalance = 910 ether;

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1010 ether);

        // Utilization rate has decreased because of premium being added to the pool
        assertLt(borrowRate,    0.0525e27);
        assertLt(liquidityRate, 0.0049875e27);
        assertEq(borrowRate,    0.052475247524752475247524752e27);
        assertEq(liquidityRate, 0.004935790608763846681697872e27);

        poolParams.currentLiquidityRate      = liquidityRate + 1;  // Rounding
        poolParams.currentVariableBorrowRate = borrowRate + 1;     // Rounding

        // 1e27 + 9.5% of 100 borrow = 1.0095e27 - Note that this was updated WITHOUT time passing.
        // Also note that the borrowIndex does not update because they do not owe any more interest.
        // Also note that this index is 1.0095 and not 1.01 because it takes into account the accruedToTreasury.
        // The amount earned by the LPs is accrued to the index, and the accruedToTreasury amount is used in the calculation.
        // These amounts are calculated based on the state of the pool BEFORE the premium is sent in.
        // So the calculation is:
        // newIndex = oldIndex + (premiumToLP / (aToken.totalSupply + aToken.accruedToTreasury * oldIndex))
        // newIndex = 1 + (9.5 / (1000 + 0 * 1))
        // newIndex = 1.0095
        poolParams.liquidityIndex = 1.0095e27;

        // Amount to treasury represented as a scaled amount
        uint256 accruedToTreasury = uint256(0.5 ether * 1e27) / 1.0095e27;

        assertEq(accruedToTreasury, 0.495294700346706290 ether);

        poolParams.accruedToTreasury = accruedToTreasury;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        // NOTE: Below is not directly relevant to the flashloan test, but is is a demonstration
        //       of how the protocol fee is reflected as a state variable and then a real amount later on
        //       These asserts ensure that the calculation is done correctly.

        assertEq(pool.getReserveNormalizedIncome(address(borrowAsset)), 1.0095e27);

        address[] memory assets = new address[](1);
        assets[0] = address(borrowAsset);

        pool.mintToTreasury(assets);

        // Reserve normalized income doesn't change because accruedToTreasury is always factored into the index
        assertEq(pool.getReserveNormalizedIncome(address(borrowAsset)), 1.0095e27);

        poolParams.accruedToTreasury = 0;

        aTokenParams.totalSupply = 1010 ether - 1;  // 0.5 ether - 1 minted to the treasury

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        _repay(borrower, address(borrowAsset), 100 ether);
        _withdraw(supplier, address(borrowAsset), 1009.5 ether);
        _withdraw(treasury, address(borrowAsset), 0.5 ether - 1);

        assertEq(aBorrowAsset.balanceOf(treasury), 0);
        assertEq(aBorrowAsset.balanceOf(supplier), 0);
        assertEq(aBorrowAsset.totalSupply(),       0);

        assertEq(borrowAsset.balanceOf(treasury),              0.5 ether - 1);  // Rounding error
        assertEq(borrowAsset.balanceOf(supplier),              1009.5 ether);
        assertEq(borrowAsset.balanceOf(address(aBorrowAsset)), 1);
    }

    function test_flashLoanSimple_06()
        whenSomeTimeHasPassed
        whenAmountIsZero
        public
    {
        _timePassedNoFeesTest();
    }

    function test_flashLoanSimple_07()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        _timePassedNoFeesTest();
    }

    function test_flashLoanSimple_08()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        // No premium to protocol when total premium is still zero
        _timePassedNoFeesTest();
    }

    function test_flashLoanSimple_09()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            uint256 borrowerInterest,
            uint256 expectedYieldLiquidityIndex,
            uint256 expectedBorrowIndex
        ) = _loadStartingParamsAndAssertState(WARP_TIME);

        _callFlashLoan();

        assertEq(borrowerInterest,            0.052513783297156325 ether);
        assertEq(expectedYieldLiquidityIndex, 1.000049875e27);  // 0.525% yield for 1% of a year * (1 - reserveFactor) = 0.00525% * 95%
        assertEq(expectedBorrowIndex,         1.000525137832971563250670960e27);

        // Premium is only added to cash side
        ( uint256 borrowRate, uint256 liquidityRate )
            = _getUpdatedRates(100 ether + borrowerInterest, 1000 ether + borrowerInterest + 10 ether);

        // Utilization rate has decreased because of premium being added to the pool
        assertLt(borrowRate,    0.0525e27);
        assertLt(liquidityRate, 0.0049875e27);
        assertEq(borrowRate,    0.052476418612348581178374884e27);
        assertEq(liquidityRate, 0.004938236030918590189350852e27);

        poolParams.variableBorrowIndex       = expectedBorrowIndex;
        poolParams.currentLiquidityRate      = liquidityRate + 2;  // Rounding
        poolParams.currentVariableBorrowRate = borrowRate + 1;     // Rounding
        poolParams.lastUpdateTimestamp       = 1 + WARP_TIME;
        poolParams.accruedToTreasury         = borrowerInterest * 5/100 * 1e27 / expectedYieldLiquidityIndex + 1;  // Rounding
        // NOTE: `accruedToTreasury` is scaled by the liquidityIndex before it is updated by the flashloan again to reflect supplier yield

        // 10% of 100 ether borrow
        uint256 flashLoanNormalizedAccrual = 10 ether * 1e27 / (borrowerInterest * 5/100 + 1000.049875 ether) + 1e27 + 1;  // Rounding

        // Update liquidityIndex again based on 10% of the flashborrow accrued over the total value of the pool
        // (totalSupply + accruedToTreasury) Note that this was updated WITHOUT time passing
        // Also note that the borrowIndex does not update because they do not owe any more interest
        // This value is accrued against the liquidityIndex that was already updated to reflect the borrower interest
        // 1. Update indexes/rates to reflect yield earned since last pool update
        // 2. Update accruedToTreasury to reflect treasury earnings from yield
        // 3. Calculate flashloanAccrued to reflect the yield earned by the LPs (includes treasury as an LP based on accruedToTreasury earnings)
        uint256 expectedLiquidityIndex = expectedYieldLiquidityIndex * flashLoanNormalizedAccrual / 1e27;
        uint256 expectedLPBalance      = 1000 ether * expectedLiquidityIndex / 1e27;  // 100 flashborrow * 10% premium + supplier yield

        assertEq(expectedLiquidityIndex, 1.010049848744486783960059129e27);
        assertEq(expectedLPBalance,      1010.049848744486783960 ether);

        aTokenParams.userBalance = expectedLPBalance;
        aTokenParams.totalSupply = expectedLPBalance;

        assetParams.aTokenBalance = 910 ether;  // 100 flashborrow * 10% premium

        poolParams.liquidityIndex = expectedLiquidityIndex;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function test_flashLoanSimple_10()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            uint256 borrowerInterest,
            uint256 expectedYieldLiquidityIndex,
            uint256 expectedBorrowIndex
        ) = _loadStartingParamsAndAssertState(WARP_TIME);

        _callFlashLoan();

        assertEq(borrowerInterest,            0.052513783297156325 ether);
        assertEq(expectedYieldLiquidityIndex, 1.000049875e27);  // 0.525% yield for 1% of a year * (1 - reserveFactor) = 0.00525% * 95%
        assertEq(expectedBorrowIndex,         1.000525137832971563250670960e27);

        ( uint256 borrowRate, uint256 liquidityRate )
            = _getUpdatedRates(100 ether + borrowerInterest, 1000 ether + borrowerInterest + 10 ether);

        // Utilization rate has decreased because of premium being added to the pool
        assertLt(borrowRate,    0.0525e27);
        assertLt(liquidityRate, 0.0049875e27);
        assertEq(borrowRate,    0.052476418612348581178374884e27);
        assertEq(liquidityRate, 0.004938236030918590189350852e27);

        // 100 + full 10% premium (0.5% protocol fee accounted with accruedToTreasury)
        assetParams.aTokenBalance = 910 ether;

        poolParams.variableBorrowIndex       = expectedBorrowIndex;
        poolParams.currentLiquidityRate      = liquidityRate + 2;  // Rounding
        poolParams.currentVariableBorrowRate = borrowRate + 1;     // Rounding
        poolParams.lastUpdateTimestamp       = 1 + WARP_TIME;
        poolParams.accruedToTreasury         = borrowerInterest * 5/100 * 1e27 / expectedYieldLiquidityIndex + 1;  // Rounding
        // NOTE: `accruedToTreasury` is scaled by the liquidityIndex before it is updated by the flashloan again to reflect supplier yield

        // 9.5% of 100 ether borrow
        uint256 flashLoanNormalizedAccrual = 9.5 ether * 1e27 / (borrowerInterest * 5/100 + 1000.049875 ether) + 1e27 + 1;  // Rounding

        // Update liquidityIndex again based on 9.5% of the flashborrow accrued over the total value of the pool
        // (totalSupply + accruedToTreasury) Note that this was updated WITHOUT time passing.
        // This value is accrued against the liquidityIndex that was already updated to reflect the borrower interest.
        // Also note that the borrowIndex does not update because they do not owe any more interest.
        // The amount earned by the LPs is accrued to the index, and the accruedToTreasury amount is used in the calculation.
        // These amounts are calculated based on the state of the pool BEFORE the premium is sent in.
        // So the calculation is:
        // newIndex = oldIndex + (premiumToLP / (aToken.totalSupply + aToken.accruedToTreasury * oldIndex))
        poolParams.liquidityIndex = expectedYieldLiquidityIndex * flashLoanNormalizedAccrual / 1e27;

        assertEq(poolParams.liquidityIndex, 1.009549850057262444762056173e27);

        aTokenParams.userBalance = 1000 ether * poolParams.liquidityIndex / 1e27;
        aTokenParams.totalSupply = 1000 ether * poolParams.liquidityIndex / 1e27;

        assertEq(aTokenParams.userBalance, 1009.549850057262444762 ether);
        assertEq(aTokenParams.totalSupply, 1009.549850057262444762 ether);

        // Amount accrued to the treasury from the flashloan premium
        uint256 accruedToTreasury = uint256(0.5 ether * 1e27) / poolParams.liquidityIndex;

        assertEq(accruedToTreasury, 0.495270243437349443 ether);

        poolParams.accruedToTreasury += accruedToTreasury;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    /**********************************************************************************************/
    /*** Helper functions                                                                       ***/
    /**********************************************************************************************/

    function _loadStartingParamsAndAssertState(uint256 timeSinceLastUpdate) internal returns (
        AssertPoolReserveStateParams memory poolParams,
        AssertATokenStateParams memory aTokenParams,
        AssertAssetStateParams memory assetParams,
        uint256 borrowerInterest,
        uint256 expectedYieldLiquidityIndex,
        uint256 expectedVariableBorrowIndex
    ) {
        Params memory params = Params({
            amountBorrowed:        100 ether,
            amountSupplied:        1000 ether,
            expectedBorrowRate:    0.0525e27,
            expectedLiquidityRate: 0.0049875e27,
            timeSinceLastUpdate:   timeSinceLastUpdate
        });

        (
            poolParams,
            aTokenParams,
            assetParams,
            borrowerInterest,
            expectedYieldLiquidityIndex,
            expectedVariableBorrowIndex
        ) = _loadStartingParamsAndAssertState(params);
    }

    struct Params {
        uint256 amountBorrowed;
        uint256 amountSupplied;
        uint256 expectedBorrowRate;
        uint256 expectedLiquidityRate;
        uint256 timeSinceLastUpdate;
    }

    function _loadStartingParamsAndAssertState(Params memory params)
        internal returns (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            uint256 borrowerInterest,
            uint256 expectedYieldLiquidityIndex,
            uint256 expectedVariableBorrowIndex
        )
    {
        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(params.amountBorrowed, params.amountSupplied);

        assertEq(borrowRate,    params.expectedBorrowRate);
        assertEq(liquidityRate, params.expectedLiquidityRate);

        uint256 compoundedNormalizedInterest = _getCompoundedNormalizedInterest(borrowRate, params.timeSinceLastUpdate);

        borrowerInterest = (compoundedNormalizedInterest - 1e27) * params.amountBorrowed / 1e27;

        // NOTE: This is called `expectedYieldLiquidityIndex` because it is the liquidityIndex update that happens
        //       before the flashloan is called, so it is just the borrowers interest that is part of this yield.
        //       The index is then updated again to reflect the yield for suppliers coming from flashloans.
        expectedYieldLiquidityIndex = 1e27 + (1e27 * liquidityRate * params.timeSinceLastUpdate / 365 days / 1e27);
        expectedVariableBorrowIndex = 1e27 * compoundedNormalizedInterest / 1e27;

        poolParams = AssertPoolReserveStateParams({
            asset:                     address(borrowAsset),
            liquidityIndex:            1e27,
            currentLiquidityRate:      liquidityRate,
            variableBorrowIndex:       1e27,
            currentVariableBorrowRate: borrowRate,
            currentStableBorrowRate:   0,
            lastUpdateTimestamp:       1,
            accruedToTreasury:         0,
            unbacked:                  0
        });

        aTokenParams = AssertATokenStateParams({
            user:        supplier,
            aToken:      address(aBorrowAsset),
            userBalance: params.amountSupplied * expectedYieldLiquidityIndex / 1e27,
            totalSupply: params.amountSupplied * expectedYieldLiquidityIndex / 1e27
        });

        assetParams = AssertAssetStateParams({
            user:          address(receiver),
            asset:         address(borrowAsset),
            allowance:     0,
            userBalance:   0,
            aTokenBalance: params.amountSupplied - params.amountBorrowed  // 100 borrowed
        });

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function _noStateChangeTest() internal {
        (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            ,
            ,
        ) = _loadStartingParamsAndAssertState(0);

        _callFlashLoan();

        // No state changes
        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

    function _timePassedNoFeesTest() internal {
        (
            AssertPoolReserveStateParams memory poolParams,
            AssertATokenStateParams memory aTokenParams,
            AssertAssetStateParams memory assetParams,
            uint256 borrowerInterest,
            uint256 expectedYieldLiquidityIndex,
            uint256 expectedBorrowIndex
        ) = _loadStartingParamsAndAssertState(WARP_TIME);

        _callFlashLoan();

        assertEq(borrowerInterest,            0.052513783297156325 ether);
        assertEq(expectedYieldLiquidityIndex, 1.000049875e27);  // 0.525% yield for 1% of a year * (1 - reserveFactor) = 0.00525% * 95%
        assertEq(expectedBorrowIndex,         1.000525137832971563250670960e27);

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether + borrowerInterest, 1000 ether + borrowerInterest);

        // Utilization rate has increased slightly because of borrowerInterest accruing
        assertGt(borrowRate,    0.0525e27);
        assertGt(liquidityRate, 0.0049875e27);
        assertEq(borrowRate,    0.052501181498079251917470876e27);
        assertEq(liquidityRate, 0.004989969384031269536001001e27);

        poolParams.liquidityIndex            = expectedYieldLiquidityIndex;
        poolParams.variableBorrowIndex       = expectedBorrowIndex;
        poolParams.currentLiquidityRate      = liquidityRate;
        poolParams.currentVariableBorrowRate = borrowRate;
        poolParams.lastUpdateTimestamp       = 1 + WARP_TIME;
        poolParams.accruedToTreasury         = borrowerInterest * 5/100 * 1e27 / expectedYieldLiquidityIndex + 1;  // Rounding

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);
    }

}


