// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { IPool } from "../../../lib/sparklend-v1-core/contracts/interfaces/IPool.sol";

import { DataTypes } from "../../../lib/sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";

import { UserConfiguration } from "../../../lib/sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";

import { MockReceiverBasic }       from "../../mocks/MockReceiver.sol";
import { MockReceiverSimpleBasic } from "../../mocks/MockReceiverSimple.sol";

interface IAaveOracleLike {

    function getAssetPrice(address asset) external view returns (uint256);

    function getSourceOfAsset(address asset) external view returns (address);

}

interface IERC20Like {

    function approve(address, uint256) external;

    function transfer(address, uint256) external;

    function transferFrom(address, address, uint256) external;

    function allowance(address, address) external view returns (uint256);

    function balanceOf(address) external view returns (uint256);

    function decimals() external view returns (uint256);

}

interface IMockOracleLike {

    function __setPrice(int256 price) external;

    function latestAnswer() external view returns (int256);

}

interface IScaledTokenLike is IERC20Like {

    function scaledBalanceOf(address) external view returns (uint256);

}

// Stateful fuzzing handler for SparkLend. Every action is bounded and wrapped so a revert never
// halts the campaign; the invariants live in Invariants.t.sol. Actions cover the full PR blast
// radius: supply / withdraw / borrow / repay / aToken transfer / liquidation / time warp.
contract PoolHandler is Test {

    uint256 internal constant MIN_AMOUNT = 0.000000000001e18; // 1e6

    IPool public immutable pool;

    address public immutable flashLoanReceiver;
    address public immutable flashLoanSimpleReceiver;

    address[] public actors;
    address[] public assets;

    constructor(address pool_, address[] memory actors_, address[] memory assets_) {
        pool   = IPool(pool_);
        actors = actors_;
        assets = assets_;

        flashLoanReceiver       = address(new MockReceiverBasic(address(0), pool_));
        flashLoanSimpleReceiver = address(new MockReceiverSimpleBasic(address(0), pool_));
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _getAsset(uint256 seed) internal view returns (address) {
        return assets[seed % assets.length];
    }

    /**********************************************************************************************/
    /*** Actions                                                                                ***/
    /**********************************************************************************************/

    function warp(uint256 timeSeed) public {
        uint256 jump = _bound(timeSeed, 1 seconds, 10 days);
        vm.warp(vm.getBlockTimestamp() + jump);
    }

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        address asset = _getAsset(assetSeed);

        amount = _bound(amount, MIN_AMOUNT, 1_000_000e18);

        deal(asset, actor, IERC20Like(asset).balanceOf(actor) + amount);

        IERC20Like aToken = IERC20Like(_getAToken(asset));

        uint256 aTokenStartingBalance = aToken.balanceOf(actor);
        uint256 assetStartingBalance  = IERC20Like(asset).balanceOf(actor);

        vm.startPrank(actor);
        IERC20Like(asset).approve(address(pool), amount);
        pool.supply(asset, amount, actor, 0);
        vm.stopPrank();

        assertEq(IERC20Like(asset).balanceOf(actor), assetStartingBalance - amount);

        uint256 mintedATokens = aToken.balanceOf(actor) - aTokenStartingBalance;

        // Minted aTokens always round against the user, up to index / 1e27
        // Assuming liquidityIndex doesn't get above 5e27
        assertLe(mintedATokens, amount,     "mintedATokens > amount");
        assertGe(mintedATokens, amount - 5, "mintedATokens < amount - 5");
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        address asset = _getAsset(assetSeed);

        uint256 aTokenStartingBalance = IERC20Like(_getAToken(asset)).balanceOf(actor);
        uint256 maxWithdrawable       = _getMaxWithdrawable(actor, asset);

        // Cap at reserve cash so the underlying transfer can't revert.
        uint256 cash = IERC20Like(asset).balanceOf(_getAToken(asset));

        if (maxWithdrawable > cash) maxWithdrawable = cash;

        vm.assume(maxWithdrawable >= MIN_AMOUNT);

        // ~10% chance of max withdraw if entire balance is withdrawable.
        if (maxWithdrawable == aTokenStartingBalance) {
            amount = _bound(amount, MIN_AMOUNT, (maxWithdrawable * 11) / 10);
        } else {
            amount = _bound(amount, MIN_AMOUNT, maxWithdrawable);
        }

        uint256 assetStartingBalance = IERC20Like(asset).balanceOf(actor);

        if (amount > aTokenStartingBalance) {
            vm.prank(actor);
            amount = pool.withdraw(asset, type(uint256).max, actor);
        } else {
            vm.prank(actor);
            pool.withdraw(asset, amount, actor);
        }

        assertEq(IERC20Like(asset).balanceOf(actor), assetStartingBalance + amount);

        uint256 burnedATokens = aTokenStartingBalance - IERC20Like(_getAToken(asset)).balanceOf(actor);

        // Burned aTokens always round against the user, up to index / 1e27
        // Assuming liquidityIndex doesn't get above 5e27
        assertGe(burnedATokens, amount,     "burnedATokens < amount");
        assertLe(burnedATokens, amount + 5, "burnedATokens > amount + 5");
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        address asset = _getAsset(assetSeed);

        ( , , uint256 availableBorrowsBase, , , ) = pool.getUserAccountData(actor);

        uint256 maxBorrowable = (availableBorrowsBase * 1e18) / _getAssetPrice(asset);
        uint256 cash          = IERC20Like(asset).balanceOf(_getAToken(asset));

        // Cap at reserve cash so the underlying transfer can't revert.
        if (maxBorrowable > cash) maxBorrowable = cash;

        vm.assume(maxBorrowable >= 1e18);

        // Leave a few base currency units of headroom: percentDiv in validateBorrow is not an
        // exact inverse of percentMul in calculateAvailableBorrows, so the exact max can revert.
        amount = _bound(amount, MIN_AMOUNT, maxBorrowable - 0.0000001e18);

        address debtToken = _getVariableDebtToken(asset);

        uint256 assetStartingBalance = IERC20Like(asset).balanceOf(actor);
        uint256 debtStartingBalance  = IERC20Like(debtToken).balanceOf(actor);

        vm.prank(actor);
        pool.borrow(asset, amount, 2, 0, actor);

        assertEq(IERC20Like(asset).balanceOf(actor), assetStartingBalance + amount);

        uint256 mintedDebtTokens = IERC20Like(debtToken).balanceOf(actor) - debtStartingBalance;

        // Minted debt tokens always round against the user, up to index / 1e27
        // Assuming variableBorrowIndex doesn't get above 5e27
        assertGe(mintedDebtTokens, amount,     "mintedDebtTokens < amount");
        assertLe(mintedDebtTokens, amount + 5, "mintedDebtTokens > amount + 5");

        ( ,,,,, uint256 healthFactor ) = pool.getUserAccountData(actor);

        assertGe(healthFactor, 1e18);
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        address asset = _getAsset(assetSeed);

        uint256 debt = IERC20Like(_getVariableDebtToken(asset)).balanceOf(actor);

        vm.assume(debt >= MIN_AMOUNT);

        // ~10% chance of max repay if entire debt is repayable.
        amount = _bound(amount, MIN_AMOUNT, (debt * 11) / 10);

        deal(asset, actor, IERC20Like(asset).balanceOf(actor) + amount);

        uint256 actualRepaid         = amount > debt ? debt : amount;
        uint256 assetStartingBalance = IERC20Like(asset).balanceOf(actor);

        ( ,,,,, uint256 healthFactorBefore ) = pool.getUserAccountData(actor);

        vm.startPrank(actor);

        IERC20Like(asset).approve(address(pool), amount);

        if (amount > debt) {
            pool.repay(asset, type(uint256).max, 2, actor);
        } else {
            pool.repay(asset, amount, 2, actor);
        }

        vm.stopPrank();

        ( ,,,,, uint256 healthFactorAfter ) = pool.getUserAccountData(actor);

        assertGe(healthFactorAfter, healthFactorBefore);

        assertEq(IERC20Like(asset).balanceOf(actor), assetStartingBalance - actualRepaid);

        uint256 burnedDebtTokens = debt - IERC20Like(_getVariableDebtToken(asset)).balanceOf(actor);

        // Burned debt tokens always round against the user, up to index / 1e27
        // Assuming variableBorrowIndex doesn't get above 5e27
        assertLe(burnedDebtTokens, actualRepaid,     "burnedDebtTokens > actualRepaid");
        assertGe(burnedDebtTokens, actualRepaid - 5, "burnedDebtTokens < actualRepaid - 5");

        // Debt reduced within index rounding, either direction (same 5 wei bound as supply, index <= 5e27)
        assertApproxEqAbs(IERC20Like(_getVariableDebtToken(asset)).balanceOf(actor), debt - actualRepaid, 5);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 assetSeed, uint256 amount) external {
        address from  = _getActor(fromSeed);
        address to    = _getActor(toSeed);
        address asset = _getAsset(assetSeed);

        uint256 maxTransferable = _getMaxWithdrawable(from, asset);

        IScaledTokenLike aToken = IScaledTokenLike(_getAToken(asset));

        uint256 startingATokenBalanceFrom = aToken.balanceOf(from);
        uint256 startingATokenBalanceTo   = aToken.balanceOf(to);

        uint256 startingScaledBalanceFrom = aToken.scaledBalanceOf(from);
        uint256 startingScaledBalanceTo   = aToken.scaledBalanceOf(to);

        vm.assume(maxTransferable >= MIN_AMOUNT);

        amount = _bound(amount, MIN_AMOUNT, maxTransferable);

        vm.prank(from);
        aToken.transfer(to, amount);

        uint256 transferredATokens       = startingATokenBalanceFrom - aToken.balanceOf(from);
        uint256 transferredScaledBalance = startingScaledBalanceFrom - aToken.scaledBalanceOf(from);

        uint256 receivedATokens       = aToken.balanceOf(to) - startingATokenBalanceTo;
        uint256 receivedScaledBalance = aToken.scaledBalanceOf(to) - startingScaledBalanceTo;

        // If the sender and recipient are the same, the deltas should all be zero
        if (from == to) {
            assertEq(transferredATokens,       0);
            assertEq(transferredScaledBalance, 0);
            assertEq(receivedATokens,          0);
            assertEq(receivedScaledBalance,    0);
            return;
        }

        // Scaled balance reduced from sender rounds up
        assertGe(transferredATokens, amount,     "transferredATokens < amount");
        assertLe(transferredATokens, amount + 5, "transferredATokens > amount + 5");

        // Difference in rebased amounts can be at most one unit because of floor rounding on balanceOf
        assertApproxEqAbs(receivedATokens, transferredATokens, 1, "receivedATokens > transferredATokens");

        // Scaled balance transfer is always exact
        assertEq(transferredScaledBalance, receivedScaledBalance);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 assetSeed, uint256 amount) external {
        address from  = _getActor(fromSeed);
        address to    = _getActor(toSeed);
        address asset = _getAsset(assetSeed);

        uint256 maxTransferable = _getMaxWithdrawable(from, asset);

        vm.assume(from != to);
        vm.assume(maxTransferable >= MIN_AMOUNT);

        amount = _bound(amount, MIN_AMOUNT, maxTransferable);

        // Alternate between an exact approval (exercises the allowance consumption cap) and a
        // loose one (exercises consumption == actual balance decrease).
        uint256 allowance = amount % 2 == 0 ? amount : amount * 2;

        IERC20Like aToken = IERC20Like(_getAToken(asset));

        vm.prank(from);
        aToken.approve(to, allowance);

        uint256 startingBalanceFrom = aToken.balanceOf(from);

        vm.prank(to);
        aToken.transferFrom(from, to, amount);

        uint256 balanceDecrease = startingBalanceFrom - aToken.balanceOf(from);

        // Sender's balance decrease rounds against them, up to index / 1e27
        // Assuming liquidityIndex doesn't get above 5e27
        assertGe(balanceDecrease, amount,     "balanceDecrease < amount");
        assertLe(balanceDecrease, amount + 5, "balanceDecrease > amount + 5");

        // Allowance is consumed by the sender's actual balance decrease, capped at the approval.
        uint256 expectedConsumption = balanceDecrease > allowance ? allowance : balanceDecrease;

        assertEq(
            allowance - aToken.allowance(from, to),
            expectedConsumption,
            "allowance consumed != balance decrease"
        );
    }

    function setCollateral(uint256 actorSeed, uint256 assetSeed, bool enable) external {
        address actor = _getActor(actorSeed);
        address asset = _getAsset(assetSeed);

        vm.assume(IERC20Like(_getAToken(asset)).balanceOf(actor) != 0);
        vm.assume(enable || _canDisableCollateral(actor, asset));

        vm.prank(actor);
        pool.setUserUseReserveAsCollateral(asset, enable);
    }

    function mintToTreasury(uint256 assetSeed) external {
        address[] memory list = new address[](1);
        list[0] = _getAsset(assetSeed);

        pool.mintToTreasury(list);
    }

    function liquidate(uint256 timeSeed, uint256 liquidatorSeed, uint256 amount, bool receiveAToken) external {
        uint256 jump = _bound(timeSeed, 30 days, 180 days);

        vm.warp(vm.getBlockTimestamp() + jump);

        address user = _getLeastHealthyBorrower();

        vm.assume(user != address(0));

        ( address collateralAsset, address debtAsset ) = _getTopPositions(user);

        vm.assume(collateralAsset != address(0));
        vm.assume(debtAsset       != address(0));

        address liquidator = _getActor(liquidatorSeed);

        vm.assume(liquidator != user);

        uint256 maxDebtToCover = _getMaxDebtToCover(user, debtAsset, collateralAsset);

        vm.assume(maxDebtToCover >= MIN_AMOUNT);

        // ~10% chance of max cover.
        amount = _bound(amount, MIN_AMOUNT, (11 * maxDebtToCover) / 10);

        deal(debtAsset, liquidator, IERC20Like(debtAsset).balanceOf(liquidator) + amount);

        vm.startPrank(liquidator);

        IERC20Like(debtAsset).approve(address(pool), amount);

        // receiveAToken=true covers the aToken-transfer path (no burn); the liquidator is an
        // actor, so the holder set used by the conservation invariants stays closed.
        if (amount > maxDebtToCover) {
            pool.liquidationCall(collateralAsset, debtAsset, user, type(uint256).max, receiveAToken);
        } else {
            pool.liquidationCall(collateralAsset, debtAsset, user, amount, receiveAToken);
        }

        vm.stopPrank();
    }

    function flashLoan(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address borrower = _getActor(actorSeed);

        address[] memory assets = new address[](1);
        assets[0] = _getAsset(assetSeed);

        amount = _bound(amount, MIN_AMOUNT, 100e18);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        vm.prank(borrower);
        pool.flashLoan(flashLoanReceiver, assets, amounts, modes, borrower, new bytes(0), 0);
    }

    function flashLoanSimple(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address borrower = _getActor(actorSeed);
        address asset    = _getAsset(assetSeed);

        amount = _bound(amount, MIN_AMOUNT, 100e18);

        vm.prank(borrower);
        pool.flashLoanSimple(flashLoanSimpleReceiver, asset, amount, new bytes(0), 0);
    }

    function setPrice(uint256 assetSeed, int256 price) external {
        address asset      = _getAsset(assetSeed);
        address aaveOracle = pool.ADDRESSES_PROVIDER().getPriceOracle();
        address source     = IAaveOracleLike(aaveOracle).getSourceOfAsset(asset);

        vm.assume(source != address(0));

        int256 currentPrice = IMockOracleLike(source).latestAnswer();
        int256 min          = (currentPrice * 9) / 10;
        int256 max          = (currentPrice * 11) / 10;

        price = _bound(price, min < 0.7e8 ? int256(0.7e8) : min, max > 1.3e8 ? int256(1.3e8) : max);

        IMockOracleLike(source).__setPrice(price);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // Exposed for the post-campaign wind-down in Invariants.t.sol. Not a fuzz target: the campaign
    // only runs the selectors registered in setUp.
    function maxWithdrawable(address actor, address asset) external view returns (uint256) {
        return _getMaxWithdrawable(actor, asset);
    }

    function _getAssetPrice(address asset) internal view returns (uint256) {
        return IAaveOracleLike(pool.ADDRESSES_PROVIDER().getPriceOracle()).getAssetPrice(asset);
    }

    function _getMaxWithdrawable(address actor, address asset) internal view returns (uint256) {
        // 1. Get the actor's total aToken balance (Absolute upper limit)
        uint256 absoluteMaxBalance = IERC20Like(_getAToken(asset)).balanceOf(actor);

        // 2. Fetch overall account data
        ( uint256 totalCollateralBase, uint256 totalDebtBase, , uint256 currentLiquidationThreshold, , ) = pool.getUserAccountData(actor);

        // If actor has no debt, they can withdraw their entire balance
        if (totalDebtBase == 0) return absoluteMaxBalance;

        // An actor with debt and no collateral value left is in bad debt, so nothing is safely
        // withdrawable. Their liquidation threshold is zero, which the division below cannot take.
        if (currentLiquidationThreshold == 0) return 0;

        // 3. Calculate minimum collateral required in Base Currency to keep Health Factor at 1.0
        // currentLiquidationThreshold is formatted in 4 decimals (e.g., 8500 = 85%), so we multiply by 10000
        // Round up and add two base units of margin: the HF check values debt with rayMulCeil and
        // collateral with rayMulFloor, so rounding down here can overshoot the HF = 1.0 boundary.
        uint256 minCollateralRequiredBase =
            (totalDebtBase * 10_000 + currentLiquidationThreshold - 1) / currentLiquidationThreshold + 2;

        // If user is already under the liquidation threshold, they can't withdraw anything safely
        if (totalCollateralBase <= minCollateralRequiredBase) return 0;

        // 4. Excess collateral value that can be safely removed (denominated in 8-decimal Base Currency)
        uint256 maxSafeWithdrawBase = totalCollateralBase - minCollateralRequiredBase;

        // 5. Convert Base Currency value into Asset units using the Oracle Price and Decimals
        uint256 maxSafeWithdraw = (maxSafeWithdrawBase * 1e18) / _getAssetPrice(asset);

        // 6. Return the stricter restriction
        return maxSafeWithdraw > absoluteMaxBalance ? absoluteMaxBalance : maxSafeWithdraw;
    }

    function _canDisableCollateral(address user, address asset) internal view returns (bool) {
        // 1. Fetch current global account metrics
        ( uint256 totalCollateralBase, uint256 totalDebtBase, , uint256 currentLiquidityThreshold, , ) = pool.getUserAccountData(user);

        // Safety Case: If the user has zero debt, they can always disable any collateral
        if (totalDebtBase == 0) return true;

        // 2. Fetch asset reserve configurations
        // Extract the specific asset's Liquidation Threshold from the configuration bitmask
        // Bits 16-31 represent the Liquidation Threshold in Aave V3
        uint256 assetLiquidityThreshold = (pool.getReserveData(asset).configuration.data >> 16) & 0xFFFF;

        // If the asset isn't even configured as collateral or threshold is 0, it can be disabled
        if (assetLiquidityThreshold == 0) return true;

        // 3. Calculate the asset's current value contribution in Base Currency
        uint256 balance = IERC20Like(_getAToken(asset)).balanceOf(user);

        if (balance == 0) return true; // No balance means removing it changes nothing

        uint256 assetValueBase = (balance * _getAssetPrice(asset)) / 1e18;

        // If the asset value is somehow greater than total collateral due to rounding/slippage, cap it
        if (assetValueBase >= totalCollateralBase) return false; // Removing it wipes out all collateral while debt exists

        // 4. Calculate hypothetical new values
        uint256 newCollateralBase = totalCollateralBase - assetValueBase;

        // Compute new weighted average liquidation threshold
        uint256 currentTotalProduct = totalCollateralBase * currentLiquidityThreshold;
        uint256 assetProduct        = assetValueBase * assetLiquidityThreshold;

        // Handle edge case to prevent underflow if products misalign slightly due to decimal rounding
        uint256 newLiquidityThreshold =
            currentTotalProduct > assetProduct
                ? (currentTotalProduct - assetProduct) / newCollateralBase
                : 0;

        // 5. Determine if the remaining collateral satisfies the outstanding debt
        // Liquidation thresholds are scaled to 4 decimals (e.g. 8500 = 85%), so divide by 10000
        uint256 maxAllowedDebtBase = (newCollateralBase * newLiquidityThreshold) / 10_000;

        return maxAllowedDebtBase > totalDebtBase;
    }

    function _getLeastHealthyBorrower() internal view returns (address) {
        uint256 leastHealthyHealthFactor = type(uint256).max;
        address leastHealthyBorrower;

        for (uint256 i; i < actors.length; ++i) {
            ( , , , , , uint256 healthFactor ) = pool.getUserAccountData(actors[i]);

            if (healthFactor < leastHealthyHealthFactor) {
                leastHealthyBorrower     = actors[i];
                leastHealthyHealthFactor = healthFactor;
            }
        }

        return leastHealthyBorrower;
    }

    function _getAssetStatus(address user, address asset) internal view returns (bool isCollateral, bool isBorrowing) {
        // 1. Fetch the unique index (id) of the token in the pool
        uint256 assetIndex = pool.getReserveData(asset).id;

        // 2. Fetch the user's global configuration bitmap
        DataTypes.UserConfigurationMap memory userConfig = pool.getUserConfiguration(user);

        // 3. Check specific bit offsets for this asset index
        isCollateral = UserConfiguration.isUsingAsCollateral(userConfig, assetIndex);
        isBorrowing  = UserConfiguration.isBorrowing(userConfig, assetIndex);
    }

    function _getTopPositions(address user) internal view returns (address highestCollateralAsset, address highestDebtAsset) {
        uint256 maxCollateralValueBase;
        uint256 maxDebtValueBase;

        // Loop through every asset to find the maximum values
        for (uint256 i = 0; i < assets.length; ++i) {
            address asset = assets[i];

            uint256 price = _getAssetPrice(asset);

            if (price == 0) continue;

            ( bool isCollateral, bool isBorrowing ) = _getAssetStatus(user, asset);

            // --- Collateral ---
            uint256 collateral = IERC20Like(_getAToken(asset)).balanceOf(user);

            if (isCollateral && (collateral > 0)) {
                // Convert raw balance to 8-decimal Base Currency
                uint256 collateralValueBase = (collateral * price) / 1e18;

                if (collateralValueBase > maxCollateralValueBase) {
                    maxCollateralValueBase = collateralValueBase;
                    highestCollateralAsset = asset;
                }
            }

            // --- Debt ---
            uint256 variableDebt    = IERC20Like(_getVariableDebtToken(asset)).balanceOf(user);
            uint256 stableDebt      = IERC20Like(_getStableDebtToken(asset)).balanceOf(user);
            uint256 totalDebtTokens = variableDebt + stableDebt;

            if (isBorrowing && (totalDebtTokens > 0)) {
                // Convert raw debt balance to 8-decimal Base Currency
                uint256 debtValueBase = (totalDebtTokens * price) / 1e18;

                if (debtValueBase > maxDebtValueBase) {
                    maxDebtValueBase = debtValueBase;
                    highestDebtAsset = asset;
                }
            }
        }
    }

    function _getMaxDebtToCover(
        address user,
        address debtAsset,
        address collateralAsset
    ) internal view returns (uint256) {
        // Fetch account info
        ( , , , , , uint256 healthFactor ) = pool.getUserAccountData(user);

        if (healthFactor >= 1e18) return 0;

        // Fetch user's total debt in the target debt asset (Variable + Stable)
        uint256 userVariableDebt = IERC20Like(_getVariableDebtToken(debtAsset)).balanceOf(user);
        uint256 userStableDebt   = IERC20Like(_getStableDebtToken(debtAsset)).balanceOf(user);
        uint256 totalDebt        = userVariableDebt + userStableDebt;

        // Determine Close Factor (Aave uses 18 decimals for HF, threshold is 0.95e18)
        uint256 closeFactor        = healthFactor > 0.95e18 ? 5_000 : 10_000; // in Basis Points (BPS)
        uint256 maxCloseFactorDebt = (totalDebt * closeFactor) / 10_000;

        uint256 collateralBalance = IERC20Like(_getAToken(collateralAsset)).balanceOf(user);

        // Sample bitmask parsing to extract Liquidation Bonus from Aave V3 configurations
        // Bits 32-47 represent the liquidation bonus in BPS (e.g., 10500 = 105%, meaning a 5% bonus)
        uint256 liquidationBonus = (pool.getReserveData(collateralAsset).configuration.data >> 32) & 0xFFFF;

        // Safety check: Avoid division by zero if asset configuration is missing or oracle fails
        uint256 debtPrice = _getAssetPrice(debtAsset);

        if (debtPrice == 0 || liquidationBonus == 0) return 0;

        // Calculate maximum debt that the actual available collateral can afford to reward
        uint256 maxDebtCoverableByCollateral = (collateralBalance * _getAssetPrice(collateralAsset) * 10_000) / (debtPrice * liquidationBonus);

        return maxCloseFactorDebt > maxDebtCoverableByCollateral ? maxDebtCoverableByCollateral : maxCloseFactorDebt;
    }

    function _getAToken(address asset) internal view returns (address) {
        return pool.getReserveData(asset).aTokenAddress;
    }

    function _getVariableDebtToken(address asset) internal view returns (address) {
        return pool.getReserveData(asset).variableDebtTokenAddress;
    }

    function _getStableDebtToken(address asset) internal view returns (address) {
        return pool.getReserveData(asset).stableDebtTokenAddress;
    }

}
