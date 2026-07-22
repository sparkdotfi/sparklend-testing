// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { IERC20 }    from "erc20-helpers/interfaces/IERC20.sol";
import { MockERC20 } from "erc20-helpers/MockERC20.sol";

import { IPool }  from "sparklend-v1-core/contracts/interfaces/IPool.sol";
import { AToken } from "sparklend-v1-core/contracts/protocol/tokenization/AToken.sol";

// Stateful fuzzing handler for SparkLend. Every action is bounded and wrapped so a revert never
// halts the campaign; the invariants live in Invariants.t.sol. Actions cover the full PR blast
// radius: supply / withdraw / borrow / repay / aToken transfer / liquidation / time warp.
contract LendingHandler is Test {

    IPool public immutable pool;

    address[] public actors;
    address[] public assets;

    // Per-action attempt/success counters, logged by invariant_callSummary. A success rate that
    // collapses to zero for an action means the campaign stopped covering that path.
    uint256 public callCount;
    mapping(string => uint256) public attempts;
    mapping(string => uint256) public successes;

    constructor(IPool pool_, address[] memory actors_, address[] memory assets_) {
        pool   = pool_;
        actors = actors_;
        assets = assets_;
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function assetsLength() external view returns (uint256) { return assets.length; }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _asset(uint256 seed) internal view returns (address) {
        return assets[seed % assets.length];
    }

    /**********************************************************************************************/
    /*** Actions                                                                                ***/
    /**********************************************************************************************/

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount, bool asCollateral) public {
        callCount++;
        attempts["supply"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        amount = bound(amount, 1, 1_000_000 ether);

        deal(asset, actor, IERC20(asset).balanceOf(actor) + amount);
        vm.startPrank(actor);
        IERC20(asset).approve(address(pool), amount);
        try pool.supply(asset, amount, actor, 0) {
            successes["supply"]++;
            if (asCollateral) {
                try pool.setUserUseReserveAsCollateral(asset, true) {} catch {}
            }
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 amount) public {
        callCount++;
        attempts["withdraw"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 bal   = AToken(_aToken(asset)).balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try pool.withdraw(asset, amount, actor) {
            successes["withdraw"]++;
        } catch {}
    }

    // Exercises the amount == type(uint256).max sentinel: the full-withdraw path is where
    // executeWithdraw's `amountToWithdraw == userBalance` equality (the flag-clearing seam the
    // rounding change touches) actually runs.
    function withdrawMax(uint256 actorSeed, uint256 assetSeed) public {
        callCount++;
        attempts["withdrawMax"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        if (AToken(_aToken(asset)).balanceOf(actor) == 0) return;

        vm.prank(actor);
        try pool.withdraw(asset, type(uint256).max, actor) {
            successes["withdrawMax"]++;
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) public {
        callCount++;
        attempts["borrow"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        amount = bound(amount, 1, 100_000 ether);

        vm.prank(actor);
        try pool.borrow(asset, amount, 2, 0, actor) {
            successes["borrow"]++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount) public {
        callCount++;
        attempts["repay"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 debt  = IERC20(_variableDebt(asset)).balanceOf(actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);

        deal(asset, actor, IERC20(asset).balanceOf(actor) + amount);
        vm.startPrank(actor);
        IERC20(asset).approve(address(pool), amount);
        try pool.repay(asset, amount, 2, actor) {
            successes["repay"]++;
        } catch {}
        vm.stopPrank();
    }

    // Exercises the amount == type(uint256).max sentinel (full repay of a ceil-rounded debt).
    function repayMax(uint256 actorSeed, uint256 assetSeed) public {
        callCount++;
        attempts["repayMax"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 debt  = IERC20(_variableDebt(asset)).balanceOf(actor);
        if (debt == 0) return;

        // Fund generously: debt accrues between balanceOf and the repay's updateState.
        deal(asset, actor, IERC20(asset).balanceOf(actor) + debt + 1 ether);
        vm.startPrank(actor);
        IERC20(asset).approve(address(pool), type(uint256).max);
        try pool.repay(asset, type(uint256).max, 2, actor) {
            successes["repayMax"]++;
        } catch {}
        IERC20(asset).approve(address(pool), 0);
        vm.stopPrank();
    }

    function transferAToken(uint256 fromSeed, uint256 toSeed, uint256 assetSeed, uint256 amount)
        public
    {
        callCount++;
        attempts["transferAToken"]++;
        address from  = _actor(fromSeed);
        address to    = _actor(toSeed);
        address asset = _asset(assetSeed);
        AToken aToken = AToken(_aToken(asset));
        uint256 bal   = aToken.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        try aToken.transfer(to, amount) {
            successes["transferAToken"]++;
        } catch {}
    }

    function setCollateral(uint256 actorSeed, uint256 assetSeed, bool enabled) public {
        callCount++;
        attempts["setCollateral"]++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);

        vm.prank(actor);
        try pool.setUserUseReserveAsCollateral(asset, enabled) {
            successes["setCollateral"]++;
        } catch {}
    }

    function mintToTreasury(uint256 assetSeed) public {
        callCount++;
        attempts["mintToTreasury"]++;
        address[] memory list = new address[](1);
        list[0] = _asset(assetSeed);

        try pool.mintToTreasury(list) {
            successes["mintToTreasury"]++;
        } catch {}
    }

    function liquidate(
        uint256 liqSeed,
        uint256 userSeed,
        uint256 collSeed,
        uint256 debtSeed,
        uint256 amount,
        bool    receiveAToken
    ) public {
        callCount++;
        attempts["liquidate"]++;
        address liquidator = _actor(liqSeed);
        address user       = _actor(userSeed);
        address collateral = _asset(collSeed);
        address debtAsset  = _asset(debtSeed);
        if (collateral == debtAsset) return;
        if (liquidator == user) return;

        uint256 debt = IERC20(_variableDebt(debtAsset)).balanceOf(user);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);

        deal(debtAsset, liquidator, IERC20(debtAsset).balanceOf(liquidator) + amount);
        vm.startPrank(liquidator);
        IERC20(debtAsset).approve(address(pool), amount);
        // receiveAToken=true covers the aToken-transfer path (no burn); the liquidator is an
        // actor, so the holder set used by the conservation invariants stays closed.
        try pool.liquidationCall(collateral, debtAsset, user, amount, receiveAToken) {
            successes["liquidate"]++;
        } catch {}
        vm.stopPrank();
    }

    function warp(uint256 timeSeed) public {
        callCount++;
        attempts["warp"]++;
        uint256 jump = bound(timeSeed, 1 hours, 180 days);
        vm.warp(block.timestamp + jump);
        successes["warp"]++;
    }

    /**********************************************************************************************/
    /*** Views                                                                                  ***/
    /**********************************************************************************************/

    function _aToken(address asset) internal view returns (address) {
        return pool.getReserveData(asset).aTokenAddress;
    }

    function _variableDebt(address asset) internal view returns (address) {
        return pool.getReserveData(asset).variableDebtTokenAddress;
    }

    function _stableDebt(address asset) internal view returns (address) {
        return pool.getReserveData(asset).stableDebtTokenAddress;
    }

    function aTokenOf(address asset) external view returns (address) { return _aToken(asset); }
    function variableDebtOf(address asset) external view returns (address) { return _variableDebt(asset); }
    function stableDebtOf(address asset) external view returns (address) { return _stableDebt(asset); }
}
