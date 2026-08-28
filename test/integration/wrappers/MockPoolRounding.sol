// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IPoolAddressesProvider } from "sparklend-v1-core/contracts/interfaces/IPoolAddressesProvider.sol";

import { Pool }      from "sparklend-v1-core/contracts/protocol/pool/Pool.sol";
import { DataTypes } from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

// Foundry equivalent of the `MockPoolRounding` used by the original TypeScript PoC
// (https://gist.github.com/santipu-alt/7d07bf2cdb7990fed58a79d3273fad98).
//
// It pins a reserve's liquidity and variable-borrow indexes to fixed values and zeroes the rates,
// so elapsed time never changes the atomic rounding result. This is only a test harness for setting
// state; it does not alter any of the SparkLend logic under test.
contract MockPoolRounding is Pool {

    constructor(IPoolAddressesProvider provider) Pool(provider) {}

    // Necessary to upgrade from the existing Pool implementation (base POOL_REVISION == 0x5).
    function getRevision() internal pure override returns (uint256) {
        return 0x6;
    }

    function setReserveIndexes(
        address asset,
        uint128 liquidityIndex,
        uint128 variableBorrowIndex
    ) external onlyPoolAdmin {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        reserve.liquidityIndex            = liquidityIndex;
        reserve.variableBorrowIndex       = variableBorrowIndex;
        reserve.currentLiquidityRate      = 0;
        reserve.currentVariableBorrowRate = 0;
        reserve.lastUpdateTimestamp       = uint40(block.timestamp);
    }

}
