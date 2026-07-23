// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { WadRayMathWrapper } from "sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

contract WadRayMathRoundingTests is Test {

    uint256 constant RAY = 1e27;

    WadRayMathWrapper mathWrapper;

    // Bound so a*b and a*RAY cannot overflow uint256 (~1.15e77): MAX_AMOUNT * MAX_INDEX
    // = 1e40 * 1e33 = 1e73. MAX_AMOUNT is ~1e22 tokens at 18 decimals (far above any TVL) and
    // MAX_INDEX is a 1e6 x index (far above any real liquidity/borrow index).
    uint256 constant MAX_AMOUNT = 1e40;
    uint256 constant MAX_INDEX  = 1e6 * RAY;

    function setUp() public {
        mathWrapper = new WadRayMathWrapper();
    }

    /**********************************************************************************************/
    /*** rayMul floor / ceil                                                                    ***/
    /**********************************************************************************************/

    function testFuzz_rayMul_floorCeil_exact(uint256 a, uint256 b) public {
        a = bound(a, 0, MAX_AMOUNT);
        b = bound(b, 0, MAX_INDEX);

        uint256 floorVal = mathWrapper.rayMulFloor(a, b);
        uint256 ceilVal  = mathWrapper.rayMulCeil(a, b);

        uint256 remainder     = mulmod(a, b, RAY);  // independent full-precision remainder
        uint256 expectedFloor = (a * b) / RAY;

        assertEq(floorVal, expectedFloor);  // floor(a*b/RAY) = (a*b)/RAY

        // Ceil is floor plus exactly one if there is a non-zero remainder.
        assertEq(ceilVal, expectedFloor + (remainder == 0 ? 0 : 1));
    }

    function testFuzz_rayMul_ceil_exactDivisionNotOverRounded(uint256 x) public {
        x = bound(x, 0, MAX_AMOUNT);

        assertEq(mathWrapper.rayMulCeil(x, RAY),  x);  // rayMulCeil(x, RAY) = x
        assertEq(mathWrapper.rayMulFloor(x, RAY), x);  // rayMulFloor(x, RAY) = x
    }

    function test_rayMulFloor_exampleValues() public {
        uint256 a = RAY + 1;
        uint256 b = RAY + 1;

        uint256 product = a * b;

        assertEq(mathWrapper.rayMulFloor(a, b), product / RAY);
        assertEq(mathWrapper.rayMulFloor(0, b), 0);
        assertEq(mathWrapper.rayMulFloor(a, 0), 0);

        uint256 tooLargeA = type(uint256).max / b + 1;

        vm.expectRevert();
        mathWrapper.rayMulFloor(tooLargeA, b);
    }

    function test_rayMulCeil_exampleValues() public {
        uint256 a = RAY + 1;
        uint256 b = RAY + 1;

        uint256 product  = a * b;
        uint256 expected = product / RAY + (product % RAY == 0 ? 0 : 1);

        assertEq(mathWrapper.rayMulCeil(a, b),     expected);
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

    function testFuzz_rayDiv_floorCeil_exact(uint256 a, uint256 b) public {
        a = bound(a, 0, MAX_AMOUNT);
        b = bound(b, 1, MAX_INDEX);

        uint256 floorVal = mathWrapper.rayDivFloor(a, b);
        uint256 ceilVal  = mathWrapper.rayDivCeil(a, b);

        uint256 remainder     = mulmod(a, RAY, b);  // independent remainder of a*RAY mod b
        uint256 expectedFloor = (a * RAY) / b;

        assertEq(floorVal, expectedFloor);                             // floor(a*RAY/b) = (a*RAY)/b
        assertEq(ceilVal,  expectedFloor + (remainder == 0 ? 0 : 1));  // rayDivCeil = floor + 1 if remainder > 0
    }

    function testFuzz_rayDiv_ceil_exactDivisionNotOverRounded(uint256 x) public {
        x = bound(x, 0, MAX_AMOUNT);

        assertEq(mathWrapper.rayDivCeil(x, RAY),  x);  // rayDivCeil(x, RAY) = x
        assertEq(mathWrapper.rayDivFloor(x, RAY), x);  // rayDivFloor(x, RAY) = x
    }

    function test_rayDiv_byZero_reverts() public {
        vm.expectRevert();
        mathWrapper.rayDivFloor(1, 0);

        vm.expectRevert();
        mathWrapper.rayDivCeil(1, 0);
    }

    function test_rayDivFloor_exampleValues() public {
        uint256 a = RAY + 1;
        uint256 b = 3;

        uint256 scaled = a * RAY;

        assertEq(mathWrapper.rayDivFloor(a, b), scaled / b);
        assertEq(mathWrapper.rayDivFloor(0, b), 0);

        uint256 tooLargeA = type(uint256).max / RAY + 1;

        vm.expectRevert();
        mathWrapper.rayDivFloor(tooLargeA, b);

        vm.expectRevert();
        mathWrapper.rayDivFloor(a, 0);
    }

    function test_rayDivCeil_exampleValues() public {
        uint256 a = RAY + 1;
        uint256 b = 3;

        uint256 scaled   = a * RAY;
        uint256 expected = scaled / b + (scaled % b == 0 ? 0 : 1);

        assertEq(mathWrapper.rayDivCeil(a, b),     expected);
        assertEq(mathWrapper.rayDivCeil(RAY, RAY), RAY);
        assertEq(mathWrapper.rayDivCeil(0, b),     0);

        uint256 tooLargeA = type(uint256).max / RAY + 1;

        vm.expectRevert();
        mathWrapper.rayDivCeil(tooLargeA, b);

        vm.expectRevert();
        mathWrapper.rayDivCeil(a, 0);
    }

    /**********************************************************************************************/
    /*** Round-trip direction guarantees (the core protocol-favoring properties)                ***/
    /**********************************************************************************************/

    // A scaled balance converted to underlying with FLOOR then back to scaled with CEIL
    // must never exceed the original scaled amount.
    function testFuzz_scaledRoundTrip_floorThenCeil_neverExceeds(uint256 scaled, uint256 index)
        public
    {
        scaled = bound(scaled, 0,   MAX_AMOUNT);
        index  = bound(index,  RAY, MAX_INDEX);

        uint256 underlying   = mathWrapper.rayMulFloor(scaled, index);
        uint256 backToScaled = mathWrapper.rayDivCeil(underlying, index);

        assertLe(backToScaled, scaled);
    }

    // A scaled debt converted to underlying with CEIL then back with FLOOR (repay-max
    // then burn-floor) must never exceed the original.
    function testFuzz_debtRoundTrip_ceilThenFloor_neverExceeds(uint256 scaled, uint256 index)
        public
    {
        scaled = bound(scaled, 0,   MAX_AMOUNT);
        index  = bound(index,  RAY, MAX_INDEX);

        uint256 underlying   = mathWrapper.rayMulCeil(scaled, index);
        uint256 backToScaled = mathWrapper.rayDivFloor(underlying, index);

        assertEq(backToScaled, scaled);
    }

    /**********************************************************************************************/
    /*** Overflow guards                                                                        ***/
    /**********************************************************************************************/

    function test_rayMul_overflowReverts() public {
        uint256 a = type(uint256).max;

        vm.expectRevert();
        mathWrapper.rayMulFloor(a, 2);

        vm.expectRevert();
        mathWrapper.rayMulCeil(a, 2);
    }

    function test_rayDiv_overflowReverts() public {
        // a * RAY must not overflow; a just above type(uint256).max / RAY triggers the guard.
        uint256 a = type(uint256).max / RAY + 1;

        vm.expectRevert();
        mathWrapper.rayDivFloor(a, 1);

        vm.expectRevert();
        mathWrapper.rayDivCeil(a, 1);
    }

}
