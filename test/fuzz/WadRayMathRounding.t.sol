// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { WadRayMathWrapper } from "sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

// Property tests for the four protocol-favoring ray helpers introduced by the SC-1569 PR:
//   rayMulFloor / rayMulCeil / rayDivFloor / rayDivCeil
//
// The oracle here is deliberately INDEPENDENT of the implementation: the exact
// remainder is computed with `mulmod` (a distinct full-precision EVM opcode) rather
// than the implementation's `mod(mul(a,b), RAY)`, so a shared arithmetic mistake in
// the assembly cannot pass on both sides. Every direction guarantee the design report
// relies on is asserted here as an exact identity, not an approximate bound.
contract WadRayMathRoundingTests is Test {

    uint256 constant RAY = 1e27;

    WadRayMathWrapper w;

    // Bound so a*b and a*RAY cannot overflow uint256 (~1.15e77): MAX_AMOUNT * MAX_INDEX
    // = 1e40 * 1e33 = 1e73. MAX_AMOUNT is ~1e22 tokens at 18dp (far above any TVL) and
    // MAX_INDEX is a 1e6x index (far above any real liquidity/borrow index).
    uint256 constant MAX_AMOUNT = 1e40;
    uint256 constant MAX_INDEX  = 1e6 * RAY;

    function setUp() public {
        w = new WadRayMathWrapper();
    }

    /**********************************************************************************************/
    /*** rayMul floor / ceil                                                                    ***/
    /**********************************************************************************************/

    function testFuzz_rayMul_floorCeil_exact(uint256 a, uint256 b) public {
        a = bound(a, 0, MAX_AMOUNT);
        b = bound(b, 0, MAX_INDEX);

        uint256 floorVal = w.rayMulFloor(a, b);
        uint256 ceilVal  = w.rayMulCeil(a, b);

        uint256 rem = mulmod(a, b, RAY);           // independent full-precision remainder
        uint256 expectedFloor = (a * b) / RAY;     // safe: bounds prevent overflow

        // Floor is exactly the truncated quotient.
        assertEq(floorVal, expectedFloor, "rayMulFloor != floor(a*b/RAY)");

        // Ceil is floor plus exactly one iff there is a non-zero remainder.
        assertEq(ceilVal, expectedFloor + (rem == 0 ? 0 : 1), "rayMulCeil wrong");

        // Ordering + at-most-one-apart.
        assertLe(floorVal, ceilVal);
        assertLe(ceilVal - floorVal, 1);

        // Legacy half-up result must sit within [floor, ceil].
        uint256 halfUp = w.rayMul(a, b);
        assertGe(halfUp, floorVal);
        assertLe(halfUp, ceilVal);
    }

    function testFuzz_rayMul_ceil_exactDivisionNotOverRounded(uint256 x) public {
        // Multiplying by RAY (identity) must never round up.
        x = bound(x, 0, MAX_AMOUNT);
        assertEq(w.rayMulCeil(x, RAY), x, "rayMulCeil(x, RAY) != x");
        assertEq(w.rayMulFloor(x, RAY), x, "rayMulFloor(x, RAY) != x");
    }

    function testFuzz_rayMul_zero(uint256 b) public {
        b = bound(b, 0, MAX_INDEX);
        assertEq(w.rayMulFloor(0, b), 0);
        assertEq(w.rayMulCeil(0, b), 0);
    }

    /**********************************************************************************************/
    /*** rayDiv floor / ceil                                                                    ***/
    /**********************************************************************************************/

    function testFuzz_rayDiv_floorCeil_exact(uint256 a, uint256 b) public {
        a = bound(a, 0, MAX_AMOUNT);
        b = bound(b, 1, MAX_INDEX);

        uint256 floorVal = w.rayDivFloor(a, b);
        uint256 ceilVal  = w.rayDivCeil(a, b);

        uint256 rem = mulmod(a, RAY, b);           // independent remainder of a*RAY mod b
        uint256 expectedFloor = (a * RAY) / b;     // safe under bounds

        assertEq(floorVal, expectedFloor, "rayDivFloor != floor(a*RAY/b)");
        assertEq(ceilVal, expectedFloor + (rem == 0 ? 0 : 1), "rayDivCeil wrong");

        assertLe(floorVal, ceilVal);
        assertLe(ceilVal - floorVal, 1);

        uint256 halfUp = w.rayDiv(a, b);
        assertGe(halfUp, floorVal);
        assertLe(halfUp, ceilVal);
    }

    function testFuzz_rayDiv_ceil_exactDivisionNotOverRounded(uint256 x) public {
        // Dividing by RAY (identity) must never round up.
        x = bound(x, 0, MAX_AMOUNT);
        assertEq(w.rayDivCeil(x, RAY), x, "rayDivCeil(x, RAY) != x");
        assertEq(w.rayDivFloor(x, RAY), x, "rayDivFloor(x, RAY) != x");
    }

    function testFuzz_rayDiv_ceil_zeroNumerator(uint256 b) public {
        b = bound(b, 1, MAX_INDEX);
        assertEq(w.rayDivCeil(0, b), 0);
        assertEq(w.rayDivFloor(0, b), 0);
    }

    function test_rayDiv_byZero_reverts() public {
        vm.expectRevert();
        w.rayDivFloor(1, 0);
        vm.expectRevert();
        w.rayDivCeil(1, 0);
    }

    /**********************************************************************************************/
    /*** Round-trip direction guarantees (the core protocol-favoring properties)                ***/
    /**********************************************************************************************/

    // A scaled balance converted to underlying with FLOOR then back to scaled with CEIL
    // must never exceed the original scaled amount. This is the exact identity the PR
    // relies on when it DROPPED the explicit `amountScaled > scaledBalance` cap in
    // _burnScaled: an aToken burn of a floor-derived balance must not over-run the balance.
    function testFuzz_scaledRoundTrip_floorThenCeil_neverExceeds(uint256 scaled, uint256 index)
        public
    {
        scaled = bound(scaled, 0, MAX_AMOUNT);
        index  = bound(index, RAY, MAX_INDEX);          // index >= RAY always holds in Aave

        uint256 underlying = w.rayMulFloor(scaled, index);   // what balanceOf shows
        uint256 backToScaled = w.rayDivCeil(underlying, index); // what burn(balanceOf) consumes

        assertLe(backToScaled, scaled, "ceil(floor(s*i)/i) exceeded s -> burn would over-run");
    }

    // Debt: a scaled debt converted to underlying with CEIL then back with FLOOR (repay-max
    // then burn-floor) must never exceed the original — i.e. a full repay burns at most the
    // real scaled debt, never more, and (for index >= RAY) burns EXACTLY it.
    function testFuzz_debtRoundTrip_ceilThenFloor_neverExceeds(uint256 scaled, uint256 index)
        public
    {
        scaled = bound(scaled, 0, MAX_AMOUNT);
        index  = bound(index, RAY, MAX_INDEX);

        uint256 underlying   = w.rayMulCeil(scaled, index);   // balanceOf (debt) rounds up
        uint256 backToScaled = w.rayDivFloor(underlying, index); // burn rounds down

        assertLe(backToScaled, scaled, "floor(ceil(s*i)/i) exceeded s");
        // For index >= RAY the round-trip is exact: a full repay clears the whole scaled debt.
        assertEq(backToScaled, scaled, "full repay left scaled dust (index >= RAY should be exact)");
    }

    /**********************************************************************************************/
    /*** Overflow guards                                                                        ***/
    /**********************************************************************************************/

    function test_rayMul_overflowReverts() public {
        uint256 a = type(uint256).max;
        vm.expectRevert();
        w.rayMulFloor(a, 2);
        vm.expectRevert();
        w.rayMulCeil(a, 2);
    }

    function test_rayDiv_overflowReverts() public {
        // a * RAY must not overflow; a just above type(uint256).max / RAY triggers the guard.
        uint256 a = type(uint256).max / RAY + 1;
        vm.expectRevert();
        w.rayDivFloor(a, 1);
        vm.expectRevert();
        w.rayDivCeil(a, 1);
    }
}
