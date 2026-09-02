// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { UserConfiguration } from "sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import { Errors }            from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";
import { DataTypes }         from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

contract SetUserUseReserveAsCollateralTestBase is SparkLendTestBase {

    address user   = makeAddr("user");
    address lender = makeAddr("lender");

    function setUp() public virtual override {
        super.setUp();

        _initCollateral({
            asset:                address(collateralAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });
    }

}

contract SetUserUseReserveAsCollateralFailureTests is SetUserUseReserveAsCollateralTestBase {

    function test_setUserUseReserveAsCollateral_whenNotActive() public {
        vm.prank(admin);
        poolConfigurator.setReserveActive(address(collateralAsset), false);

        vm.prank(user);
        vm.expectRevert(bytes(Errors.RESERVE_INACTIVE));
        pool.setUserUseReserveAsCollateral(address(collateralAsset), true);
    }

    function test_setUserUseReserveAsCollateral_whenPaused() public {
        vm.prank(admin);
        poolConfigurator.setReservePause(address(collateralAsset), true);

        vm.prank(user);
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        pool.setUserUseReserveAsCollateral(address(collateralAsset), true);
    }

    function test_setUserUseReserveAsCollateral_success_whenFrozen() public {
        _supply(user, address(collateralAsset), 1000 ether);  // Auto-enabled as collateral at supply

        vm.prank(admin);
        poolConfigurator.setReserveFreeze(address(collateralAsset), true);

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);
    }

    function test_setUserUseReserveAsCollateral_enableWithZeroScaledBalance() public {
        vm.prank(user);
        vm.expectRevert(bytes(Errors.UNDERLYING_BALANCE_ZERO));
        pool.setUserUseReserveAsCollateral(address(collateralAsset), true);
    }

    function test_setUserUseReserveAsCollateral_enableZeroLtvAsset() public {
        _supply(user, address(borrowAsset), 1000 ether);  // LTV is zero at supply so not auto-enabled

        vm.prank(user);
        vm.expectRevert(bytes(Errors.USER_IN_ISOLATION_MODE_OR_LTV_ZERO));
        pool.setUserUseReserveAsCollateral(address(borrowAsset), true);
    }

    function test_setUserUseReserveAsCollateral_enableWhileInIsolationMode() public {
        _setCollateralDebtCeiling(address(collateralAsset), 1000_00);

        _supplyAndUseAsCollateral(user, address(collateralAsset), 1000 ether);  // Isolated collateral

        address newCollateralAsset = _setUpNewCollateral({
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        _supply(user, newCollateralAsset, 1000 ether);  // Not auto-enabled while in isolation mode

        vm.prank(user);
        vm.expectRevert(bytes(Errors.USER_IN_ISOLATION_MODE_OR_LTV_ZERO));
        pool.setUserUseReserveAsCollateral(newCollateralAsset, true);
    }

    function test_setUserUseReserveAsCollateral_enableIsolatedAssetWithOtherCollateral() public {
        address isolatedAsset = _setUpNewCollateral({
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });
        _setCollateralDebtCeiling(isolatedAsset, 1000_00);

        _supplyAndUseAsCollateral(user, address(collateralAsset), 1000 ether);
        _supply(user, isolatedAsset, 1000 ether);  // Isolated assets are never auto-enabled

        vm.prank(user);
        vm.expectRevert(bytes(Errors.USER_IN_ISOLATION_MODE_OR_LTV_ZERO));
        pool.setUserUseReserveAsCollateral(isolatedAsset, true);
    }

    function test_setUserUseReserveAsCollateral_disableHealthFactorBelowOneBoundary() public {
        address newCollateralAsset = _setUpNewCollateral({
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        vm.prank(admin);
        poolConfigurator.setReserveBorrowing(address(borrowAsset), true);

        _supply(lender, address(borrowAsset), 600 ether);

        _supplyAndUseAsCollateral(user, address(collateralAsset), 1000 ether);
        _supplyAndUseAsCollateral(user, newCollateralAsset,       1000 ether);

        // NOTE: 1e10 used for boundary since HF calculations are done in 1e8 precision
        _borrow(user, address(borrowAsset), 500 ether + 1e10);

        vm.prank(user);
        vm.expectRevert(bytes(Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD));
        pool.setUserUseReserveAsCollateral(newCollateralAsset, false);

        _repay(user, address(borrowAsset), 1e10);

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(newCollateralAsset, false);

        ( ,,,,, uint256 healthFactor ) = pool.getUserAccountData(user);

        assertEq(healthFactor, 1e18);  // Remaining 1000 * 50% collateral exactly covers the 500 debt
    }

    function test_setUserUseReserveAsCollateral_disableWithOtherZeroLtvCollateral() public {
        address newCollateralAsset = _setUpNewCollateral({
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        _supplyAndUseAsCollateral(user, address(collateralAsset), 1000 ether);
        _supplyAndUseAsCollateral(user, newCollateralAsset,       1000 ether);

        // Zero the LTV after the flag is set; the user config keeps the asset as collateral
        _initCollateral({
            asset:                newCollateralAsset,
            ltv:                  0,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        vm.prank(user);
        vm.expectRevert(bytes(Errors.LTV_VALIDATION_FAILED));
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);
    }

}

contract SetUserUseReserveAsCollateralConcreteTests is SetUserUseReserveAsCollateralTestBase {

    using UserConfiguration for DataTypes.UserConfigurationMap;

    event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);
    event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);

    uint256 collateralAssetId;
    uint256 borrowAssetId;

    function setUp() public override {
        super.setUp();
        collateralAssetId = pool.getReserveData(address(collateralAsset)).id;
        borrowAssetId     = pool.getReserveData(address(borrowAsset)).id;
    }

    function test_setUserUseReserveAsCollateral_01() public proveNoOp {
        _supply(user, address(collateralAsset), 1000 ether);  // Auto-enabled as collateral at supply

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(collateralAssetId), true);

        vm.startStateDiffRecording();

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), true);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(collateralAssetId), true);
    }

    function test_setUserUseReserveAsCollateral_02() public proveNoOp {
        assertEq(aCollateralAsset.balanceOf(user), 0);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(collateralAssetId), false);

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(collateralAssetId), false);
    }

    function test_setUserUseReserveAsCollateral_03() public {
        _supply(user, address(borrowAsset), 1000 ether);  // LTV is zero at supply so not auto-enabled

        _initCollateral({
            asset:                address(borrowAsset),
            ltv:                  50_00,
            liquidationThreshold: 50_00,
            liquidationBonus:     100_01
        });

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(borrowAssetId), false);

        ( uint256 totalCollateralBase,,,,, ) = pool.getUserAccountData(user);

        assertEq(totalCollateralBase, 0);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ReserveUsedAsCollateralEnabled(address(borrowAsset), user);

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(borrowAsset), true);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(borrowAssetId), true);

        ( totalCollateralBase,,,,, ) = pool.getUserAccountData(user);

        assertEq(totalCollateralBase, 1000e8);
    }

    function test_setUserUseReserveAsCollateral_04() public {
        _supply(user, address(collateralAsset), 1000 ether);  // Auto-enabled as collateral at supply

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(collateralAssetId), true);

        ( uint256 totalCollateralBase,,,,, ) = pool.getUserAccountData(user);

        assertEq(totalCollateralBase, 1000e8);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ReserveUsedAsCollateralDisabled(address(collateralAsset), user);

        vm.prank(user);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);

        assertEq(pool.getUserConfiguration(user).isUsingAsCollateral(collateralAssetId), false);

        ( totalCollateralBase,,,,, ) = pool.getUserAccountData(user);

        assertEq(totalCollateralBase, 0);
    }

}
