// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IPoolAddressesProvider} from "sparklend-v1-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {DataTypes} from "sparklend-v1-core/contracts/protocol/libraries/types/DataTypes.sol";
import {UserConfiguration} from "sparklend-v1-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import {Errors} from "sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol";
import {StableDebtToken} from "sparklend-v1-core/contracts/protocol/tokenization/StableDebtToken.sol";
import {VariableDebtToken} from "sparklend-v1-core/contracts/protocol/tokenization/VariableDebtToken.sol";

import {ReserveLogicWrapper} from "test/fuzz/wrappers/ReserveLogicWrapper.sol";
import {SparkLendTestBase} from "test/SparkLendTestBase.sol";

contract IndexedCollateralSafetyPoolWrapper is ReserveLogicWrapper {
    using UserConfiguration for DataTypes.UserConfigurationMap;

    constructor(IPoolAddressesProvider provider) ReserveLogicWrapper(provider) {}

    // Construct the stale flag directly so these tests isolate recovery behavior from its creation path.
    function setUsingAsCollateralForTest(address user, uint256 reserveId, bool enabled) external {
        _usersConfig[user].setUsingAsCollateral(reserveId, enabled);
    }
}

contract IndexedCollateralSafetyTests is SparkLendTestBase {
    uint128 constant RAY = 1e27;
    uint128 constant BASE_RATE_RAY = 0.05e27;

    // At this index, 1 unit scales to zero while 2 scales to one and that scaled unit is visible as 3.
    uint128 constant TARGET_LIQUIDITY_INDEX = 2530773485048679075952786560;
    uint256 constant FIRST_UNMINTABLE_AMOUNT = 1;
    uint256 constant FIRST_MINTABLE_AMOUNT = 2;
    uint256 constant FIRST_MINTABLE_VISIBLE_BALANCE = 3;

    // 50% LTV, 60% threshold, 100.01% bonus, 18 decimals, active, and 5% reserve factor.
    uint256 constant COLLATERAL_CONFIG = uint256(50_00) | (uint256(60_00) << 16) | (uint256(100_01) << 32)
        | (uint256(18) << 48) | (uint256(1) << 56) | (uint256(5_00) << 64);
    // Reserve zero's collateral bit in the interleaved user-configuration bitmap.
    uint256 constant COLLATERAL_USER_CONFIG = 2;

    address owner = makeAddr("owner");

    StableDebtToken stableDebtToken;
    VariableDebtToken variableDebtToken;
    IndexedCollateralSafetyPoolWrapper testPool;
    address collateralStrategy;
    uint256 supplyAmount;

    struct UserAccountDataSnapshot {
        uint256 totalCollateralBase;
        uint256 totalDebtBase;
        uint256 availableBorrowsBase;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
    }

    struct IndexedState {
        DataTypes.ReserveData reserve;
        uint256 underlyingTotalSupply;
        uint256 ownerUnderlyingBalance;
        uint256 ownerUnderlyingAllowance;
        uint256 ownerATokenAllowance;
        uint256 ownerVisibleBalance;
        uint256 ownerScaledBalance;
        uint256 ownerPreviousIndex;
        uint256 ownerUserConfiguration;
        UserAccountDataSnapshot ownerAccountData;
        uint256 treasuryUnderlyingBalance;
        uint256 treasuryUnderlyingAllowance;
        uint256 treasuryATokenAllowance;
        uint256 treasuryVisibleBalance;
        uint256 treasuryScaledBalance;
        uint256 treasuryPreviousIndex;
        uint256 treasuryUserConfiguration;
        UserAccountDataSnapshot treasuryAccountData;
        uint256 scaledATokenSupply;
        uint256 visibleATokenSupply;
        uint256 stableDebtOwnerBalance;
        uint256 stableDebtTotalSupply;
        uint256 variableDebtOwnerBalance;
        uint256 variableDebtOwnerScaledBalance;
        uint256 variableDebtOwnerPreviousIndex;
        uint256 variableDebtScaledTotalSupply;
        uint256 variableDebtTotalSupply;
        uint256 reserveCash;
    }

    function setUp() public override {
        super.setUp();

        _initCollateral({
            asset: address(collateralAsset), ltv: 50_00, liquidationThreshold: 60_00, liquidationBonus: 100_01
        });

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(collateralAsset));
        assertEq(reserve.id, 0, "fixture.collateralReserveId");

        stableDebtToken = StableDebtToken(reserve.stableDebtTokenAddress);
        variableDebtToken = VariableDebtToken(reserve.variableDebtTokenAddress);
        collateralStrategy = reserve.interestRateStrategyAddress;

        testPool = new IndexedCollateralSafetyPoolWrapper(poolAddressesProvider);
        testPool.initialize(poolAddressesProvider);

        // Install the wrapper as the Pool proxy implementation so it operates on live Pool storage.
        vm.prank(admin);
        poolAddressesProvider.setPoolImpl(address(testPool));

        vm.label(owner, "owner");
    }

    modifier givenSyntheticEnabledCollateralFlagWithZeroScaledBalance() {
        // Rebind the wrapper interface to the proxy; the implementation instance has separate storage.
        testPool = IndexedCollateralSafetyPoolWrapper(address(pool));
        testPool.cumulateToLiquidityIndex(address(collateralAsset), RAY, TARGET_LIQUIDITY_INDEX - RAY);
        testPool.setUsingAsCollateralForTest(owner, 0, true);

        assertEq(pool.getReserveNormalizedIncome(address(collateralAsset)), TARGET_LIQUIDITY_INDEX);
        assertEq(_rayDivHalfUp(FIRST_UNMINTABLE_AMOUNT, TARGET_LIQUIDITY_INDEX), 0);
        assertEq(_rayDivHalfUp(FIRST_MINTABLE_AMOUNT, TARGET_LIQUIDITY_INDEX), 1);
        assertEq(_rayMulHalfUp(1, TARGET_LIQUIDITY_INDEX), FIRST_MINTABLE_VISIBLE_BALANCE);
        _assertIndexedState(_expectedSyntheticStaleState(0, 0));
        _;
    }

    modifier whenSupplyIsBelowFirstHalfUpMintableAmount() {
        supplyAmount = FIRST_UNMINTABLE_AMOUNT;
        _mintAndApproveSupply(supplyAmount);
        _;
    }

    modifier whenSupplyIsAtFirstHalfUpMintableAmount() {
        supplyAmount = FIRST_MINTABLE_AMOUNT;
        _mintAndApproveSupply(supplyAmount);
        _;
    }

    modifier givenFirstHalfUpMintableResupply() {
        _mintAndApproveSupply(FIRST_MINTABLE_AMOUNT);
        vm.prank(owner);
        pool.supply(address(collateralAsset), FIRST_MINTABLE_AMOUNT, owner, 0);
        _;
    }

    function test_staleFlagDisableRevertsAndPreservesState()
        public
        givenSyntheticEnabledCollateralFlagWithZeroScaledBalance
    {
        IndexedState memory expected = _expectedSyntheticStaleState(0, 0);

        vm.prank(owner);
        vm.expectRevert(bytes(Errors.UNDERLYING_BALANCE_ZERO));
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);

        _assertIndexedState(expected);
    }

    function test_belowFirstMintableSupplyRevertsAndPreservesState()
        public
        givenSyntheticEnabledCollateralFlagWithZeroScaledBalance
        whenSupplyIsBelowFirstHalfUpMintableAmount
    {
        IndexedState memory expected = _expectedSyntheticStaleState(supplyAmount, supplyAmount);
        _assertIndexedState(expected);

        vm.prank(owner);
        vm.expectRevert(bytes(Errors.INVALID_MINT_AMOUNT));
        pool.supply(address(collateralAsset), supplyAmount, owner, 0);

        _assertIndexedState(expected);
    }

    function test_indexedCollateralSafety_01()
        public
        givenSyntheticEnabledCollateralFlagWithZeroScaledBalance
        whenSupplyIsAtFirstHalfUpMintableAmount
    {
        _assertIndexedState(_expectedSyntheticStaleState(supplyAmount, supplyAmount));

        vm.prank(owner);
        pool.supply(address(collateralAsset), supplyAmount, owner, 0);

        _assertIndexedState(_expectedRecoveredState());
    }

    function test_indexedCollateralSafety_02()
        public
        givenSyntheticEnabledCollateralFlagWithZeroScaledBalance
        givenFirstHalfUpMintableResupply
    {
        IndexedState memory expected = _expectedRecoveredState();
        _assertIndexedState(expected);

        vm.prank(owner);
        pool.setUserUseReserveAsCollateral(address(collateralAsset), false);

        expected.ownerUserConfiguration = 0;
        _assertIndexedState(expected);
    }

    function _mintAndApproveSupply(uint256 amount) internal {
        collateralAsset.mint(owner, amount);
        vm.prank(owner);
        collateralAsset.approve(address(pool), amount);
    }

    function _expectedSyntheticStaleState(uint256 ownerBalance, uint256 ownerAllowance)
        internal
        view
        returns (IndexedState memory expected)
    {
        expected.reserve.configuration.data = COLLATERAL_CONFIG;
        expected.reserve.liquidityIndex = TARGET_LIQUIDITY_INDEX;
        expected.reserve.variableBorrowIndex = RAY;
        expected.reserve.id = 0;
        expected.reserve.aTokenAddress = address(aCollateralAsset);
        expected.reserve.stableDebtTokenAddress = address(stableDebtToken);
        expected.reserve.variableDebtTokenAddress = address(variableDebtToken);
        expected.reserve.interestRateStrategyAddress = collateralStrategy;

        expected.underlyingTotalSupply = ownerBalance;
        expected.ownerUnderlyingBalance = ownerBalance;
        expected.ownerUnderlyingAllowance = ownerAllowance;
        expected.ownerUserConfiguration = COLLATERAL_USER_CONFIG;
        expected.ownerAccountData = _emptyAccountData();
        expected.treasuryAccountData = _emptyAccountData();
    }

    function _expectedRecoveredState() internal view returns (IndexedState memory expected) {
        expected = _expectedSyntheticStaleState(FIRST_MINTABLE_AMOUNT, FIRST_MINTABLE_AMOUNT);
        expected.reserve.lastUpdateTimestamp = 1;
        expected.reserve.currentVariableBorrowRate = BASE_RATE_RAY;
        expected.ownerUnderlyingBalance = 0;
        expected.ownerUnderlyingAllowance = 0;
        expected.ownerVisibleBalance = FIRST_MINTABLE_VISIBLE_BALANCE;
        expected.ownerScaledBalance = 1;
        expected.ownerPreviousIndex = TARGET_LIQUIDITY_INDEX;
        expected.scaledATokenSupply = 1;
        expected.visibleATokenSupply = FIRST_MINTABLE_VISIBLE_BALANCE;
        expected.reserveCash = FIRST_MINTABLE_AMOUNT;
    }

    function _assertIndexedState(IndexedState memory expected) internal {
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(collateralAsset));

        assertEq(reserve.configuration.data, expected.reserve.configuration.data, "reserve.configuration");
        assertEq(reserve.liquidityIndex, expected.reserve.liquidityIndex, "reserve.liquidityIndex");
        assertEq(reserve.currentLiquidityRate, expected.reserve.currentLiquidityRate, "reserve.currentLiquidityRate");
        assertEq(reserve.variableBorrowIndex, expected.reserve.variableBorrowIndex, "reserve.variableBorrowIndex");
        assertEq(
            reserve.currentVariableBorrowRate,
            expected.reserve.currentVariableBorrowRate,
            "reserve.currentVariableBorrowRate"
        );
        assertEq(
            reserve.currentStableBorrowRate, expected.reserve.currentStableBorrowRate, "reserve.currentStableBorrowRate"
        );
        assertEq(reserve.lastUpdateTimestamp, expected.reserve.lastUpdateTimestamp, "reserve.lastUpdateTimestamp");
        assertEq(reserve.id, expected.reserve.id, "reserve.id");
        assertEq(reserve.aTokenAddress, expected.reserve.aTokenAddress, "reserve.aTokenAddress");
        assertEq(
            reserve.stableDebtTokenAddress, expected.reserve.stableDebtTokenAddress, "reserve.stableDebtTokenAddress"
        );
        assertEq(
            reserve.variableDebtTokenAddress,
            expected.reserve.variableDebtTokenAddress,
            "reserve.variableDebtTokenAddress"
        );
        assertEq(reserve.interestRateStrategyAddress, expected.reserve.interestRateStrategyAddress, "reserve.strategy");
        assertEq(reserve.accruedToTreasury, expected.reserve.accruedToTreasury, "reserve.accruedToTreasury");
        assertEq(reserve.unbacked, expected.reserve.unbacked, "reserve.unbacked");
        assertEq(
            reserve.isolationModeTotalDebt, expected.reserve.isolationModeTotalDebt, "reserve.isolationModeTotalDebt"
        );

        assertEq(collateralAsset.totalSupply(), expected.underlyingTotalSupply, "underlying.totalSupply");
        assertEq(collateralAsset.balanceOf(owner), expected.ownerUnderlyingBalance, "owner.underlyingBalance");
        assertEq(
            collateralAsset.allowance(owner, address(pool)),
            expected.ownerUnderlyingAllowance,
            "owner.underlyingAllowance"
        );
        assertEq(
            aCollateralAsset.allowance(owner, address(pool)), expected.ownerATokenAllowance, "owner.aTokenAllowance"
        );
        assertEq(aCollateralAsset.balanceOf(owner), expected.ownerVisibleBalance, "owner.visibleBalance");
        assertEq(aCollateralAsset.scaledBalanceOf(owner), expected.ownerScaledBalance, "owner.scaledBalance");
        assertEq(aCollateralAsset.getPreviousIndex(owner), expected.ownerPreviousIndex, "owner.previousIndex");
        assertEq(pool.getUserConfiguration(owner).data, expected.ownerUserConfiguration, "owner.userConfiguration");
        _assertAccountData(owner, expected.ownerAccountData, "owner.accountData");

        assertEq(collateralAsset.balanceOf(treasury), expected.treasuryUnderlyingBalance, "treasury.underlyingBalance");
        assertEq(
            collateralAsset.allowance(treasury, address(pool)),
            expected.treasuryUnderlyingAllowance,
            "treasury.underlyingAllowance"
        );
        assertEq(
            aCollateralAsset.allowance(treasury, address(pool)),
            expected.treasuryATokenAllowance,
            "treasury.aTokenAllowance"
        );
        assertEq(aCollateralAsset.balanceOf(treasury), expected.treasuryVisibleBalance, "treasury.visibleBalance");
        assertEq(aCollateralAsset.scaledBalanceOf(treasury), expected.treasuryScaledBalance, "treasury.scaledBalance");
        assertEq(aCollateralAsset.getPreviousIndex(treasury), expected.treasuryPreviousIndex, "treasury.previousIndex");
        assertEq(
            pool.getUserConfiguration(treasury).data, expected.treasuryUserConfiguration, "treasury.userConfiguration"
        );
        _assertAccountData(treasury, expected.treasuryAccountData, "treasury.accountData");

        assertEq(aCollateralAsset.scaledTotalSupply(), expected.scaledATokenSupply, "aToken.scaledTotalSupply");
        assertEq(aCollateralAsset.totalSupply(), expected.visibleATokenSupply, "aToken.totalSupply");
        assertEq(stableDebtToken.balanceOf(owner), expected.stableDebtOwnerBalance, "stableDebt.ownerBalance");
        assertEq(stableDebtToken.totalSupply(), expected.stableDebtTotalSupply, "stableDebt.totalSupply");
        assertEq(variableDebtToken.balanceOf(owner), expected.variableDebtOwnerBalance, "variableDebt.ownerBalance");
        assertEq(
            variableDebtToken.scaledBalanceOf(owner),
            expected.variableDebtOwnerScaledBalance,
            "variableDebt.ownerScaledBalance"
        );
        assertEq(
            variableDebtToken.getPreviousIndex(owner),
            expected.variableDebtOwnerPreviousIndex,
            "variableDebt.ownerPreviousIndex"
        );
        assertEq(
            variableDebtToken.scaledTotalSupply(),
            expected.variableDebtScaledTotalSupply,
            "variableDebt.scaledTotalSupply"
        );
        assertEq(variableDebtToken.totalSupply(), expected.variableDebtTotalSupply, "variableDebt.totalSupply");
        assertEq(collateralAsset.balanceOf(address(aCollateralAsset)), expected.reserveCash, "reserveCash");
    }

    function _getAccountData(address user) internal view returns (UserAccountDataSnapshot memory data) {
        (
            data.totalCollateralBase,
            data.totalDebtBase,
            data.availableBorrowsBase,
            data.currentLiquidationThreshold,
            data.ltv,
            data.healthFactor
        ) = pool.getUserAccountData(user);
    }

    function _assertAccountData(address user, UserAccountDataSnapshot memory expected, string memory label) internal {
        UserAccountDataSnapshot memory actual = _getAccountData(user);

        assertEq(actual.totalCollateralBase, expected.totalCollateralBase, string.concat(label, ".totalCollateralBase"));
        assertEq(actual.totalDebtBase, expected.totalDebtBase, string.concat(label, ".totalDebtBase"));
        assertEq(
            actual.availableBorrowsBase, expected.availableBorrowsBase, string.concat(label, ".availableBorrowsBase")
        );
        assertEq(
            actual.currentLiquidationThreshold,
            expected.currentLiquidationThreshold,
            string.concat(label, ".currentLiquidationThreshold")
        );
        assertEq(actual.ltv, expected.ltv, string.concat(label, ".ltv"));
        assertEq(actual.healthFactor, expected.healthFactor, string.concat(label, ".healthFactor"));
    }

    function _emptyAccountData() internal pure returns (UserAccountDataSnapshot memory data) {
        data.healthFactor = type(uint256).max;
    }

    function _rayMulHalfUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + 0.5e27) / RAY;
    }

    function _rayDivHalfUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + (b / 2)) / b;
    }
}
