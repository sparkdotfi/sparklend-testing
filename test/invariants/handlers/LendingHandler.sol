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

    // Ghost accounting for round-trip / conservation invariants.
    mapping(address => uint256) public sumSupplied;    // asset => cumulative supplied
    mapping(address => uint256) public sumWithdrawn;   // asset => cumulative withdrawn
    mapping(address => uint256) public sumBorrowed;    // asset => cumulative borrowed
    mapping(address => uint256) public sumRepaid;      // asset => cumulative repaid

    // Every address that could hold an aToken/debt balance, for exact conservation sums.
    address[] public holders;
    mapping(address => bool) internal _isHolder;

    uint256 public callCount;

    constructor(IPool pool_, address[] memory actors_, address[] memory assets_) {
        pool   = pool_;
        actors = actors_;
        assets = assets_;
        for (uint256 i; i < actors_.length; ++i) _addHolder(actors_[i]);
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function assetsLength() external view returns (uint256) { return assets.length; }
    function holdersLength() external view returns (uint256) { return holders.length; }

    function _addHolder(address a) internal {
        if (!_isHolder[a]) { _isHolder[a] = true; holders.push(a); }
    }

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
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        amount = bound(amount, 1, 1_000_000 ether);

        deal(asset, actor, IERC20(asset).balanceOf(actor) + amount);
        vm.startPrank(actor);
        IERC20(asset).approve(address(pool), amount);
        try pool.supply(asset, amount, actor, 0) {
            sumSupplied[asset] += amount;
            if (asCollateral) {
                try pool.setUserUseReserveAsCollateral(asset, true) {} catch {}
            }
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 amount) public {
        callCount++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 bal   = AToken(_aToken(asset)).balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try pool.withdraw(asset, amount, actor) returns (uint256 withdrawn) {
            sumWithdrawn[asset] += withdrawn;
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) public {
        callCount++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        amount = bound(amount, 1, 100_000 ether);

        vm.prank(actor);
        try pool.borrow(asset, amount, 2, 0, actor) {
            sumBorrowed[asset] += amount;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount) public {
        callCount++;
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 debt  = IERC20(_variableDebt(asset)).balanceOf(actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);

        deal(asset, actor, IERC20(asset).balanceOf(actor) + amount);
        vm.startPrank(actor);
        IERC20(asset).approve(address(pool), amount);
        try pool.repay(asset, amount, 2, actor) returns (uint256 repaid) {
            sumRepaid[asset] += repaid;
        } catch {}
        vm.stopPrank();
    }

    function transferAToken(uint256 fromSeed, uint256 toSeed, uint256 assetSeed, uint256 amount)
        public
    {
        callCount++;
        address from  = _actor(fromSeed);
        address to    = _actor(toSeed);
        address asset = _asset(assetSeed);
        AToken aToken = AToken(_aToken(asset));
        uint256 bal   = aToken.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        _addHolder(to);
        vm.prank(from);
        try aToken.transfer(to, amount) {} catch {}
    }

    function liquidate(uint256 liqSeed, uint256 userSeed, uint256 collSeed, uint256 debtSeed, uint256 amount)
        public
    {
        callCount++;
        address liquidator = _actor(liqSeed);
        address user       = _actor(userSeed);
        address collateral = _asset(collSeed);
        address debtAsset  = _asset(debtSeed);
        if (collateral == debtAsset) return;

        uint256 debt = IERC20(_variableDebt(debtAsset)).balanceOf(user);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);

        deal(debtAsset, liquidator, IERC20(debtAsset).balanceOf(liquidator) + amount);
        vm.startPrank(liquidator);
        IERC20(debtAsset).approve(address(pool), amount);
        try pool.liquidationCall(collateral, debtAsset, user, amount, false) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 timeSeed) public {
        callCount++;
        uint256 jump = bound(timeSeed, 1 hours, 180 days);
        vm.warp(block.timestamp + jump);
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
