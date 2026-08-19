// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { console } from "../../lib/forge-std/src/console.sol";

import { WadRayMath } from "../../lib/sparklend-v1-core/contracts/protocol/libraries/math/WadRayMath.sol";

import { MockOracle } from "../mocks/MockOracle.sol";

import { SparkLendTestBase } from "../SparkLendTestBase.sol";

interface IERC20Like {

    function approve(address to, uint256 amount) external returns (bool);

    function totalSupply() external view returns (uint256);

}

// Worst realistic case for audit finding #177, "Same-asset underlying liquidation stores rates
// without repaid liquidity" (ACK'd, Low).
//
// liquidationCall(A, A, user, ..., false) updates reserve A's rates twice. The debt-side update
// models the repayment as liquidity added; _burnCollateralATokens then overwrites it, passing only
// the collateral withdrawal as liquidityTaken and nothing as liquidityAdded, while neither
// underlying transfer has happened yet. The repayment lands afterwards with no further rate
// update, so the reserve stores rates priced as though `actualDebtToLiquidate` less cash exists
// than it actually holds.
//
// The stored supply rate is then too high for the real utilization, so suppliers are credited more
// than borrowers owe plus the reserve factor's cut. That surplus is unbacked: claims outgrow
// cash + debt until the next action on the reserve reprices it, and the gap banked by then never
// reverses.
contract SameAssetLiquidation is SparkLendTestBase {

    using WadRayMath for uint256;

    // Supplied and reverted purely to refresh the reserve before reading its state.
    uint256 internal constant MIN_DUST = 0.000000000001e18;

    // SparkLend's largest stablecoin reserves sit in the billions.
    uint256 internal constant RESERVE_SIZE = 3_000_000_000e18;

    // The victim loops the reserve asset against mixed collateral, so the crash of the volatile
    // leg is what puts them underwater. Sized so the seizure consumes their whole stable collateral
    // leg, which maximises the cash the stored rates fail to see.
    uint256 internal constant VICTIM_STABLE_COLLATERAL   = 1_100_000_000e18;
    uint256 internal constant VICTIM_VOLATILE_COLLATERAL =   900_000_000e18;
    uint256 internal constant VICTIM_DEBT                = 1_400_000_000e18;

    // Left borrowed by unrelated users, so the reserve still carries debt to misprice afterwards.
    uint256 internal constant OTHER_DEBT = 450_000_000e18;

    address internal lp            = makeAddr("lp");
    address internal otherBorrower = makeAddr("otherBorrower");
    address internal victim        = makeAddr("victim");

    // Net claims right after the liquidation, which every later reading is measured against.
    int256 internal baseline;

    address internal stableAsset;
    address internal volatileAsset;

    function setUp() public virtual override {
        super.setUp();

        stableAsset   = address(collateralAsset);
        volatileAsset = address(borrowAsset);

        _initCollateral(stableAsset,   70_00, 75_00, 105_00);
        _initCollateral(volatileAsset, 70_00, 75_00, 105_00);

        vm.startPrank(admin);
        poolConfigurator.setReserveBorrowing(stableAsset, true);
        poolConfigurator.setLiquidationProtocolFee(stableAsset, 10_00);
        vm.stopPrank();
    }

    function test_sameAssetLiquidation_doesNotLeak() external {
        // The victim loops the reserve asset against both legs of their collateral.
        _supplyAndUseAsCollateral(victim, stableAsset,   VICTIM_STABLE_COLLATERAL);
        _supplyAndUseAsCollateral(victim, volatileAsset, VICTIM_VOLATILE_COLLATERAL);

        // Everyone else in the reserve, bringing it up to mainnet scale.
        _supply(lp, stableAsset, RESERVE_SIZE - IERC20Like(stableAsset).totalSupply());

        _supplyAndUseAsCollateral(otherBorrower, volatileAsset, OTHER_DEBT * 2);
        _borrow(otherBorrower, stableAsset, OTHER_DEBT);

        _borrow(victim, stableAsset, VICTIM_DEBT);

        _logState("before crash");

        // The volatile leg halves, which is what makes the position liquidatable.
        MockOracle(aaveOracle.getSourceOfAsset(volatileAsset)).__setPrice(0.5e8);

        _logState("after crash");

        _liquidate(victim, stableAsset, stableAsset, false);

        baseline = _getNetClaims();

        _logState("after liquidation");

        // Nobody touches the reserve, so the mispriced rates keep accruing unbacked claims.
        skip(1 hours);
        _logState("+1 hour (realistic gap between actions at this size)");

        skip(23 hours);
        _logState("+1 day");

        skip(6 days);
        _logState("+7 days");

        skip(23 days);
        uint256 unbacked = _logState("+30 days (a very quiet reserve)");

        // The next action reprices the reserve, but the shortfall banked by then is permanent.
        _supply(lp, stableAsset, MIN_DUST);

        _logState("after poke (rates corrected)");

        skip(30 days);
        uint256 unbackedAfterRepricing = _logState("+30 days, repriced");

        assertEq(unbacked, 0, "mispricing accrued a shortfall");
    }

    function _liquidate(address user, address collateral, address debt, bool receiveAToken) internal {
        address liquidator = makeAddr("liquidator");

        deal(debt, liquidator, VICTIM_DEBT);

        vm.startPrank(liquidator);

        IERC20Like(debt).approve(address(pool), type(uint256).max);

        // receiveAToken=true covers the aToken-transfer path (no burn); the liquidator is an
        // actor, so the holder set used by the conservation invariants stays closed.
        pool.liquidationCall(collateral, debt, user, type(uint256).max, receiveAToken);

        vm.stopPrank();
    }

    // Claims the reserve owes less the cash and debt backing them, the same quantity invariant_full
    // requires to stay at or below zero.
    //
    // Measured behind a dust supply that is reverted immediately: `accruedToTreasury` is only
    // booked when the reserve is touched, so reading it straight off a stale reserve would miss the
    // treasury's share of the pending interest.
    function _getNetClaims() internal returns (int256) {
        uint256 snapshot = vm.snapshotState();

        _supply(lp, stableAsset, MIN_DUST);

        address vDebt = pool.getReserveData(stableAsset).variableDebtTokenAddress;

        uint256 backing = collateralAsset.balanceOf(address(aCollateralAsset)) + IERC20Like(vDebt).totalSupply();

        uint256 claims = aCollateralAsset.totalSupply()
            + uint256(pool.getReserveData(stableAsset).accruedToTreasury).rayMul(pool.getReserveNormalizedIncome(stableAsset));

        vm.revertToState(snapshot);

        return int256(claims) - int256(backing);
    }

    // Unbacked claims accrued since the liquidation. Measured against a baseline because the
    // liquidation itself leaves the reserve slightly over-backed, from bps rounding on a
    // billion-scale seizure.
    function _logState(string memory label) internal returns (uint256 unbacked) {
        int256 netClaims = _getNetClaims();

        unbacked = netClaims > baseline ? uint256(netClaims - baseline) : 0;

        uint256 cash = collateralAsset.balanceOf(address(aCollateralAsset));
        uint256 debt = IERC20Like(pool.getReserveData(stableAsset).variableDebtTokenAddress).totalSupply();

        console.log("");
        console.log(label);
        console.log("  cash / debt (millions)  ", cash / 1e24, debt / 1e24);
        console.log("  true utilization (bps)  ", debt * 10_000 / (cash + debt));
        console.log("  stored borrow rate (bps)", pool.getReserveData(stableAsset).currentVariableBorrowRate / 1e23);
        console.log("  stored supply rate (bps)", pool.getReserveData(stableAsset).currentLiquidityRate / 1e23);
        console.log("  UNBACKED CLAIMS (tokens)", unbacked / 1e18);
    }

}
