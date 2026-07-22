// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

import { ReserveLogicWrapper } from "test/fuzz/wrappers/ReserveLogicWrapper.sol";

import { WadRayMathWrapper } from "sparklend-v1-core/contracts/mocks/tests/WadRayMathWrapper.sol";

contract TransferFromTestBase is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address owner     = makeAddr("owner");
    address spender   = makeAddr("spender");
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

contract TransferFromRoundingTests is TransferFromTestBase {

    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    function test_transferFrom_revertsWhenAllowanceIsInsufficientBoundary() public {
        _supply(owner, address(borrowAsset), 100);

        _setLiquidityIndex(1.5e27);  // 1.5

        vm.prank(owner);
        aBorrowAsset.approve(spender, 1);  // less than the requested amount

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, spender, 1, 2));
        aBorrowAsset.transferFrom(owner, recipient, 2);

        vm.prank(spender);
        aBorrowAsset.transferFrom(owner, recipient, 1);
    }

    function test_transferFrom_allowanceChargedForActualBalanceDecrease_notRequestedAmount() public {
        _supply(owner, address(borrowAsset), 100);

        _setLiquidityIndex(1.6e27);

        vm.prank(owner);
        aBorrowAsset.approve(spender, 10);

        assertEq(aBorrowAsset.scaledBalanceOf(owner),     100);
        assertEq(aBorrowAsset.scaledBalanceOf(recipient), 0);

        assertEq(aBorrowAsset.balanceOf(owner),          160);  // floor(100 * 1.6)
        assertEq(aBorrowAsset.balanceOf(recipient),      0);
        assertEq(aBorrowAsset.allowance(owner, spender), 10);

        vm.prank(spender);
        aBorrowAsset.transferFrom(owner, recipient, 2);

        assertEq(aBorrowAsset.scaledBalanceOf(owner),     98);  // ceil(2 / 1.6) = 2
        assertEq(aBorrowAsset.scaledBalanceOf(recipient), 2);

        assertEq(aBorrowAsset.balanceOf(owner),          156);  // floor(98 * 1.6) = 156
        assertEq(aBorrowAsset.balanceOf(recipient),      3);    // floor(2 * 1.6)  = 3

        // Allowance spent is the difference between the initial sender balance and the new balance after the transfer
        // floor(100 * 1.6) - floor((100 - ceil(2 / 1.6)) * 1.6) = 4
        // 160 - floor((100 - 2) * 1.6) = 4
        // 160 - 156 = 4
        assertEq(aBorrowAsset.allowance(owner, spender), 6);
    }

    function test_transferFrom_allowanceFullyConsumedWhenExceedingResultingAmount() public {
        _supply(owner, address(borrowAsset), 100);

        _setLiquidityIndex(1.5e27);  // 1.5

        vm.prank(owner);
        aBorrowAsset.approve(spender, 2);

        assertEq(aBorrowAsset.scaledBalanceOf(owner),     100);
        assertEq(aBorrowAsset.scaledBalanceOf(recipient), 0);

        assertEq(aBorrowAsset.balanceOf(owner),          150);  // floor(100 * 1.5)
        assertEq(aBorrowAsset.balanceOf(recipient),      0);
        assertEq(aBorrowAsset.allowance(owner, spender), 2);

        vm.prank(spender);
        aBorrowAsset.transferFrom(owner, recipient, 2);

        assertEq(aBorrowAsset.scaledBalanceOf(owner),     98);  // ceil(2 / 1.5) = 2
        assertEq(aBorrowAsset.scaledBalanceOf(recipient), 2);

        assertEq(aBorrowAsset.balanceOf(owner),     147);  // floor(98 * 1.5) = 147
        assertEq(aBorrowAsset.balanceOf(recipient), 3);    // floor(2 * 1.6)  = 3

        // Allowance spent is the difference between the initial sender balance and the new balance after the transfer
        // floor(100 * 1.5) - floor(((100 - ceil(2 / 1.5)) * 1.5) = 3
        // 150 - floor(100 - 2) * 1.5) = 3
        // 150 - 147 = 3
        // 3 > 2, so the allowance is set to 0
        assertEq(aBorrowAsset.allowance(owner, spender), 0);
    }

    function testFuzz_transferFrom_allowanceChargedForActualBalanceDecrease_neverHigherThanTwo(
        uint256 liquidityIndex,
        uint256 startingBalance,
        uint256 transferAmount,
        uint256 startingAllowance
    )
        public
    {
        WadRayMathWrapper math = new WadRayMathWrapper();

        liquidityIndex    = _bound(liquidityIndex,    RAY,            RAY * 3);
        startingBalance   = _bound(startingBalance,   100,            1e9 * 1e18);   // 1 billion
        transferAmount    = _bound(transferAmount,    1,              math.rayMulFloor(startingBalance, liquidityIndex));
        startingAllowance = _bound(startingAllowance, transferAmount, type(uint256).max);

        _supply(owner, address(borrowAsset), startingBalance);

        _setLiquidityIndex(liquidityIndex);

        vm.prank(owner);
        aBorrowAsset.approve(spender, startingAllowance);

        assertEq(aBorrowAsset.scaledBalanceOf(owner),     startingBalance);
        assertEq(aBorrowAsset.scaledBalanceOf(recipient), 0);

        uint256 expectedSenderStartingBalance = math.rayMulFloor(startingBalance, liquidityIndex);

        assertEq(aBorrowAsset.balanceOf(owner),          expectedSenderStartingBalance);
        assertEq(aBorrowAsset.balanceOf(recipient),      0);
        assertEq(aBorrowAsset.allowance(owner, spender), startingAllowance);

        vm.prank(spender);
        aBorrowAsset.transferFrom(owner, recipient, transferAmount);

        uint256 scaledTransferAmount = math.rayDivCeil(transferAmount, liquidityIndex);

        assertEq(aBorrowAsset.scaledBalanceOf(owner),     startingBalance - scaledTransferAmount);
        assertEq(aBorrowAsset.scaledBalanceOf(recipient), scaledTransferAmount);

        uint256 expectedSenderEndingBalance = math.rayMulFloor(startingBalance - scaledTransferAmount, liquidityIndex);

        assertEq(aBorrowAsset.balanceOf(owner),     expectedSenderEndingBalance);
        assertEq(aBorrowAsset.balanceOf(recipient), math.rayMulFloor(scaledTransferAmount, liquidityIndex));

        uint256 expectedAllowanceSpent = expectedSenderStartingBalance - expectedSenderEndingBalance;

        // Allowance spent can be higher than the transfer amount due to rounding, but it should be at most 3 units of the asset (At RAY * 3)
        assertGe(expectedAllowanceSpent,                  transferAmount);
        assertLe(expectedAllowanceSpent - transferAmount, 3);

        // If allowance spent is greater than the starting allowance, the allowance should be set to 0
        assertEq(
            aBorrowAsset.allowance(owner, spender),
            expectedAllowanceSpent > startingAllowance ? 0 : startingAllowance - expectedAllowanceSpent
        );
    }

}
