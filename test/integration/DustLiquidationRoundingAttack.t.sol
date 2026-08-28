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

    function test_xautRounding_createsBadDebtWithOneRepaymentReverts() public {
        // Setup
        uint256 xautSeed       = 252;
        uint256 initialShares  = 120;
        uint256 daiBorrow      = 1.06599999e18;

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

        vm.expectRevert(abi.encode("35"));
        vm.prank(borrower);
        pool.repayWithATokens(address(xaut), 1, 2);
    }

    function test_xautRounding_selfLiquidationsNoLongerValueExtractive() public {
        // Setup
        uint256 xautSeed       = 252;
        uint256 initialShares  = 120;
        uint256 daiBorrow      = 1.008e18;  // 80% LTV of the $1.26 of XAUT collateral
        uint256 oneAtomPayment = 0.005e18;  // $0.005 of DAI == value of one XAUT atom

        IERC20 variableDebtDai = IERC20(pool.getReserveData(address(dai)).variableDebtTokenAddress);

        _setIndexes();

        _supply(liquidityProvider, address(dai), 2e18);

        // Step 1: Supply 252 XAUT atoms, 120 scaled shares at the 2.1 RAY liquidity index.
        _supply(borrower, address(xaut), xautSeed);

        assertEq(aXaut.scaledBalanceOf(borrower), initialShares);
        assertEq(aXaut.balanceOf(borrower),       252);

        // Step 2: Borrow DAI up to the LTV limit.
        _borrow(borrower, address(dai), daiBorrow);

        ( , , , , , uint256 healthFactorAtBorrow ) = pool.getUserAccountData(borrower);
        assertEq(healthFactorAtBorrow, 1.0625e18);

        // Step 3: Warp forward so accrued borrow interest puts the position underwater.
        vm.warp(block.timestamp + 730 days);

        ( , , , , , uint256 healthFactorUnderwater ) = pool.getUserAccountData(borrower);
        assertEq(healthFactorUnderwater, 0.937502552199700053e18);

        // Step 4: Self-liquidate in one-atom increment, taking aTokens and paying with borrowed DAI.
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);

        assertEq(aXaut.scaledBalanceOf(borrower),     initialShares);
        assertEq(aXaut.balanceOf(borrower),           252);
        assertEq(aXaut.scaledBalanceOf(liquidator),   0);
        assertEq(aXaut.balanceOf(liquidator),         0);
        assertEq(variableDebtDai.balanceOf(borrower), 1.142396884633911925e18);

        vm.prank(liquidator);
        pool.liquidationCall(address(xaut), address(dai), borrower, oneAtomPayment, true);

        // The one seized atom scales down to zero shares, so no collateral is transferred.
        assertEq(aXaut.scaledBalanceOf(borrower),     initialShares);
        assertEq(aXaut.balanceOf(borrower),           252);
        assertEq(aXaut.scaledBalanceOf(liquidator),   0);
        assertEq(aXaut.balanceOf(liquidator),         0);
        assertEq(variableDebtDai.balanceOf(borrower), 1.142396884633911925e18 - oneAtomPayment + 1);

        ( , , , , , uint256 healthFactorAfterLiquidation ) = pool.getUserAccountData(borrower);

        // Each call only burns debt, so the health factor increases and liquidations stop
        // being possible. Under the old rounding it fell with every call, down to zero collateral.
        assertEq(healthFactorAfterLiquidation, 0.94162381611576237e18);
    }

}
