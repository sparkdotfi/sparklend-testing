// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IPool }                  from "sparklend-v1-core/contracts/interfaces/IPool.sol";
import { IPoolAddressesProvider } from "sparklend-v1-core/contracts/interfaces/IPoolAddressesProvider.sol";
import { IPoolConfigurator }      from "sparklend-v1-core/contracts/interfaces/IPoolConfigurator.sol";

import { Ethereum } from "sparklend-address-registry/Ethereum.sol";

import { UserActions } from "src/UserActions.sol";

contract ForkTestBase is UserActions {

    IPool                  constant pool                  = IPool(Ethereum.POOL);
    IPoolAddressesProvider constant poolAddressesProvider = IPoolAddressesProvider(Ethereum.POOL_ADDRESSES_PROVIDER);
    IPoolConfigurator      constant poolConfigurator      = IPoolConfigurator(Ethereum.POOL_CONFIGURATOR);

    function setUp() public {
        vm.createSelectFork(getChain("mainnet").rpcUrl, 19483900);  // March 21, 2024
    }

    /**********************************************************************************************/
    /*** User helper functions                                                                  ***/
    /**********************************************************************************************/

    function _useAsCollateral(address user, address newCollateralAsset) internal {
        _useAsCollateral(address(pool), user, newCollateralAsset);
    }

    function _borrow(address user, address asset, uint256 amount) internal {
        _borrow(address(pool), user, asset, amount);
    }

    function _supply(address user, address asset, uint256 amount) internal {
        _supply(address(pool), user, asset, amount);
    }

    function _repay(address user, address asset, uint256 amount) internal {
        _repay(address(pool), user, asset, amount);
    }

    function _withdraw(address user, address asset, uint256 amount) internal {
        _withdraw(address(pool), user, asset, amount);
    }

    function _supplyAndUseAsCollateral(address user, address asset, uint256 amount) internal {
        _supplyAndUseAsCollateral(address(pool), user, asset, amount);
    }

    /**********************************************************************************************/
    /*** Debugging utility functions                                                            ***/
    /**********************************************************************************************/

    function _etchLibrary(address deployedLib) internal {
        string memory libName;

        if      (deployedLib == Ethereum.BORROW_LOGIC)      libName = "BorrowLogic";
        else if (deployedLib == Ethereum.BRIDGE_LOGIC)      libName = "BridgeLogic";
        else if (deployedLib == Ethereum.EMODE_LOGIC)       libName = "EmodeLogic";
        else if (deployedLib == Ethereum.FLASH_LOAN_LOGIC)  libName = "FlashLoanLogic";
        else if (deployedLib == Ethereum.LIQUIDATION_LOGIC) libName = "LiquidationLogic";
        else if (deployedLib == Ethereum.POOL_LOGIC)        libName = "PoolLogic";
        else if (deployedLib == Ethereum.SUPPLY_LOGIC)      libName = "SupplyLogic";
        else revert("Unknown library");

        string memory path = string(abi.encodePacked(libName, ".sol:", libName));
        address debuggingLib = deployCode(path, bytes(""));
        vm.etch(deployedLib, debuggingLib.code);
    }

}

