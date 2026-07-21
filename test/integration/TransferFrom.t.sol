// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

import { ReserveLogicWrapper } from "test/fuzz/wrappers/ReserveLogicWrapper.sol";

contract TransferFromTestBase is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address owner     = makeAddr("owner");
    address spender   = makeAddr("spender");
    address recipient = makeAddr("recipient");

    ReserveLogicWrapper wrapper;

    function setUp() public override {
        super.setUp();

        _supply(owner, address(borrowAsset), 100);

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

    function test_transferFrom_allowanceChargedForActualBalanceDecrease_notRequestedAmount() public {
        _setLiquidityIndex(RAY * 8 / 5);  // 1.6

        vm.prank(owner);
        aBorrowAsset.approve(spender, 10);

        uint256 ownerBalanceBefore     = aBorrowAsset.balanceOf(owner);      // 160 (100 scaled * 1.6)
        uint256 recipientBalanceBefore = aBorrowAsset.balanceOf(recipient);  // 0

        assertEq(ownerBalanceBefore,     160);
        assertEq(recipientBalanceBefore, 0);

        vm.prank(spender);
        aBorrowAsset.transferFrom(owner, recipient, 2);

        assertEq(aBorrowAsset.balanceOf(owner),                              156);
        assertEq(aBorrowAsset.balanceOf(recipient) - recipientBalanceBefore, 3);
        assertEq(aBorrowAsset.allowance(owner, spender),                     6);
    }

    function test_transferFrom_fullAllowanceConsumed() public {
        _setLiquidityIndex(RAY * 3 / 2);  // 1.5

        vm.prank(owner);
        aBorrowAsset.approve(spender, 2);  // exactly the requested amount

        assertEq(aBorrowAsset.balanceOf(owner),     150);
        assertEq(aBorrowAsset.balanceOf(recipient), 0);

        vm.prank(spender);
        aBorrowAsset.transferFrom(owner, recipient, 2);

        // Doesn't revert even though the real decrease (3) exceeds the approved amount (2) -
        // the full allowance is instead consumed and capped there
        assertEq(aBorrowAsset.allowance(owner, spender), 0);

        assertEq(aBorrowAsset.balanceOf(owner),     147);  // 150 indexed balance - 3
        assertEq(aBorrowAsset.balanceOf(recipient), 3);
    }

    function test_transferFrom_revertsWhenAllowanceIsInsufficient() public {
        _setLiquidityIndex(RAY * 3 / 2);  // 1.5

        vm.prank(owner);
        aBorrowAsset.approve(spender, 1);  // less than the requested amount

        assertEq(aBorrowAsset.balanceOf(owner),     150);
        assertEq(aBorrowAsset.balanceOf(recipient), 0);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, spender, 1, 2));
        aBorrowAsset.transferFrom(owner, recipient, 2);
    }

}
