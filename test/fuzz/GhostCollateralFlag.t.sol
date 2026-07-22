// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

// Regression PoCs for the "ghost collateral flag" issue introduced by the SC-1569
// protocol-favoring rounding change.
//
// ROOT CAUSE: aToken balances are read with rayMulFloor (down) but a transfer/withdraw consumes
// scaled balance with rayDivCeil (up). The Pool decides whether a user emptied a reserve by
// comparing UNDERLYING amounts (`balanceFromBefore == amount` in finalizeTransfer,
// `amountToWithdraw == userBalance` in executeWithdraw). A ceil-consuming transfer/withdraw can
// zero the user's SCALED balance while the underlying-equality check reads false, leaving
// isUsingAsCollateral == true on a zero balance — a flag that then can't be cleared, because
// setUserUseReserveAsCollateral reverts on a zero balance (UNDERLYING_BALANCE_ZERO).
//
// IMPORTANT — these tests are GREEN by design: they assert the CURRENT (buggy) behavior so the
// suite passes and documents the open finding. The desired invariant is
// `isUsingAsCollateral => scaledBalance > 0` (also encoded in test/invariants/Invariants.t.sol as
// invariant_collateralFlagImpliesBalance). WHEN THE BUG IS FIXED, `test_ghostFlag_*` will start
// failing at the marked assertions — that failure is the signal the fix landed; invert the
// assertions at that point.
contract GhostCollateralFlagTests is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address victim   = makeAddr("victim");
    address borrower = makeAddr("borrower");
    address sink     = makeAddr("sink");

    function setUp() public override {
        super.setUp();

        // Both assets: collateral (50% LTV) and borrowable, so the collateral asset's liquidity
        // index can rise above 1.0 through real borrowing + interest accrual.
        _initCollateral(address(collateralAsset), 50_00, 50_00, 101_00);
        _initCollateral(address(borrowAsset),     50_00, 50_00, 101_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);
        poolConfigurator.setReserveBorrowing(address(borrowAsset),     true);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // Drives the collateralAsset liquidity index above 1.0 by having a borrower borrow it, then
    // warping ~10 years so interest accrues.
    function _growCollateralIndex() internal {
        _supplyAndUseAsCollateral(borrower, address(borrowAsset), 10_000_000 ether);
        vm.prank(borrower);
        pool.borrow(address(collateralAsset), 200_000 ether, 2, 0, borrower);

        vm.warp(block.timestamp + 3650 days);

        _supply(borrower, address(collateralAsset), 1 ether);  // poke reserve state
    }

    function _rayDivCeil(uint256 a, uint256 index) internal pure returns (uint256) {
        return (a * RAY + index - 1) / index;
    }

    function _isCollateral(address asset, address user) internal view returns (bool enabled) {
        ( , , , , , , , , enabled) = protocolDataProvider.getUserReserveData(asset, user);
    }

    // Finds an amount strictly below balanceOf whose ceil-scaled value equals the ENTIRE scaled
    // balance — i.e. a transfer that empties scaled balance while the underlying-equality
    // flag-clear (amount == balanceOf) reads false. Returns (amount, true) if the window exists.
    function _findGhostAmount(uint256 index, uint256 scaled, uint256 balanceOf)
        internal pure returns (uint256, bool)
    {
        for (uint256 k = 1; k <= 256 && k < balanceOf; ++k) {
            uint256 a = balanceOf - k;
            if (_rayDivCeil(a, index) == scaled) return (a, true);
        }
        return (0, false);
    }

    function _setupGhostTransfer() internal returns (uint256 ghostAmount) {
        _supplyAndUseAsCollateral(victim, address(collateralAsset), 1_000_000 ether);
        _growCollateralIndex();

        uint256 index     = pool.getReserveNormalizedIncome(address(collateralAsset));
        uint256 scaled    = aCollateralAsset.scaledBalanceOf(victim);
        uint256 balanceOf = aCollateralAsset.balanceOf(victim);

        assertGt(index, RAY, "precondition: index must exceed 1.0");
        assertTrue(_isCollateral(address(collateralAsset), victim), "precondition: flag set");

        bool found;
        (ghostAmount, found) = _findGhostAmount(index, scaled, balanceOf);
        assertTrue(found, "precondition: ghost window exists at this index");
        assertTrue(ghostAmount != balanceOf, "ghost amount must differ from balanceOf");
    }

    /**********************************************************************************************/
    /*** PoC: a transfer that ceil-empties the scaled balance leaves the flag stuck             ***/
    /**********************************************************************************************/

    function test_ghostFlag_transfer_leavesFlagOnZeroBalance() public {
        uint256 ghostAmount = _setupGhostTransfer();

        vm.prank(victim);
        aCollateralAsset.transfer(sink, ghostAmount);

        // Current (buggy) behavior: scaled balance is emptied, but the flag is still set.
        // WHEN FIXED: the second assertion below flips (flag should be false); invert it then.
        assertEq(aCollateralAsset.scaledBalanceOf(victim), 0, "scaled balance should be emptied");
        assertTrue(
            _isCollateral(address(collateralAsset), victim),
            "GHOST FLAG (F1): collateral flag stuck true on a zero balance"
        );
    }

    // The stuck flag cannot be cleared through the intended path: disabling collateral reverts on
    // a zero balance.
    function test_ghostFlag_isUnclearable() public {
        uint256 ghostAmount = _setupGhostTransfer();

        vm.prank(victim);
        aCollateralAsset.transfer(sink, ghostAmount);

        vm.prank(victim);
        vm.expectRevert(bytes("43"));  // Errors.UNDERLYING_BALANCE_ZERO
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);
    }

    // The only escape is to re-supply the asset (note: a 1-wei supply itself reverts once the index
    // is above 1.0, because the floored scaled mint rounds to zero — the user must supply at least
    // ~ceil(index/RAY) wei), then disable, then withdraw.
    function test_ghostFlag_escapeRequiresResupply() public {
        uint256 ghostAmount = _setupGhostTransfer();

        vm.prank(victim);
        aCollateralAsset.transfer(sink, ghostAmount);

        // A 1-wei re-supply reverts (floored scaled mint rounds to zero at index > 1.0).
        deal(address(collateralAsset), victim, 1);
        vm.startPrank(victim);
        collateralAsset.approve(address(pool), 1);
        vm.expectRevert(bytes("24"));  // Errors.INVALID_MINT_AMOUNT
        pool.supply(address(collateralAsset), 1, victim, 0);
        vm.stopPrank();

        // Supplying a non-dust amount succeeds; the flag can then finally be cleared.
        _supply(victim, address(collateralAsset), 1 ether);
        vm.prank(victim);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);

        assertTrue(!_isCollateral(address(collateralAsset), victim), "flag clears after re-supply");
    }
}
