// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {WadRayMathWrapper} from "test/fuzz/wrappers/WadRayMathWrapper.sol";

contract WadRayMathTests is Test {
    uint256 constant RAY = 1e27;
    uint256 constant HALF_RAY = 0.5e27;

    // Keep the oracle arithmetic below uint256 overflow while covering large token amounts and nonidentity indexes.
    uint256 constant TOKEN_MAX = 1e40;
    uint256 constant INDEX_MAX = 1e6 * RAY;

    WadRayMathWrapper wrapper;

    function setUp() public {
        wrapper = new WadRayMathWrapper();
    }

    function test_rayMul_zeroAndIdentityBoundaries() public {
        assertEq(wrapper.rayMul(0, 0), 0);
        assertEq(wrapper.rayMul(0, RAY), 0);
        assertEq(wrapper.rayMul(123, 0), 0);
        assertEq(wrapper.rayMul(123, RAY), 123);
        assertEq(wrapper.rayMul(RAY, 3 * RAY), 3 * RAY);
    }

    function test_rayMul_halfUpRoundingBoundaries() public {
        uint256 floorExample = wrapper.rayMul(1, RAY + 1);
        uint256 ceilExample = wrapper.rayMul(1, RAY + HALF_RAY);

        assertEq(_floorRayMul(1, RAY + 1), 1);
        assertEq(_ceilRayMul(1, RAY + 1), 2);
        assertEq(floorExample, 1);

        assertEq(_floorRayMul(1, RAY + HALF_RAY), 1);
        assertEq(_ceilRayMul(1, RAY + HALF_RAY), 2);
        assertEq(ceilExample, 2);
    }

    function test_rayMul_overflowBoundary() public {
        uint256 b = 2 * RAY;
        uint256 last = 57896044618658097711785492504343953926634992332820;
        uint256 next = last + 1;

        assertEq(last, (type(uint256).max - HALF_RAY) / b);
        assertEq(wrapper.rayMul(last, b), 115792089237316195423570985008687907853269984665640);

        vm.expectRevert();
        wrapper.rayMul(next, b);
    }

    function test_rayDiv_zeroAndIdentityBoundaries() public {
        assertEq(wrapper.rayDiv(0, 1), 0);
        assertEq(wrapper.rayDiv(1, 1), RAY);
        assertEq(wrapper.rayDiv(0, RAY), 0);
        assertEq(wrapper.rayDiv(123, RAY), 123);
        assertEq(wrapper.rayDiv(3 * RAY, RAY), 3 * RAY);
    }

    function test_rayDiv_halfUpRoundingBoundaries() public {
        uint256 roundDownExample = wrapper.rayDiv(1, 3);
        uint256 roundUpExample = wrapper.rayDiv(2, 3);

        assertEq(_floorRayDiv(1, 3), 333333333333333333333333333);
        assertEq(_ceilRayDiv(1, 3), 333333333333333333333333334);
        assertEq(roundDownExample, 333333333333333333333333333);

        assertEq(_floorRayDiv(2, 3), 666666666666666666666666666);
        assertEq(_ceilRayDiv(2, 3), 666666666666666666666666667);
        assertEq(roundUpExample, 666666666666666666666666667);
    }

    function test_rayDiv_zeroDenominatorReverts() public {
        vm.expectRevert();
        wrapper.rayDiv(1, 0);
    }

    function test_rayDiv_overflowBoundary() public {
        uint256 b = 2 * RAY;
        uint256 last = 115792089237316195423570985008687907853269984665639;
        uint256 next = last + 1;

        assertEq(last, (type(uint256).max - (b / 2)) / RAY);
        assertEq(wrapper.rayDiv(last, b), 57896044618658097711785492504343953926634992332820);

        vm.expectRevert();
        wrapper.rayDiv(next, b);
    }

    function testFuzz_rayMul_matchesCurrentHalfUpOracle(uint256 a, uint256 b) public {
        a = bound(a, 0, TOKEN_MAX);
        b = bound(b, 0, INDEX_MAX);

        assertEq(wrapper.rayMul(a, b), _halfUpRayMul(a, b));
    }

    function testFuzz_rayDiv_matchesCurrentHalfUpOracle(uint256 a, uint256 b) public {
        a = bound(a, 0, TOKEN_MAX);
        b = bound(b, 1, INDEX_MAX);

        assertEq(wrapper.rayDiv(a, b), _halfUpRayDiv(a, b));
    }

    function _halfUpRayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + HALF_RAY) / RAY;
    }

    function _floorRayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / RAY;
    }

    function _ceilRayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return ((a * b) - 1) / RAY + 1;
    }

    function _halfUpRayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + (b / 2)) / b;
    }

    function _floorRayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * RAY / b;
    }

    function _ceilRayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return ((a * RAY) - 1) / b + 1;
    }
}
