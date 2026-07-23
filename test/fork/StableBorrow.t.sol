// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { Ethereum } from "sparklend-address-registry/Ethereum.sol";

import { VariableBorrowInterestRateStrategy } from "sparklend-advanced/VariableBorrowInterestRateStrategy.sol";

import { IPoolAddressesProvider } from "sparklend-v1-core/contracts/interfaces/IPoolAddressesProvider.sol";

import { DataTypes }            from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";
import { Errors }               from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";
import { ReserveConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import { StableDebtToken }      from "sparklend-v1-core/contracts/protocol/tokenization/StableDebtToken.sol";
import { VariableDebtToken }    from "sparklend-v1-core/contracts/protocol/tokenization/VariableDebtToken.sol";

import { ForkTestBase } from "./ForkTestBase.sol";

contract StableBorrowTests is ForkTestBase {

    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    address borrower = makeAddr("borrower");

    function test_stableBorrowImpossible() public {
        address[] memory reserves = pool.getReservesList();

        _supplyAndUseAsCollateral(borrower, Ethereum.WETH, 1000 ether);

        vm.startPrank(borrower);

        for (uint256 i = 0; i < reserves.length; i++) {
            DataTypes.ReserveConfigurationMap memory configuration = pool.getReserveData(reserves[i]).configuration;

            if (
                !configuration.getBorrowingEnabled() ||
                configuration.getFrozen()            ||
                _borrowCapExceeded(reserves[i], 100)
            ) {
                vm.expectRevert();
                pool.borrow(reserves[i], 100, 1, 0, borrower);
                continue;
            }

            vm.expectRevert(bytes(Errors.STABLE_BORROWING_NOT_ENABLED));
            pool.borrow(reserves[i], 100, 1, 0, borrower);
        }
    }

    function test_stableRepayImpossible() public {
        address[] memory reserves = pool.getReservesList();

        _supplyAndUseAsCollateral(borrower, Ethereum.WETH, 1000 ether);

        // Snapshot and revert to avoid issues with siloed borrowing
        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < reserves.length; i++) {
            DataTypes.ReserveConfigurationMap memory configuration = pool.getReserveData(reserves[i]).configuration;

            if (
                !configuration.getBorrowingEnabled() ||
                configuration.getFrozen()            ||
                _borrowCapExceeded(reserves[i], 100)
            ) continue;

            _borrow(borrower, reserves[i], 100);

            vm.prank(borrower);
            vm.expectRevert(bytes(Errors.NO_DEBT_OF_SELECTED_TYPE));
            pool.repay(reserves[i], 100, 1, borrower);

            vm.revertTo(snapshot);
        }
    }

    function test_stableSwapBorrowRateModeImpossible() public {
        address[] memory reserves = pool.getReservesList();

        _supplyAndUseAsCollateral(borrower, Ethereum.WETH, 1000 ether);

        // Snapshot and revert to avoid issues with siloed borrowing
        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < reserves.length; i++) {
            DataTypes.ReserveConfigurationMap memory configuration = pool.getReserveData(reserves[i]).configuration;

            if (
                !configuration.getBorrowingEnabled() ||
                configuration.getFrozen()            ||
                _borrowCapExceeded(reserves[i], 100)
            ) continue;

            _borrow(borrower, reserves[i], 100);

            // Can't switch to stable from variable with no stable borrowing enabled
            // (not possible to have stable debt to start)
            vm.prank(borrower);
            vm.expectRevert(bytes(Errors.NO_OUTSTANDING_STABLE_DEBT));
            pool.swapBorrowRateMode(reserves[i], 1);

            // Can't switch to variable from stable with no stable borrowing enabled
            // (not possible to create new stable debt)
            vm.prank(borrower);
            vm.expectRevert(bytes(Errors.STABLE_BORROWING_NOT_ENABLED));
            pool.swapBorrowRateMode(reserves[i], 2);

            vm.revertTo(snapshot);
        }
    }

    function test_rebalanceStableBorrowRateImpossible() public {
        address[] memory reserves = pool.getReservesList();

        _supplyAndUseAsCollateral(borrower, Ethereum.WETH, 1000 ether);

        // Snapshot and revert to avoid issues with siloed borrowing
        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < reserves.length; i++) {
            DataTypes.ReserveConfigurationMap memory configuration = pool.getReserveData(reserves[i]).configuration;

            if (
                !configuration.getBorrowingEnabled() ||
                configuration.getFrozen()            ||
                _borrowCapExceeded(reserves[i], 100)
            ) continue;

            _borrow(borrower, reserves[i], 100);

            vm.prank(borrower);
            vm.expectRevert(bytes(Errors.INTEREST_RATE_REBALANCE_CONDITIONS_NOT_MET));
            pool.rebalanceStableBorrowRate(reserves[i], borrower);

            vm.revertTo(snapshot);
        }
    }

    function test_rebalanceStableBorrowRateAfterIrmChangeBoundary() public {
        // Set the supply cap to be higher so the borrower can post enough ETH to borrow all the DAI
        vm.prank(Ethereum.SPARK_PROXY);
        poolConfigurator.setSupplyCap(Ethereum.WETH, 10_000_000);

        _supplyAndUseAsCollateral(borrower, Ethereum.WETH, 1_000_000 ether);

        // Borrow all the DAI so that liquidityRate == borrowRate for easier test configuration
        _borrow(borrower, Ethereum.DAI, IERC20(Ethereum.DAI).balanceOf(Ethereum.DAI_ATOKEN));

        uint256 currentLiquidityRate = pool.getReserveData(Ethereum.DAI).currentLiquidityRate;

        assertEq(currentLiquidityRate, 0.1780804294714108555998624e27);

        // Rebalance fails under normal conditions
        vm.prank(borrower);
        vm.expectRevert(bytes(Errors.INTEREST_RATE_REBALANCE_CONDITIONS_NOT_MET));
        pool.rebalanceStableBorrowRate(Ethereum.DAI, borrower);

        uint256 reserveFactor = pool.getReserveData(Ethereum.DAI).configuration.getReserveFactor();

        uint256 boundaryBaseVariableBorrowRate =
            currentLiquidityRate * 10_000 * 10_000 / (9_000 * (10_000 - reserveFactor));  // baseVariableBorrowRate = currentLiquidityRate / (0.9 * (1 - reserveFactor))

        // Update the strategy to boundary condition of 90% of liquidity rate check
        address strategy = address(new VariableBorrowInterestRateStrategy({
            provider:               IPoolAddressesProvider(Ethereum.POOL_ADDRESSES_PROVIDER),
            optimalUsageRatio:      1e27,
            baseVariableBorrowRate: boundaryBaseVariableBorrowRate - 1,
            variableRateSlope1:     0,
            variableRateSlope2:     0
        }));

        vm.prank(Ethereum.SPARK_PROXY);
        poolConfigurator.setReserveInterestRateStrategyAddress(Ethereum.DAI, strategy);

        // Same error
        vm.prank(borrower);
        vm.expectRevert(bytes(Errors.INTEREST_RATE_REBALANCE_CONDITIONS_NOT_MET));
        pool.rebalanceStableBorrowRate(Ethereum.DAI, borrower);

        // Update the strategy to pass the 90% check
        strategy = address(new VariableBorrowInterestRateStrategy({
            provider:               IPoolAddressesProvider(Ethereum.POOL_ADDRESSES_PROVIDER),
            optimalUsageRatio:      1e27,
            baseVariableBorrowRate: boundaryBaseVariableBorrowRate,
            variableRateSlope1:     0,
            variableRateSlope2:     0
        }));

        vm.prank(Ethereum.SPARK_PROXY);
        poolConfigurator.setReserveInterestRateStrategyAddress(Ethereum.DAI, strategy);

        // Get a different error, an EVM revert on line 146 of StableDebtToken.sol
        // Revert occurs in `rayDiv((currentBalance + amount).wadToRay())` portion of calculation
        // in the `mint` function because `currentBalance` and `amount` are both zero, resulting in
        // a division by zero. Since a user can not mint stable debt through the SparkLend protocol,
        // this function cannot be successfully called.
        vm.prank(borrower);
        vm.expectRevert(bytes(""));  // EvmError: Revert
        pool.rebalanceStableBorrowRate(Ethereum.DAI, borrower);
    }

    function _borrowCapExceeded(address asset, uint256 amount) internal view returns (bool) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);

        uint256 borrowCap = reserveData.configuration.getBorrowCap();

        if (borrowCap == 0) return false;

        // Borrow cap applies to combined stable + variable debt
        uint256 currentDebt =
            VariableDebtToken(reserveData.variableDebtTokenAddress).totalSupply() +
            StableDebtToken(reserveData.stableDebtTokenAddress).totalSupply();

        return currentDebt + amount > borrowCap * 10 ** reserveData.configuration.getDecimals();
    }

}
