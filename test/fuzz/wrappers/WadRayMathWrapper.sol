// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import {WadRayMath} from "sparklend-v1-core/contracts/protocol/libraries/math/WadRayMath.sol";

contract WadRayMathWrapper {
    function rayMul(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.rayMul(a, b);
    }

    function rayDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.rayDiv(a, b);
    }
}
