// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { WadRayMathWrapper } from "../../lib/sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

contract WadRayMathRoundingTests is Test {

    uint256 constant RAY = 1e27;

    WadRayMathWrapper mathWrapper;

    // Bound so a*b and a*RAY cannot overflow uint256 (~1.15e77): MAX_AMOUNT * MAX_INDEX
    // = 1e40 * 1e33 = 1e73. MAX_AMOUNT is ~1e22 tokens at 18 decimals (far above any TVL) and
    // MAX_INDEX is a 1e6 x index (far above any real liquidity/borrow index).
    uint256 constant MAX_AMOUNT = 1e40;
    uint256 constant MAX_INDEX  = 50 * RAY;

    function setUp() public {
        mathWrapper = new WadRayMathWrapper();
    }

    /**********************************************************************************************/
    /*** rayMul floor / ceil                                                                    ***/
    /**********************************************************************************************/

    function testFuzz_rayMul_floorCeil_exact(uint256 a, uint256 b) external view {
        a = _bound(a, 0, MAX_AMOUNT);
        b = _bound(b, 0, MAX_INDEX);

        uint256 floorVal = mathWrapper.rayMulFloor(a, b);
        uint256 ceilVal  = mathWrapper.rayMulCeil(a, b);

        uint256 remainder     = mulmod(a, b, RAY);  // Independent full-precision remainder
        uint256 expectedFloor = (a * b) / RAY;

        assertEq(floorVal, expectedFloor);  // floor(a*b/RAY) = (a*b)/RAY

        // Ceil is floor plus exactly one if there is a non-zero remainder.
        assertEq(ceilVal, expectedFloor + (remainder == 0 ? 0 : 1));
    }

    function testFuzz_rayMul_ceil_exactDivisionNotOverRounded(uint256 x) external view {
        x = _bound(x, 0, MAX_AMOUNT);

        assertEq(mathWrapper.rayMulCeil(x, RAY),  x);
        assertEq(mathWrapper.rayMulFloor(x, RAY), x);
    }

    function test_rayMulFloor_exampleValues() external {
        uint256 a = RAY + 1;
        uint256 b = RAY + 1;

        assertEq(mathWrapper.rayMulFloor(a, b), a * b / RAY);
        assertEq(mathWrapper.rayMulFloor(0, b), 0);
        assertEq(mathWrapper.rayMulFloor(a, 0), 0);

        uint256 tooLargeA = type(uint256).max / b + 1;

        vm.expectRevert();
        mathWrapper.rayMulFloor(tooLargeA, b);
    }

    function test_rayMulCeil_exampleValues() external {
        uint256 a = RAY + 1;
        uint256 b = RAY + 1;

        assertEq(mathWrapper.rayMulCeil(a, b),     a * b / RAY + 1);
        assertEq(mathWrapper.rayMulCeil(RAY, RAY), RAY);
        assertEq(mathWrapper.rayMulCeil(0, b),     0);
        assertEq(mathWrapper.rayMulCeil(a, 0),     0);

        uint256 tooLargeA = type(uint256).max / b + 1;

        vm.expectRevert();
        mathWrapper.rayMulCeil(tooLargeA, b);
    }

    /**********************************************************************************************/
    /*** rayDiv floor / ceil                                                                    ***/
    /**********************************************************************************************/

    function testFuzz_rayDiv_floorCeil_exact(uint256 a, uint256 b) external view {
        a = _bound(a, 0, MAX_AMOUNT);
        b = _bound(b, 1, MAX_INDEX);

        uint256 floorVal = mathWrapper.rayDivFloor(a, b);
        uint256 ceilVal  = mathWrapper.rayDivCeil(a, b);

        uint256 remainder     = mulmod(a, RAY, b);  // independent remainder of a*RAY mod b
        uint256 expectedFloor = (a * RAY) / b;

        assertEq(floorVal, expectedFloor);                             // floor(a*RAY/b) = (a*RAY)/b
        assertEq(ceilVal,  expectedFloor + (remainder == 0 ? 0 : 1));  // rayDivCeil = floor + 1 if remainder > 0
    }

    function testFuzz_rayDiv_ceil_exactDivisionNotOverRounded(uint256 x) external view {
        x = _bound(x, 0, MAX_AMOUNT);

        assertEq(mathWrapper.rayDivCeil(x, RAY),  x);
        assertEq(mathWrapper.rayDivFloor(x, RAY), x);
    }

    function test_rayDiv_byZero_reverts() external {
        vm.expectRevert();
        mathWrapper.rayDivFloor(1, 0);

        vm.expectRevert();
        mathWrapper.rayDivCeil(1, 0);
    }

    function test_rayDivFloor_exampleValues() external {
        uint256 a = RAY + 1;
        uint256 b = 3;

        assertEq(mathWrapper.rayDivFloor(a, b), a * RAY / b);
        assertEq(mathWrapper.rayDivFloor(0, b), 0);

        uint256 tooLargeA = type(uint256).max / RAY + 1;

        vm.expectRevert();
        mathWrapper.rayDivFloor(tooLargeA, b);
    }

    function test_rayDivCeil_exampleValues() external {
        uint256 a = RAY + 1;
        uint256 b = 3;

        uint256 scaled   = a * RAY;
        uint256 expected = scaled / b + (scaled % b == 0 ? 0 : 1);

        assertEq(mathWrapper.rayDivCeil(a, b), expected);
        assertEq(mathWrapper.rayDivCeil(0, b), 0);

        uint256 tooLargeA = type(uint256).max / RAY + 1;

        vm.expectRevert();
        mathWrapper.rayDivCeil(tooLargeA, b);
    }

    /**********************************************************************************************/
    /*** Round-trip direction guarantees (the core protocol-favoring properties)                ***/
    /**********************************************************************************************/

    // aToken read-then-write path: balanceOf() returns rayMulFloor(scaled, index), and any
    // transfer/withdraw/liquidation converts the underlying amount back to scaled via rayDivCeil.
    // The round-trip must never exceed the original scaled balance, otherwise the burn could
    // destroy more scaled shares than the user actually holds (underflow / silent over-burn).
    function testFuzz_scaledRoundTrip_mulFloorThenDivCeil(uint256 scaled, uint256 index) external view {
        scaled = _bound(scaled, 0,   MAX_AMOUNT);
        index  = _bound(index,  RAY, MAX_INDEX);

        uint256 underlying   = mathWrapper.rayMulFloor(scaled, index);
        uint256 backToScaled = mathWrapper.rayDivCeil(underlying, index);

        assertEq(backToScaled, scaled);
    }

    function testFuzz_scaledRoundTrip_mulFloorThenDivFloor(uint256 scaled, uint256 index) external view {
        scaled = _bound(scaled, 0,   MAX_AMOUNT);
        index  = _bound(index,  RAY, MAX_INDEX);

        uint256 underlying   = mathWrapper.rayMulFloor(scaled, index);
        uint256 backToScaled = mathWrapper.rayDivFloor(underlying, index);

        assertTrue(scaled - backToScaled <= 1); // Can't round down more than 1
    }

    // debtToken repay-max path: balanceOf() returns rayMulCeil(scaled, index) (so users are
    // quoted at least their true obligation), and paying that exact amount burns scaled debt
    // via rayDivFloor. The round-trip must return exactly the original scaled amount so a
    // repay-max fully closes the position with no 1-wei dust debt remaining.
    function testFuzz_scaledRoundTrip_mulCeilThenDivFloor(uint256 scaled, uint256 index) external view {
        scaled = _bound(scaled, 0,   MAX_AMOUNT);
        index  = _bound(index,  RAY, MAX_INDEX);

        uint256 underlying   = mathWrapper.rayMulCeil(scaled, index);
        uint256 backToScaled = mathWrapper.rayDivFloor(underlying, index);

        assertEq(backToScaled, scaled);
    }

    function testFuzz_scaledRoundTrip_mulCeilThenDivCeil(uint256 scaled, uint256 index) external view {
        scaled = _bound(scaled, 0,   MAX_AMOUNT);
        index  = _bound(index,  RAY, MAX_INDEX);

        uint256 underlying   = mathWrapper.rayMulCeil(scaled, index);
        uint256 backToScaled = mathWrapper.rayDivCeil(underlying, index);

        assertTrue(backToScaled - scaled <= 1); // Can't round up more than 1
    }

    function testFuzz_underlyingRoundTrip_divFloorThenMulCeil(uint256 underlying, uint256 index) external view {
        underlying = _bound(underlying, 0,   MAX_AMOUNT);
        index      = _bound(index,      RAY, MAX_INDEX);

        uint256 scaled           = mathWrapper.rayDivFloor(underlying, index);
        uint256 backToUnderlying = mathWrapper.rayMulCeil(scaled, index);

        // Maximum error in scaledAmount scales with index, every multiple of RAY adds 1 to the error.
        assertTrue(underlying - backToUnderlying <= index / RAY);
        assertTrue(underlying - backToUnderlying <= 50);
    }

    function testFuzz_underlyingRoundTrip_divFloorThenMulFloor(uint256 underlying, uint256 index) external view {
        underlying = _bound(underlying, 0,   MAX_AMOUNT);
        index      = _bound(index,      RAY, MAX_INDEX);

        uint256 scaled           = mathWrapper.rayDivFloor(underlying, index);
        uint256 backToUnderlying = mathWrapper.rayMulFloor(scaled, index);

        // Maximum error in scaledAmount scales with index, every multiple of RAY adds 1 to the error.
        // In addition, two roundings in the same direction adds 1 to the error on the underlying side.
        assertTrue(underlying - backToUnderlying <= index / RAY + 1);
        assertTrue(underlying - backToUnderlying <= 50);
    }

    function testFuzz_underlyingRoundTrip_divCeilThenMulFloor(uint256 underlying, uint256 index) external view {
        underlying = _bound(underlying, 0,   MAX_AMOUNT);
        index      = _bound(index,      RAY, MAX_INDEX);

        uint256 scaled           = mathWrapper.rayDivCeil(underlying, index);
        uint256 backToUnderlying = mathWrapper.rayMulFloor(scaled, index);

        // Maximum error in scaledAmount scales with index, every multiple of RAY adds 1 to the error.
        assertTrue(backToUnderlying - underlying <= index / RAY);
        assertTrue(backToUnderlying - underlying <= 50);
    }

    function testFuzz_underlyingRoundTrip_divCeilThenMulCeil(uint256 underlying, uint256 index) external view {
        underlying = _bound(underlying, 0,   MAX_AMOUNT);
        index      = _bound(index,      RAY, MAX_INDEX);

        uint256 scaled           = mathWrapper.rayDivCeil(underlying, index);
        uint256 backToUnderlying = mathWrapper.rayMulCeil(scaled, index);

        // Maximum error in scaledAmount scales with index, every multiple of RAY adds 1 to the error.
        // In addition, two roundings in the same direction adds 1 to the error on the underlying side.
        assertTrue(backToUnderlying - underlying <= index / RAY + 1);
        assertTrue(backToUnderlying - underlying <= 50);
    }

}
