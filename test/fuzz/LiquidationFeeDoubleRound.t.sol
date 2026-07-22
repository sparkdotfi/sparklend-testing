// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { WadRayMathWrapper } from "sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

// Executable evidence for the "two-leg ceil overshoot" seam in LiquidationLogic.
//
// A liquidation carves a user's collateral into two amounts from ONE budget:
//   - actualCollateralToLiquidate  (burned via AToken.burn, ROUND_UP)
//   - liquidationProtocolFeeAmount  (transferred to treasury, ROUND_UP)
// Each leg is independently ceil-rounded to scaled units. Because
//   ceil(a/I) + ceil(b/I)  can exceed  ceil((a+b)/I)  by 1,
// the two scaled legs can sum to MORE than the user's scaled balance S, even when the underlying
// budget a+b <= balanceOf(user) = floor(S*I) never violates the single-round-trip invariant that
// makes the dropped _burnScaled cap safe.
//
// In the live contract the fee leg re-reads the post-burn scaled balance and clamps
// (LiquidationLogic protocol-fee clamp), so there is NO revert — but the treasury is silently
// short-changed by the overshoot, and the user's scaled balance can be driven to exactly 0 by a
// mechanism DISTINCT from the "amount == balanceOf" equality that the collateral-flag-clear checks.
// This is dust-scale (<= ~1 wei of the fee per liquidation) but matters more for low-decimal,
// high-value assets. These tests prove the arithmetic seam is real.
contract LiquidationFeeDoubleRoundTests is Test {

    uint256 constant RAY = 1e27;

    WadRayMathWrapper w;

    function setUp() public {
        w = new WadRayMathWrapper();
    }

    // Deterministic counterexample surfaced by the audit: S=147, I≈2.5307..e27, a=367, b=4.
    function test_twoLegCeil_overshoots_concrete() public {
        uint256 S = 147;
        uint256 I = 2530773485048679075952786560; // ~2.5307 * RAY
        uint256 a = 367; // actualCollateralToLiquidate (underlying)
        uint256 b = 4;   // liquidationProtocolFeeAmount (underlying)

        uint256 B = w.rayMulFloor(S, I); // balanceOf(user)

        // Budget respects the user's displayed balance (the "safe" precondition).
        assertLe(a + b, B, "precondition: a+b must fit within balanceOf");

        // The COMBINED burn would be safe: ceil((a+b)/I) <= S.
        assertLe(w.rayDivCeil(a + b, I), S, "combined single-leg burn is within scaled balance");

        // But the two SEPARATE ceil legs overshoot the scaled balance.
        uint256 scaledA = w.rayDivCeil(a, I);
        uint256 scaledB = w.rayDivCeil(b, I);
        assertGt(scaledA + scaledB, S, "two-leg ceil sum should exceed scaled balance S");

        // Concretely: 146 + 2 = 148 > 147.
        assertEq(scaledA, 146);
        assertEq(scaledB, 2);
        assertEq(S, 147);
    }

    // Property: whenever the two-leg ceil sum exceeds S, the combined single-leg conversion does
    // NOT — i.e. the overshoot is purely an artifact of splitting the budget into two ceil legs,
    // which is exactly what LiquidationLogic does (burn + fee). This is the seam the design's
    // "amount <= balanceOf => ceil <= scaled" safety argument does not cover.
    function testFuzz_twoLegCeil_overshootIsSplitArtifact(
        uint256 scaled,
        uint256 index,
        uint256 aSeed
    ) public {
        scaled = bound(scaled, 2, 1e30);
        index  = bound(index, RAY + 1, 1e6 * RAY); // must exceed RAY for ceil to diverge
        uint256 B = w.rayMulFloor(scaled, index);
        vm.assume(B >= 2);

        uint256 a = bound(aSeed, 1, B - 1);
        uint256 b = B - a; // whole budget consumed (full-collateral liquidation shape)

        uint256 scaledA = w.rayDivCeil(a, index);
        uint256 scaledB = w.rayDivCeil(b, index);

        // The single combined conversion is ALWAYS within the scaled balance (safety holds).
        assertLe(w.rayDivCeil(a + b, index), scaled, "combined conversion must stay within S");

        // If the split overshoots, it is by at most 1 scaled unit beyond the combined value.
        if (scaledA + scaledB > scaled) {
            assertLe(
                scaledA + scaledB - w.rayDivCeil(a + b, index),
                1,
                "two-leg overshoot exceeds the expected 1-unit split artifact"
            );
        }
    }
}
