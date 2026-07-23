// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { Ethereum } from "sparklend-address-registry/Ethereum.sol";

import { SafeERC20 } from "sparklend-v1-core/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol";
import { IERC20 }    from "sparklend-v1-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol";

import { BaseImmutableAdminUpgradeabilityProxy }
    from "sparklend-v1-core/contracts/protocol/libraries/aave-upgradeability/BaseImmutableAdminUpgradeabilityProxy.sol";

import { ConfiguratorInputTypes } from "sparklend-v1-core/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol";
import { DataTypes }              from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";
import { ReserveConfiguration }   from "sparklend-v1-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";

import { AToken }            from "sparklend-v1-core/contracts/protocol/tokenization/AToken.sol";
import { VariableDebtToken } from "sparklend-v1-core/contracts/protocol/tokenization/VariableDebtToken.sol";
import { Pool }              from "sparklend-v1-core/contracts/protocol/pool/Pool.sol";

import { ForkTestBase } from "./ForkTestBase.sol";

contract UpgradeTest is ForkTestBase {

    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using SafeERC20            for IERC20;

    struct ReserveState {
        address aToken;
        address variableDebtToken;
        uint256 aTokenSupply;
        uint256 variableDebtSupply;
        uint256 liquidityIndex;
        uint256 variableBorrowIndex;
        string  aTokenName;
        string  aTokenSymbol;
        string  debtTokenName;
        string  debtTokenSymbol;
    }

    function test_upgrade() public {
        address[] memory reserves = pool.getReservesList();

        // Step 1: Get the state of the pool and reserves before the upgrade

        ReserveState[] memory beforeStates = new ReserveState[](reserves.length);
        for (uint256 i = 0; i < reserves.length; i++) {
            beforeStates[i] = _getReserveState(reserves[i]);
        }

        address poolImplBefore         = _getPoolImplementation();
        uint256 reservesCountBefore    = pool.getReservesCount();
        uint16  maxReservesBefore      = pool.MAX_NUMBER_RESERVES();
        uint128 flashLoanPremiumBefore = pool.FLASHLOAN_PREMIUM_TOTAL();

        // Step 2: Deploy the new implementations

        Pool              newPoolImpl         = new Pool(poolAddressesProvider);
        AToken            newATokenImpl       = new AToken(pool);
        VariableDebtToken newVarDebtTokenImpl = new VariableDebtToken(pool);

        // Step 3: Update the pool and reserves

        vm.startPrank(Ethereum.SPARK_PROXY);

        poolAddressesProvider.setPoolImpl(address(newPoolImpl));

        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i];

            AToken currentAToken = AToken(beforeStates[i].aToken);

            poolConfigurator.updateAToken(ConfiguratorInputTypes.UpdateATokenInput({
                asset                : asset,
                treasury             : currentAToken.RESERVE_TREASURY_ADDRESS(),
                incentivesController : address(currentAToken.getIncentivesController()),
                name                 : beforeStates[i].aTokenName,
                symbol               : beforeStates[i].aTokenSymbol,
                implementation       : address(newATokenImpl),
                params               : ""
            }));

            VariableDebtToken currentDebtToken = VariableDebtToken(beforeStates[i].variableDebtToken);

            poolConfigurator.updateVariableDebtToken(ConfiguratorInputTypes.UpdateDebtTokenInput({
                asset                : asset,
                incentivesController : address(currentDebtToken.getIncentivesController()),
                name                 : beforeStates[i].debtTokenName,
                symbol               : beforeStates[i].debtTokenSymbol,
                implementation       : address(newVarDebtTokenImpl),
                params               : ""
            }));
        }

        vm.stopPrank();

        // Step 4: Check the state of the pool and reserves after the upgrade

        address poolImplAfter = _getPoolImplementation();

        assertEq(poolImplAfter, address(newPoolImpl));

        assertTrue(poolImplAfter != poolImplBefore);

        assertEq(poolAddressesProvider.getPool(),    address(pool));
        assertEq(address(pool.ADDRESSES_PROVIDER()), address(poolAddressesProvider));
        assertEq(pool.getReservesCount(),            reservesCountBefore);
        assertEq(pool.MAX_NUMBER_RESERVES(),         maxReservesBefore);
        assertEq(pool.FLASHLOAN_PREMIUM_TOTAL(),     flashLoanPremiumBefore);

        address[] memory reservesAfterPoolUpgrade = pool.getReservesList();

        assertEq(reservesAfterPoolUpgrade.length, reserves.length);

        for (uint256 i = 0; i < reserves.length; i++) {
            assertEq(reservesAfterPoolUpgrade[i], reserves[i]);
        }

        // Check before/after state for every single reserve
        for (uint256 i = 0; i < reserves.length; i++) {
            ReserveState memory beforeUpgrade = beforeStates[i];
            ReserveState memory afterUpgrade  = _getReserveState(reserves[i]);

            assertEq(afterUpgrade.aToken,              beforeUpgrade.aToken);
            assertEq(afterUpgrade.variableDebtToken,   beforeUpgrade.variableDebtToken);
            assertEq(afterUpgrade.aTokenSupply,        beforeUpgrade.aTokenSupply);
            assertEq(afterUpgrade.variableDebtSupply,  beforeUpgrade.variableDebtSupply);
            assertEq(afterUpgrade.liquidityIndex,      beforeUpgrade.liquidityIndex);
            assertEq(afterUpgrade.variableBorrowIndex, beforeUpgrade.variableBorrowIndex);
            assertEq(afterUpgrade.aTokenName,          beforeUpgrade.aTokenName);
            assertEq(afterUpgrade.aTokenSymbol,        beforeUpgrade.aTokenSymbol);
            assertEq(afterUpgrade.debtTokenName,       beforeUpgrade.debtTokenName);
            assertEq(afterUpgrade.debtTokenSymbol,     beforeUpgrade.debtTokenSymbol);
        }

        // Check that the pool and tokens are still fully functional end-to-end after the upgrade, for every reserve
        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i];

            DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);

            if (reserveData.configuration.getFrozen()) continue;

            uint256 supplyCap = reserveData.configuration.getSupplyCap();
            if (supplyCap != 0) {
                if (
                    AToken(reserveData.aTokenAddress).totalSupply() + 1_000 >
                    supplyCap * 10 ** reserveData.configuration.getDecimals()
                ) continue;
            }

            address supplier = makeAddr(string.concat("supplier", vm.toString(i)));

            _fundAndSupply(asset, supplier, 1_000);
            _withdraw(supplier, asset, 500);

            reserveData = pool.getReserveData(asset);

            if (!reserveData.configuration.getBorrowingEnabled()) continue;

            uint256 borrowCap = reserveData.configuration.getBorrowCap();
            if (borrowCap != 0) {
                if (
                    VariableDebtToken(reserveData.variableDebtTokenAddress).totalSupply() + 1_000 >
                    borrowCap * 10 ** reserveData.configuration.getDecimals()
                ) continue;
            }

            address borrower = makeAddr(string.concat("borrower", vm.toString(i)));

            _supplyAndUseAsCollateral(borrower, Ethereum.WETH, 1 ether);
            _borrow(borrower, asset, 1_000);
            _fundAndRepay(asset, borrower, 1_000);
        }
    }

    function _getPoolImplementation() internal returns (address) {
        vm.prank(address(poolAddressesProvider));
        return BaseImmutableAdminUpgradeabilityProxy(payable(address(pool))).implementation();
    }

    function _fundAndSupply(address asset, address user, uint256 amount) internal {
        deal(asset, user, amount);

        vm.startPrank(user);
        IERC20(asset).safeApprove(address(pool), amount);
        pool.supply(asset, amount, user, 0);
        vm.stopPrank();
    }

    function _fundAndRepay(address asset, address user, uint256 amount) internal {
        deal(asset, user, amount);

        vm.startPrank(user);
        IERC20(asset).safeApprove(address(pool), amount);
        pool.repay(asset, amount, 2, user);
        vm.stopPrank();
    }

    function _getReserveState(address asset) internal view returns (ReserveState memory state) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);

        state.aToken              = reserveData.aTokenAddress;
        state.variableDebtToken   = reserveData.variableDebtTokenAddress;
        state.aTokenSupply        = AToken(state.aToken).scaledTotalSupply();
        state.variableDebtSupply  = VariableDebtToken(state.variableDebtToken).scaledTotalSupply();
        state.liquidityIndex      = reserveData.liquidityIndex;
        state.variableBorrowIndex = reserveData.variableBorrowIndex;
        state.aTokenName          = AToken(state.aToken).name();
        state.aTokenSymbol        = AToken(state.aToken).symbol();
        state.debtTokenName       = VariableDebtToken(state.variableDebtToken).name();
        state.debtTokenSymbol     = VariableDebtToken(state.variableDebtToken).symbol();
    }

}
