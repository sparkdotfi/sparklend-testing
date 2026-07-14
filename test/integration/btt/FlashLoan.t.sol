// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { Errors } from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";

import {
    MockReceiverBasic,
    MockReceiverReturnFalse,
    MockReceiverInsufficientApprove,
    MockReceiverInsufficientBalance,
    MockReceiverMintPremium
} from "test/mocks/MockReceiver.sol";

import { FlashLoanSimpleSuccessTests } from "test/integration/btt/FlashLoanSimple.t.sol";

import { IERC20, SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract FlashLoanTestBase is SparkLendTestBase {

    address borrower = makeAddr("borrower");
    address supplier = makeAddr("supplier");

    address receiver;

    // Renaming assets for this test for easier comprehension
    address asset0;
    address asset1;

    function setUp() public virtual override {
        super.setUp();

        receiver = address(new MockReceiverBasic(address(poolConfigurator), address(pool)));

        asset0 = address(borrowAsset);
        asset1 = address(collateralAsset);

        // Set up necessary conditions for success
        _supply(supplier, asset0, 1000 ether);
        _supply(supplier, asset1, 1000 ether);

        vm.startPrank(admin);
        poolConfigurator.setReserveFlashLoaning(asset0, true);
        poolConfigurator.setReserveFlashLoaning(asset1, true);
        vm.stopPrank();
    }

    function _callFlashLoan(uint256 amount0, uint256 amount1, address onBehalfOf) internal virtual {
        address[] memory assets  = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes   = new uint256[](2);

        assets[0] = asset0;
        assets[1] = asset1;

        amounts[0] = amount0;
        amounts[1] = amount1;

        modes[0] = 0;
        modes[1] = 0;

        pool.flashLoan(receiver, assets, amounts, modes, onBehalfOf, new bytes(0), 0);
    }

}

contract FlashLoanFailureTests is FlashLoanTestBase {

    function test_flashLoan_whenLengthAssetsDoesNotEqualLengthAmounts() public {
        address[] memory assets  = new address[](3);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes   = new uint256[](2);

        assets[0] = asset0;
        assets[1] = asset1;

        amounts[0] = 1;
        amounts[1] = 1;

        modes[0] = 0;
        modes[1] = 0;

        vm.expectRevert(bytes(Errors.INCONSISTENT_FLASHLOAN_PARAMS));
        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);

        assets = new address[](1);  // Check less than case as well
        assets[0] = asset0;

        vm.expectRevert(bytes(Errors.INCONSISTENT_FLASHLOAN_PARAMS));
        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);
    }

    function test_flashLoan_whenModesLengthLtAmounts() public {
        address[] memory assets  = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes   = new uint256[](1);

        assets[0] = asset0;
        assets[1] = asset1;

        amounts[0] = 1;
        amounts[1] = 1;

        modes[0] = 0;

        vm.expectRevert(stdError.indexOOBError);
        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);

        // Demonstrate modes can be greater than
        modes = new uint256[](3);
        modes[0] = 0;
        modes[1] = 0;
        modes[2] = 0;

        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);
    }

    function test_flashLoan_whenNotActive_asset0() public {
        // Avoid RESERVE_LIQUIDITY_NOT_ZERO error when deactivating
        _withdraw(supplier, asset0, 1000 ether);

        vm.prank(admin);
        poolConfigurator.setReserveActive(asset0, false);

        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_whenNotActive_asset1() public {
        // Avoid RESERVE_LIQUIDITY_NOT_ZERO error when deactivating
        _withdraw(supplier, asset1, 1000 ether);

        vm.prank(admin);
        poolConfigurator.setReserveActive(asset1, false);

        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_whenPaused_asset0() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(asset0, true);

        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_whenPaused_asset1() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(asset1, true);

        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_whenFrozen_asset0() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(asset0, true);

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_whenFrozen_asset1() public {
        vm.prank(admin);
        poolConfigurator.setReserveFreeze(asset1, true);

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_flashLoanNotEnabled_asset0() public {
        vm.prank(admin);
        poolConfigurator.setReserveFlashLoaning(asset0, false);

        vm.expectRevert(bytes(Errors.FLASHLOAN_DISABLED));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_flashLoanNotEnabled_asset1() public {
        vm.prank(admin);
        poolConfigurator.setReserveFlashLoaning(asset1, false);

        vm.expectRevert(bytes(Errors.FLASHLOAN_DISABLED));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_insufficientLiquidityBoundary_asset0() public {
        vm.expectRevert(stdError.arithmeticError);
        _callFlashLoan(1000 ether + 1, 1000 ether, borrower);

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_insufficientLiquidityBoundary_asset1() public {
        vm.expectRevert(stdError.arithmeticError);
        _callFlashLoan(1000 ether, 1000 ether + 1, borrower);

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_receiverReturnsFalse() public {
        receiver = address(new MockReceiverReturnFalse(address(poolConfigurator), address(pool)));

        vm.expectRevert(bytes(Errors.INVALID_FLASHLOAN_EXECUTOR_RETURN));
        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_receiverInsufficientApprovalBoundary_asset0() public {
        receiver = address(new MockReceiverInsufficientApprove(address(poolConfigurator), address(pool), asset0));

        vm.expectRevert(stdError.arithmeticError);
        _callFlashLoan(1000 ether, 1000 ether, borrower);

        receiver = address(new MockReceiverBasic(address(poolConfigurator), address(pool)));

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_receiverInsufficientApprovalBoundary_asset1() public {
        receiver = address(new MockReceiverInsufficientApprove(address(poolConfigurator), address(pool), asset1));

        vm.expectRevert(stdError.arithmeticError);
        _callFlashLoan(1000 ether, 1000 ether, borrower);

        receiver = address(new MockReceiverBasic(address(poolConfigurator), address(pool)));

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_receiverInsufficientBalanceBoundary_asset0() public {
        receiver = address(new MockReceiverInsufficientBalance(address(poolConfigurator), address(pool), asset0));

        vm.expectRevert(stdError.arithmeticError);
        _callFlashLoan(1000 ether, 1000 ether, borrower);

        receiver = address(new MockReceiverBasic(address(poolConfigurator), address(pool)));

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_receiverInsufficientBalanceBoundary_asset1() public {
        receiver = address(new MockReceiverInsufficientBalance(address(poolConfigurator), address(pool), asset1));

        vm.expectRevert(stdError.arithmeticError);
        _callFlashLoan(1000 ether, 1000 ether, borrower);

        receiver = address(new MockReceiverBasic(address(poolConfigurator), address(pool)));

        _callFlashLoan(1000 ether, 1000 ether, borrower);
    }

    function test_flashLoan_userTriesToFlashLoanIntoBorrow_asset0() public {
        address[] memory assets  = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes   = new uint256[](2);

        assets[0] = asset0;
        assets[1] = asset1;

        amounts[0] = 1000 ether;
        amounts[1] = 1000 ether;

        modes[0] = 1;
        modes[1] = 0;

        vm.expectRevert("FLASHLOAN_INTO_BORROW_DEPRECATED");
        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);
    }

    function test_flashLoan_userTriesToFlashLoanIntoBorrow_asset1() public {
        address[] memory assets  = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes   = new uint256[](2);

        assets[0] = asset0;
        assets[1] = asset1;

        amounts[0] = 1000 ether;
        amounts[1] = 1000 ether;

        modes[0] = 0;
        modes[1] = 1;

        vm.expectRevert("FLASHLOAN_INTO_BORROW_DEPRECATED");
        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);
    }

}

// NOTE: These tests prove that the `flashLoan` contract works in the exact same way as
//       `flashLoanSimple` when only one asset is used.
contract FlashLoanFlashLoanSimpleEquivalenceTests is FlashLoanSimpleSuccessTests {

    function setUp() public virtual override {
        super.setUp();

        // Overwrite the receiver to work with the interface in flashLoan
        receiver = address(new MockReceiverMintPremium(address(poolConfigurator), address(pool)));
    }

    function _callFlashLoan() internal override {
        address[] memory assets  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes   = new uint256[](1);

        assets[0]  = address(borrowAsset);  // asset0 not defined in inherited contract
        amounts[0] = amount;
        modes[0]   = 0;

        pool.flashLoan(receiver, assets, amounts, modes, address(borrower), new bytes(0), 0);
    }

}

// NOTE: These tests use the same assertions and logic branches as `flashLoanSimple` but with
//       two identical sets of assertions (state changes are the same), one for each asset.
contract FlashLoanSuccessTests is FlashLoanTestBase {

    uint256 amount;  // Amount to set in the modifier

    function setUp() public virtual override {
        super.setUp();

        // Mint the premium to allow for successful flashloans with premiums
        receiver = address(new MockReceiverMintPremium(address(poolConfigurator), address(pool)));

        address collateral1 = _setUpNewCollateral(50_00, 50_00, 100_01);
        address collateral2 = _setUpNewCollateral(50_00, 50_00, 100_01);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(asset0), true);
        poolConfigurator.setReserveBorrowing(address(asset1), true);
        vm.stopPrank();

        // Set up the same situations so the state changes can be compared
        _supplyAndUseAsCollateral(borrower, address(collateral1), 1000 ether);
        _supplyAndUseAsCollateral(borrower, address(collateral2), 1000 ether);

        _borrow(borrower, address(asset0), 100 ether);
        _borrow(borrower, address(asset1), 100 ether);

        vm.startPrank(admin);
        poolConfigurator.setReserveFlashLoaning(address(asset0), true);
        poolConfigurator.setReserveFlashLoaning(address(asset1), true);
        vm.stopPrank();
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

    modifier givenUserIsNotFlashBorrower { _; }

    modifier givenUserIsFlashBorrower {
        vm.prank(admin);
        aclManager.addFlashBorrower(borrower);
        _;
    }

    /**********************************************************************************************/
    /*** BTT tests                                                                              ***/
    /**********************************************************************************************/

    function test_flashLoan_01()
        whenNoTimeHasPassed
        whenAmountIsZero
        public
    {
        _noStateChangeTest();
    }

    function test_flashLoan_02()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        _noStateChangeTest();
    }

    function test_flashLoan_03()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        // No premium to protocol when total premium is still zero
        _noStateChangeTest();
    }

    function test_flashLoan_04()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsNotFlashBorrower
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        (
            AssertPoolReserveStateParams memory poolParams0,
            AssertATokenStateParams memory aTokenParams0,
            AssertAssetStateParams memory assetParams0,
            ,
            ,
        ) = _loadStartingParamsAndAssertState(0);

        _assertAsset1StateMatchesAsset0(poolParams0, aTokenParams0, assetParams0);

        _callFlashLoan();

        aTokenParams0.userBalance = 1010 ether;  // 100 flashborrow * 10% premium
        aTokenParams0.totalSupply = 1010 ether;  // 100 flashborrow * 10% premium

        assetParams0.aTokenBalance = 910 ether;  // 100 flashborrow * 10% premium

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1010 ether);

        // Utilization rate has decreased because of premium being added to the pool
        assertLt(borrowRate,    0.0525e27);
        assertLt(liquidityRate, 0.0049875e27);  // 5.25% * 95%
        assertEq(borrowRate,    0.052475247524752475247524752e27);
        assertEq(liquidityRate, 0.004935790608763846681697872e27);

        poolParams0.currentLiquidityRate      = liquidityRate + 1;  // Rounding
        poolParams0.currentVariableBorrowRate = borrowRate + 1;     // Rounding

        // 1e27 + 10% of 100 borrow = 1.01e27 - Note that this was updated WITHOUT time passing
        // Also note that the borrowIndex does not update because they do not owe any more interest
        poolParams0.liquidityIndex = 1.01e27;

        _assertPoolReserveState(poolParams0);
        _assertATokenState(aTokenParams0);
        _assertAssetState(assetParams0);

        _assertAsset1StateMatchesAsset0(poolParams0, aTokenParams0, assetParams0);
    }

    function test_flashLoan_05()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsNotFlashBorrower
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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

        _callFlashLoan();

        aTokenParams.userBalance = 1009.5 ether;  // 100 + 9.5% premium (5% of 10% to protocol)
        aTokenParams.totalSupply = 1009.5 ether;  // 100 + 9.5% premium (5% of 10% to protocol)

        // 100 + full 10% premium (0.5% protocol fee accounted with accruedToTreasury)
        assetParams.aTokenBalance = 910 ether;

        ( uint256 borrowRate, uint256 liquidityRate ) = _getUpdatedRates(100 ether, 1010 ether);

        // Utilization rate has decreased because of premium being added to the pool
        assertLt(borrowRate,    0.0525e27);
        assertLt(liquidityRate, 0.0049875e27);  // 5.25% * 95%
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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

        // NOTE: Below is not directly relevant to the flashloan test, but is is a demonstration
        //       of how the protocol fee is reflected as a state variable and then a real amount later on
        //       These asserts ensure that the calculation is done correctly.

        assertEq(pool.getReserveNormalizedIncome(asset0), 1.0095e27);

        address[] memory assets = new address[](2);
        assets[0] = asset0;
        assets[1] = asset1;

        pool.mintToTreasury(assets);

        // Reserve normalized income doesn't change because accruedToTreasury is always factored into the index
        assertEq(pool.getReserveNormalizedIncome(asset0), 1.0095e27);

        poolParams.accruedToTreasury = 0;

        aTokenParams.totalSupply = 1010 ether - 1;  // 0.5 ether - 1 minted to the treasury

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

        _repay(borrower, asset0, 100 ether);
        _repay(borrower, asset1, 100 ether);

        _withdraw(supplier, asset0, 1009.5 ether);
        _withdraw(supplier, asset1, 1009.5 ether);
        _withdraw(treasury, asset0, 0.5 ether - 1);  // Rounding
        _withdraw(treasury, asset1, 0.5 ether - 1);  // Rounding

        IERC20 aToken0 = IERC20(pool.getReserveData(asset0).aTokenAddress);
        IERC20 aToken1 = IERC20(pool.getReserveData(asset1).aTokenAddress);

        assertEq(aToken0.balanceOf(treasury), 0);
        assertEq(aToken0.balanceOf(supplier), 0);
        assertEq(aToken0.totalSupply(),       0);

        assertEq(aToken1.balanceOf(treasury), 0);
        assertEq(aToken1.balanceOf(supplier), 0);
        assertEq(aToken1.totalSupply(),       0);

        assertEq(IERC20(asset0).balanceOf(treasury),              0.5 ether - 1);  // Rounding
        assertEq(IERC20(asset0).balanceOf(supplier),              1009.5 ether);
        assertEq(IERC20(asset0).balanceOf(address(aBorrowAsset)), 1);
    }

    function test_flashLoan_06()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsFlashBorrower
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        // No state changes when there are no premiums and no time has passed
        _noStateChangeTest();
    }

    function test_flashLoan_07()
        whenNoTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsFlashBorrower
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        // No state changes when there are no premiums and no time has passed
        _noStateChangeTest();
    }

    function test_flashLoan_08()
        whenSomeTimeHasPassed
        whenAmountIsZero
        public
    {
        _timePassedNoFeesTest();
    }

    function test_flashLoan_09()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        _timePassedNoFeesTest();
    }

    function test_flashLoan_10()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsZero
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        // No premium to protocol when total premium is still zero
        _timePassedNoFeesTest();
    }

    function test_flashLoan_11()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsNotFlashBorrower
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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);
    }

    function test_flashLoan_12()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsNotFlashBorrower
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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

        _callFlashLoan();

        assertEq(borrowerInterest,            0.052513783297156325 ether);
        assertEq(expectedYieldLiquidityIndex, 1.000049875e27);  // 0.525% yield for 1% of a year * (1 - reserveFactor) = 0.00525% * 95%
        assertEq(expectedBorrowIndex,         1.000525137832971563250670960e27);

        aTokenParams.userBalance = 1009.549875 ether;  // 100 + 9.5% premium (5% of 10% to protocol) + supplier yield
        aTokenParams.totalSupply = 1009.549875 ether;  // 100 + 9.5% premium (5% of 10% to protocol) + supplier yield

        // 100 + full 10% premium (0.5% protocol fee accounted with accruedToTreasury)
        assetParams.aTokenBalance = 910 ether;

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

        // Amount accrued to the treasury from the flashloan premium, scaled against the resulting liquidityIndex
        uint256 accruedToTreasury = uint256(0.5 ether * 1e27) / poolParams.liquidityIndex;

        assertEq(accruedToTreasury, 0.495270243437349443 ether);

        poolParams.accruedToTreasury += accruedToTreasury;

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);
    }

    function test_flashLoan_13()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsFlashBorrower
        givenFlashLoanPremiumToProtocolIsZero
        public
    {
        // No premiums with flash borrower
        _timePassedNoFeesTest();
    }

    function test_flashLoan_14()
        whenSomeTimeHasPassed
        whenAmountIsNotZero
        givenTotalPremiumIsNotZero
        givenUserIsFlashBorrower
        givenFlashLoanPremiumToProtocolIsNotZero
        public
    {
        // No premiums with flash borrower
        _timePassedNoFeesTest();
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
            expectedLiquidityRate: 0.00525e27 * 0.95,
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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

        _callFlashLoan();

        // No state changes
        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);
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

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);

        _callFlashLoan();

        assertEq(borrowerInterest,            0.052513783297156325 ether);
        assertEq(expectedYieldLiquidityIndex, 1.000049875e27);  // 0.525% yield for 1% of a year = 0.00525% * 95%
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
        poolParams.accruedToTreasury         = borrowerInterest * 5/100 * 1e27 / expectedYieldLiquidityIndex + 1;  // Accruing from borrower yield

        _assertPoolReserveState(poolParams);
        _assertATokenState(aTokenParams);
        _assertAssetState(assetParams);

        _assertAsset1StateMatchesAsset0(poolParams, aTokenParams, assetParams);
    }

    function _callFlashLoan() internal virtual {
        address[] memory assets  = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes   = new uint256[](2);

        assets[0] = asset0;
        assets[1] = asset1;

        amounts[0] = amount;
        amounts[1] = amount;

        modes[0] = 0;
        modes[1] = 0;

        vm.prank(borrower);
        pool.flashLoan(receiver, assets, amounts, modes, borrower, new bytes(0), 0);
    }

    function _assertAsset1StateMatchesAsset0(
        AssertPoolReserveStateParams memory poolParams0,
        AssertATokenStateParams memory aTokenParams0,
        AssertAssetStateParams memory assetParams0
    )
        internal
    {
        AssertPoolReserveStateParams memory poolParams1   = poolParams0;
        AssertATokenStateParams      memory aTokenParams1 = aTokenParams0;
        AssertAssetStateParams       memory assetParams1  = assetParams0;

        poolParams1.asset    = asset1;
        aTokenParams1.aToken = pool.getReserveData(asset1).aTokenAddress;
        assetParams1.asset   = asset1;

        _assertPoolReserveState(poolParams1);
        _assertATokenState(aTokenParams1);
        _assertAssetState(assetParams1);
    }

}

