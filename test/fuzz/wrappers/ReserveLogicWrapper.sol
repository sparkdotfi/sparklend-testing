// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IPoolAddressesProvider } from 'sparklend-v1-core/contracts/interfaces/IPoolAddressesProvider.sol';

import { ReserveLogic } from "sparklend-v1-core/contracts/protocol/libraries/logic/ReserveLogic.sol";
import { Pool }         from "sparklend-v1-core/contracts/protocol/pool/Pool.sol";

contract ReserveLogicWrapper is Pool {

    constructor(IPoolAddressesProvider provider) Pool(provider) {}

    // Necessary to upgrade from the existing Pool implementation
    function getRevision() internal pure override returns (uint256) {
        return 0x6;
    }

    /**********************************************************************************************/
    /*** Wrapper functions                                                                      ***/
    /**********************************************************************************************/

    function cumulateToLiquidityIndex(
        address reserve,
        uint256 totalLiquidity,
        uint256 amount
    ) external returns (uint256 updatedLiquidityIndex) {
        updatedLiquidityIndex
            = ReserveLogic.cumulateToLiquidityIndex(_reserves[reserve], totalLiquidity, amount);
    }

}
