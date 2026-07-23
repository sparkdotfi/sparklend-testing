// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

import { WadRayMathWrapper } from "sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

// Pure arithmetic proof of the "two-leg ceil overshoot" seam in LiquidationLogic.
//
// A liquidation splits one budget into two ceil-rounded legs: the burn (actualCollateralToLiquidate)
// and the fee (liquidationProtocolFeeAmount). Since ceil(a/I) + ceil(b/I) can exceed ceil((a+b)/I)
// by 1, the two scaled legs can sum to one more than the user's scaled balance S, even when the
// underlying budget a+b <= balanceOf = floor(S*I) keeps each single conversion safe.
contract LiquidationFeeDoubleRoundTests is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    WadRayMathWrapper internal _wadRayMathWrapper;

    function setUp() public override {
        _wadRayMathWrapper = new WadRayMathWrapper();
    }

    // Simple example of the two-leg ceil overshoot.
    function test_twoLegCeil_overshoots_concrete() public {
        uint256 scaledBalanceOfUser          = 147;
        uint256 index                        = 2.530773485048679075952786560e27; // ~2.5307 * RAY
        uint256 actualCollateralToLiquidate  = 367;
        uint256 liquidationProtocolFeeAmount = 4;

        uint256 balanceOfUser = _wadRayMathWrapper.rayMulFloor(scaledBalanceOfUser, index);

        // The budget respects the user's displayed balance
        assertLe(actualCollateralToLiquidate + liquidationProtocolFeeAmount, balanceOfUser);

        // The combined burn would be safe
        assertLe(_wadRayMathWrapper.rayDivCeil(actualCollateralToLiquidate + liquidationProtocolFeeAmount, index), scaledBalanceOfUser);

        // But the two SEPARATE ceil legs overshoot the scaled balance.
        uint256 scaledA = _wadRayMathWrapper.rayDivCeil(actualCollateralToLiquidate, index);
        uint256 scaledB = _wadRayMathWrapper.rayDivCeil(liquidationProtocolFeeAmount, index);
        assertGt(scaledA + scaledB, scaledBalanceOfUser);

        assertEq(scaledA, 146);
        assertEq(scaledB, 2);
        assertEq(scaledBalanceOfUser, 147);
    }

    function testFuzz_twoLegCeil_overshootIsSplitArtifact(
        uint256 scaledBalanceOfUser,
        uint256 index,
        uint256 actualCollateralToLiquidate
    ) public {
        scaledBalanceOfUser = bound(scaledBalanceOfUser, 2, 1e30);
        index               = bound(index, RAY + 1, 1e6 * RAY); // must exceed RAY for ceil to diverge

        uint256 balanceOfUser = _wadRayMathWrapper.rayMulFloor(scaledBalanceOfUser, index);

        vm.assume(balanceOfUser >= 2);

        actualCollateralToLiquidate = bound(actualCollateralToLiquidate, 1, balanceOfUser - 1);

        uint256 liquidationProtocolFeeAmount = balanceOfUser - actualCollateralToLiquidate; // whole budget consumed (full-collateral liquidation shape)

        uint256 scaledA  = _wadRayMathWrapper.rayDivCeil(actualCollateralToLiquidate, index);
        uint256 scaledB  = _wadRayMathWrapper.rayDivCeil(liquidationProtocolFeeAmount, index);
        uint256 combined = _wadRayMathWrapper.rayDivCeil(actualCollateralToLiquidate + liquidationProtocolFeeAmount, index);

        // The single combined conversion is always within the scaled balance.
        assertLe(combined, scaledBalanceOfUser);

        // The split legs bracket the combined conversion exactly: never less than it and at most 1 scaled unit more.
        assertGe(scaledA + scaledB, combined);
        assertLe(scaledA + scaledB, combined + 1);
    }

}
