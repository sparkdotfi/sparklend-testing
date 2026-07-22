// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

// Fuzz coverage for AToken.transferFrom under the protocol-favoring rounding change.
//
// The new core OVERRIDES transferFrom with Aave v3.5-inspired allowance semantics
// (AToken.transferFrom + IncentivizedERC20._spendAllowance):
//   - the call is gated on `allowance >= amount` (nominal underlying units), BUT
//   - the allowance actually consumed is `actualAmountOut` — the sender's real indexed balance
//     decrease, floor(S*I) - floor((S - ceil(amount/I))*I) — which can EXCEED `amount` by a
//     rounding wei, clamped to the remaining allowance.
// So transferFrom(amount) is NOT vanilla ERC20: a spender's allowance can drain slightly faster
// than the nominal amounts transferred. These properties pin that seam at index > RAY:
//   - allowance consumed == min(senderLoss, allowanceBefore), and senderLoss >= amount;
//   - the scaled ledger moves exactly ceil(amount/index) and is conserved (no mint/burn);
//   - in underlying terms the recipient receives at least `amount` and at most
//     `amount + index/RAY` — the ceil'd scaled units are worth slightly more than `amount`, and
//     that surplus comes out of the sender, never the protocol.
contract ATokenTransferFromTests is SparkLendTestBase {

    uint256 constant RAY = 1e27;

    address owner_    = makeAddr("owner");
    address spender   = makeAddr("spender");
    address recipient = makeAddr("recipient");
    address borrower  = makeAddr("borrower");
    address lp        = makeAddr("lp");

    function setUp() public override {
        super.setUp();

        _initCollateral(address(collateralAsset), 50_00, 50_00, 101_00);
        _initCollateral(address(borrowAsset),     50_00, 50_00, 101_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);
        poolConfigurator.setReserveBorrowing(address(borrowAsset),     true);
        vm.stopPrank();

        // Seed collateralAsset cash (kept in the reserve) and open a borrow against it so its
        // liquidity index accrues above RAY over the fuzzed warp — floor/ceil rounding only
        // diverges there.
        _supply(lp, address(collateralAsset), 5_000_000 ether);
        _supplyAndUseAsCollateral(borrower, address(borrowAsset), 10_000_000 ether);
        vm.prank(borrower);
        pool.borrow(address(collateralAsset), 200_000 ether, 2, 0, borrower);
    }

    function _rayDivCeil(uint256 a, uint256 index) internal pure returns (uint256) {
        return (a * RAY + index - 1) / index;
    }

    function testFuzz_transferFrom_allowanceAndScaledLedgersAgree(
        uint256 supplyAmount,
        uint256 transferAmount,
        uint256 allowanceAmount,
        uint256 warpTime
    ) public {
        supplyAmount = bound(supplyAmount, 1 ether, 1_000_000 ether);
        warpTime     = bound(warpTime, 1 days, 3650 days);

        _supply(owner_, address(collateralAsset), supplyAmount);

        vm.warp(block.timestamp + warpTime);

        uint256 index = pool.getReserveNormalizedIncome(address(collateralAsset));
        assertGt(index, RAY, "precondition: index must exceed RAY");

        uint256 ownerBalance = aCollateralAsset.balanceOf(owner_);
        transferAmount  = bound(transferAmount, 1, ownerBalance);
        allowanceAmount = bound(allowanceAmount, transferAmount, type(uint128).max);

        vm.prank(owner_);
        aCollateralAsset.approve(spender, allowanceAmount);

        uint256 expectedScaledMoved   = _rayDivCeil(transferAmount, index);
        uint256 ownerScaledBefore     = aCollateralAsset.scaledBalanceOf(owner_);
        uint256 recipientScaledBefore = aCollateralAsset.scaledBalanceOf(recipient);
        uint256 recipientBalBefore    = aCollateralAsset.balanceOf(recipient);
        uint256 scaledSupplyBefore    = aCollateralAsset.scaledTotalSupply();

        vm.prank(spender);
        aCollateralAsset.transferFrom(owner_, recipient, transferAmount);

        // The scaled ledger moves exactly ceil(amount/index), conserved between the two parties.
        assertEq(
            ownerScaledBefore - aCollateralAsset.scaledBalanceOf(owner_),
            expectedScaledMoved,
            "sender scaled decrease != ceil(amount/index)"
        );
        assertEq(
            aCollateralAsset.scaledBalanceOf(recipient) - recipientScaledBefore,
            expectedScaledMoved,
            "recipient scaled increase != ceil(amount/index)"
        );
        assertEq(
            aCollateralAsset.scaledTotalSupply(),
            scaledSupplyBefore,
            "transfer must not mint or burn scaled supply"
        );

        // Underlying view: sender loses >= amount; recipient gains in [amount, amount + index/RAY].
        uint256 senderLoss    = ownerBalance - aCollateralAsset.balanceOf(owner_);
        uint256 recipientGain = aCollateralAsset.balanceOf(recipient) - recipientBalBefore;

        assertGe(senderLoss, transferAmount, "sender lost less underlying than amount");
        assertLe(
            senderLoss,
            transferAmount + index / RAY,
            "sender lost more than the one-scaled-unit ceil surplus"
        );
        assertGe(recipientGain, transferAmount, "recipient gained less underlying than amount");
        assertLe(
            recipientGain,
            transferAmount + index / RAY,
            "recipient gained more than the one-scaled-unit ceil surplus"
        );

        // v3.5-style allowance consumption: the sender's ACTUAL indexed balance decrease is
        // spent (clamped to the allowance), not the nominal amount — so the allowance can drain
        // slightly faster than the amounts transferred.
        uint256 expectedConsumed = senderLoss > allowanceAmount ? allowanceAmount : senderLoss;
        assertEq(
            aCollateralAsset.allowance(owner_, spender),
            allowanceAmount - expectedConsumed,
            "allowance not consumed by min(actual balance decrease, allowance)"
        );
    }

    // The nominal-amount gate still applies: an allowance of amount - 1 must revert even though
    // consumption is computed from the actual balance decrease.
    function testFuzz_transferFrom_revertsBelowNominalAllowance(
        uint256 supplyAmount,
        uint256 transferAmount,
        uint256 warpTime
    ) public {
        supplyAmount = bound(supplyAmount, 1 ether, 1_000_000 ether);
        warpTime     = bound(warpTime, 1 days, 3650 days);

        _supply(owner_, address(collateralAsset), supplyAmount);

        vm.warp(block.timestamp + warpTime);

        transferAmount = bound(transferAmount, 2, aCollateralAsset.balanceOf(owner_));

        vm.prank(owner_);
        aCollateralAsset.approve(spender, transferAmount - 1);

        vm.prank(spender);
        vm.expectRevert();  // ERC20InsufficientAllowance
        aCollateralAsset.transferFrom(owner_, recipient, transferAmount);
    }
}
