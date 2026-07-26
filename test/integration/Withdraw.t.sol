// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { WadRayMathWrapper } from "../../lib/sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

import { SparkLendTestBase } from "../SparkLendTestBase.sol";

import { ReserveLogicWrapper } from "../fuzz/wrappers/ReserveLogicWrapper.sol";

contract WithdrawTestBase is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address owner     = makeAddr("owner");
    address recipient = makeAddr("recipient");

    ReserveLogicWrapper wrapper;

    function setUp() public override {
        super.setUp();

        ReserveLogicWrapper wrapperImpl = new ReserveLogicWrapper(poolAddressesProvider);
        wrapperImpl.initialize(poolAddressesProvider);

        vm.prank(admin);
        poolAddressesProvider.setPoolImpl(address(wrapperImpl));

        wrapper = ReserveLogicWrapper(address(pool));
    }

    function _setLiquidityIndex(uint256 newIndex) internal {
        wrapper.cumulateToLiquidityIndex(address(borrowAsset), RAY, newIndex - RAY);
    }

}

contract WithdrawRoundingTests is WithdrawTestBase {

    function testFuzz_maxWithdraw(uint256 liquidityIndex, uint256 balance) external {
        WadRayMathWrapper math = new WadRayMathWrapper();

        liquidityIndex = _bound(liquidityIndex, RAY, RAY * 3);
        balance        = _bound(balance,        100, 1e9 * 1e18);   // 1 billion

        _supply(owner, address(borrowAsset), balance);

        _setLiquidityIndex(liquidityIndex);

        uint256 expectedSenderBalance = math.rayMulFloor(balance, liquidityIndex);

        deal(address(borrowAsset), address(aBorrowAsset), expectedSenderBalance);

        assertEq(aBorrowAsset.balanceOf(owner),     expectedSenderBalance);
        assertEq(aBorrowAsset.balanceOf(recipient), 0);

        vm.prank(owner);
        pool.withdraw(address(borrowAsset), expectedSenderBalance, owner);

        assertEq(aBorrowAsset.balanceOf(owner), 0);
    }

}
