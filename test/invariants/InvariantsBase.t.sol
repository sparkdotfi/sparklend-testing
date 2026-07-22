// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { SparkLendTestBase } from "test/SparkLendTestBase.sol";

import { LendingHandler } from "test/invariants/handlers/LendingHandler.sol";

// Stateful invariant setup: multi-actor, multi-reserve, both assets collateral + borrowable, with
// seeded liquidity and an active borrow so the liquidity/borrow indices actually drift above RAY
// during the campaign — floor/ceil rounding never diverges at index == RAY.
contract InvariantsBase is SparkLendTestBase {

    LendingHandler internal handler;

    address[] internal actors;
    address[] internal assetList;

    address internal bootstrap = makeAddr("bootstrap");

    function setUp() public virtual override {
        super.setUp();

        // Both reserves usable as collateral and borrowable.
        _initCollateral(address(collateralAsset), 70_00, 75_00, 105_00);
        _initCollateral(address(borrowAsset),     70_00, 75_00, 105_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(address(collateralAsset), true);
        poolConfigurator.setReserveBorrowing(address(borrowAsset),     true);
        vm.stopPrank();

        assetList.push(address(collateralAsset));
        assetList.push(address(borrowAsset));

        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }

        // Seed deep liquidity and open a real borrow so indices move over time.
        _supplyAndUseAsCollateral(bootstrap, address(collateralAsset), 5_000_000 ether);
        _supplyAndUseAsCollateral(bootstrap, address(borrowAsset),     5_000_000 ether);
        vm.prank(bootstrap);
        pool.borrow(address(collateralAsset), 500_000 ether, 2, 0, bootstrap);
        vm.prank(bootstrap);
        pool.borrow(address(borrowAsset), 500_000 ether, 2, 0, bootstrap);

        // Give every actor starting collateral so borrows can succeed during the campaign.
        for (uint256 i; i < actors.length; ++i) {
            _supplyAndUseAsCollateral(actors[i], address(collateralAsset), 100_000 ether);
        }

        handler = new LendingHandler(pool, actors, assetList);

        // Fuzz only the action functions. This keeps the campaign off the handler's view
        // functions and auto-generated array getters (which revert on out-of-bounds indices and
        // would trip fail_on_revert). Every action is internally try/catch-wrapped, so any revert
        // that reaches the runner is a handler bug by construction.
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0]  = handler.supply.selector;
        selectors[1]  = handler.withdraw.selector;
        selectors[2]  = handler.withdrawMax.selector;
        selectors[3]  = handler.borrow.selector;
        selectors[4]  = handler.repay.selector;
        selectors[5]  = handler.repayMax.selector;
        selectors[6]  = handler.transferAToken.selector;
        selectors[7]  = handler.setCollateral.selector;
        selectors[8]  = handler.mintToTreasury.selector;
        selectors[9]  = handler.liquidate.selector;
        selectors[10] = handler.warp.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }
}
