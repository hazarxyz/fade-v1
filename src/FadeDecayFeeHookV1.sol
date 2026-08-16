// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { FadeDecayFeeMath } from "./FadeDecayFeeMath.sol";

interface ICreatorToken {
    function creator() external view returns (address);
}

/// @title FadeDecayFeeHookV1
/// @notice Splits a time-decaying ETH swap fee between a pool creator and Programmable.
/// @dev The hook is shared by many pools. Each pool is registered once by the creator recorded on its token contract.
///      Fees accrue as native-currency ERC-6909 claims in PoolManager and can only be redeemed to the recorded creator
///      or the fixed Programmable treasury. The total fee starts at 3.00% and decays linearly over 24 hours to 1.00%.
///      Programmable's fixed 0.10 percentage-point share is deducted from that total and never added on top. The
///      contract is non-upgradeable and has no owner, pause, fee setter, recipient setter, or rescue control.
contract FadeDecayFeeHookV1 is BaseHook, IUnlockCallback, ReentrancyGuardTransient {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using CurrencySettler for Currency;
    using SafeCast for *;

    uint16 public constant PROGRAMMABLE_FEE_BPS = 10;
    uint16 public constant START_TOTAL_SWAP_FEE_BPS = 300;
    uint16 public constant END_TOTAL_SWAP_FEE_BPS = 100;
    uint256 public constant DECAY_DURATION = 1 days;
    uint24 public constant LP_FEE_PIPS = 0;
    int24 public constant TICK_SPACING = 200;

    address public constant PROGRAMMABLE_TREASURY = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    Currency private constant NATIVE = Currency.wrap(address(0));

    struct PoolFeeConfig {
        address creator;
        address registrar;
        uint64 launchTimestamp;
        bool registered;
        uint256 creatorFeesAccrued;
    }

    mapping(bytes32 poolId => PoolFeeConfig config) public poolFeeConfig;

    /// @notice Native ETH fees accrued to Programmable across every registered pool.
    uint256 public programmableFeesAccrued;

    /// @notice Total accounted native ETH claims held by this hook in PoolManager.
    uint256 public totalNativeFeesAccrued;

    error AlreadyRegistered(bytes32 poolId);
    error InvalidCreator(address creator);
    error InvalidCurrencyOrder(address currency0, address currency1);
    error InvalidHook(address actual, address expected);
    error InvalidLpFee(uint24 actual, uint24 expected);
    error InvalidRegistrar(address caller, address recordedCreator);
    error InvalidTickSpacing(int24 actual, int24 expected);
    error NoFeesToClaim();
    error PartialFillUnsupported(uint256 expectedNativePoolAmount, uint256 actualNativePoolAmount);
    error PoolNotRegistered(bytes32 poolId);
    error UnauthorizedInitializer(address caller, address expected);
    error UnexpectedUnlockResult();
    error UnexpectedHookData(uint256 length);
    error UnrecognizedToken(address token);
    error ZeroAddress();

    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed token,
        address indexed creator,
        address registrar,
        uint64 launchTimestamp,
        uint16 startTotalSwapFeeBps,
        uint16 endTotalSwapFeeBps,
        uint16 programmableFeeBps,
        uint256 decayDuration
    );
    event NativeSwapFeesAccrued(
        bytes32 indexed poolId,
        address indexed swapSender,
        bool indexed isBuy,
        uint16 appliedTotalSwapFeeBps,
        uint256 grossNativeAmount,
        uint256 creatorFee,
        uint256 programmableFee
    );
    event CreatorFeesClaimed(
        bytes32 indexed poolId, address indexed creator, address indexed recipient, address caller, uint256 amount
    );
    event ProgrammableFeesClaimed(
        address indexed treasury, address indexed recipient, address indexed caller, uint256 amount
    );

    constructor(IPoolManager poolManager_) BaseHook(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
    }

    /// @notice Registers one native ETH/token pool and starts its immutable 24-hour decay schedule.
    /// @dev The caller must be the address returned by token.creator(). Launcher-created UERC20s record the launcher
    ///      contract as creator, so registration and pool initialization remain atomic without a mutable allowlist.
    function registerPool(PoolKey calldata key, address creator) external returns (bytes32 poolId) {
        _validatePoolShape(key);
        if (creator == address(0)) revert InvalidCreator(creator);

        address token = Currency.unwrap(key.currency1);
        address recordedCreator = _recordedTokenCreator(token);
        if (recordedCreator != msg.sender) revert InvalidRegistrar(msg.sender, recordedCreator);

        poolId = PoolId.unwrap(key.toId());
        if (poolFeeConfig[poolId].registered) revert AlreadyRegistered(poolId);

        uint64 launchTimestamp = block.timestamp.toUint64();
        poolFeeConfig[poolId] = PoolFeeConfig({
            creator: creator,
            registrar: msg.sender,
            launchTimestamp: launchTimestamp,
            registered: true,
            creatorFeesAccrued: 0
        });

        emit PoolRegistered(
            poolId,
            token,
            creator,
            msg.sender,
            launchTimestamp,
            START_TOTAL_SWAP_FEE_BPS,
            END_TOTAL_SWAP_FEE_BPS,
            PROGRAMMABLE_FEE_BPS,
            DECAY_DURATION
        );
    }

    function totalSwapFeeBpsFor(bytes32 poolId, uint256 timestamp) public view returns (uint16) {
        PoolFeeConfig storage config = poolFeeConfig[poolId];
        if (!config.registered) revert PoolNotRegistered(poolId);
        return FadeDecayFeeMath.feeBpsAt(config.launchTimestamp, timestamp);
    }

    function currentTotalSwapFeeBps(bytes32 poolId) external view returns (uint16) {
        return totalSwapFeeBpsFor(poolId, block.timestamp);
    }

    /// @notice Returns the fees charged when `grossNativeAmount` is the complete ETH side of a swap.
    function quoteGrossFees(bytes32 poolId, uint256 grossNativeAmount, uint256 timestamp)
        external
        view
        returns (uint256 creatorFee, uint256 launcherFee)
    {
        return FadeDecayFeeMath.feesForGross(grossNativeAmount, totalSwapFeeBpsFor(poolId, timestamp));
    }

    /// @notice Returns fees that preserve `netNativeAmount` as the requested exact ETH output or pool input.
    function quoteExactOutputFees(bytes32 poolId, uint256 netNativeAmount, uint256 timestamp)
        external
        view
        returns (uint256 creatorFee, uint256 launcherFee)
    {
        return FadeDecayFeeMath.feesForNet(netNativeAmount, totalSwapFeeBpsFor(poolId, timestamp));
    }

    /// @notice Redeems one pool's accrued creator fees directly to its immutable creator recipient.
    /// @dev Anyone may trigger the claim but cannot redirect it.
    function claimCreatorFees(bytes32 poolId) external nonReentrant returns (uint256 amount) {
        PoolFeeConfig storage config = poolFeeConfig[poolId];
        if (!config.registered) revert PoolNotRegistered(poolId);

        return _claimCreatorFees(poolId, config, config.creator);
    }

    function _claimCreatorFees(bytes32 poolId, PoolFeeConfig storage config, address recipient)
        private
        returns (uint256 amount)
    {
        amount = config.creatorFeesAccrued;
        if (amount == 0) revert NoFeesToClaim();

        config.creatorFeesAccrued = 0;
        totalNativeFeesAccrued -= amount;
        _redeemNative(recipient, amount);

        emit CreatorFeesClaimed(poolId, config.creator, recipient, msg.sender, amount);
    }

    /// @notice Redeems all accrued Programmable fees to the policy-fixed treasury.
    /// @dev Anyone may trigger the claim but cannot redirect it.
    function claimProgrammableFees() external nonReentrant returns (uint256 amount) {
        return _claimProgrammableFees(PROGRAMMABLE_TREASURY);
    }

    function _claimProgrammableFees(address recipient) private returns (uint256 amount) {
        amount = programmableFeesAccrued;
        if (amount == 0) revert NoFeesToClaim();

        programmableFeesAccrued = 0;
        totalNativeFeesAccrued -= amount;
        _redeemNative(recipient, amount);

        emit ProgrammableFeesClaimed(PROGRAMMABLE_TREASURY, recipient, msg.sender, amount);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        PoolFeeConfig storage config = _registeredConfig(key);
        if (sender != config.registrar) revert UnauthorizedInitializer(sender, config.registrar);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateHookData(hookData);
        bytes32 poolId = _registeredPoolId(key);
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (!nativeIsSpecified) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 nativeAmount = _absolute(params.amountSpecified);
        uint256 totalFee = _chargeNative(poolId, sender, nativeAmount, params.amountSpecified > 0, params.zeroForOne);
        if (totalFee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(totalFee.toInt256().toInt128(), 0), 0);
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        _validateHookData(hookData);
        bytes32 poolId = _registeredPoolId(key);
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (nativeIsSpecified) {
            _verifySpecifiedNativeDelta(poolId, params, delta);
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 nativeAmount = _absolute(int256(delta.amount0()));
        uint256 totalFee = _chargeNative(poolId, sender, nativeAmount, params.amountSpecified > 0, params.zeroForOne);
        if (totalFee == 0) return (IHooks.afterSwap.selector, 0);

        return (IHooks.afterSwap.selector, totalFee.toInt256().toInt128());
    }

    function _validateHookData(bytes calldata hookData) private pure {
        if (hookData.length != 0) revert UnexpectedHookData(hookData.length);
    }

    function _verifySpecifiedNativeDelta(bytes32 poolId, SwapParams calldata params, BalanceDelta delta) private view {
        uint256 requestedNativeAmount = _absolute(params.amountSpecified);
        uint16 appliedFeeBps = FadeDecayFeeMath.feeBpsAt(poolFeeConfig[poolId].launchTimestamp, block.timestamp);
        uint256 expectedTotalFee =
            _totalFeeForNativeAmount(requestedNativeAmount, appliedFeeBps, params.amountSpecified > 0);
        uint256 expectedNativePoolAmount = params.amountSpecified > 0
            ? requestedNativeAmount + expectedTotalFee
            : requestedNativeAmount - expectedTotalFee;
        uint256 actualNativePoolAmount = _absolute(int256(delta.amount0()));
        if (actualNativePoolAmount != expectedNativePoolAmount) {
            revert PartialFillUnsupported(expectedNativePoolAmount, actualNativePoolAmount);
        }
    }

    function _totalFeeForNativeAmount(uint256 nativeAmount, uint16 feeBps, bool amountIsNet)
        private
        pure
        returns (uint256 totalFee)
    {
        (uint256 creatorFee, uint256 programmableFee) = amountIsNet
            ? FadeDecayFeeMath.feesForNet(nativeAmount, feeBps)
            : FadeDecayFeeMath.feesForGross(nativeAmount, feeBps);
        return creatorFee + programmableFee;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        NATIVE.settle(poolManager, address(this), amount, true);
        NATIVE.take(poolManager, recipient, amount, false);
        return "";
    }

    function _accrue(
        bytes32 poolId,
        PoolFeeConfig storage config,
        address sender,
        bool isBuy,
        uint16 appliedFeeBps,
        uint256 grossNativeAmount,
        uint256 creatorFee,
        uint256 programmableFee
    ) private {
        config.creatorFeesAccrued += creatorFee;
        programmableFeesAccrued += programmableFee;
        totalNativeFeesAccrued += creatorFee + programmableFee;
        emit NativeSwapFeesAccrued(poolId, sender, isBuy, appliedFeeBps, grossNativeAmount, creatorFee, programmableFee);
    }

    function _chargeNative(bytes32 poolId, address sender, uint256 nativeAmount, bool amountIsNet, bool isBuy)
        private
        returns (uint256 totalFee)
    {
        PoolFeeConfig storage config = poolFeeConfig[poolId];
        uint16 appliedFeeBps = FadeDecayFeeMath.feeBpsAt(config.launchTimestamp, block.timestamp);
        (uint256 creatorFee, uint256 programmableFee) = amountIsNet
            ? FadeDecayFeeMath.feesForNet(nativeAmount, appliedFeeBps)
            : FadeDecayFeeMath.feesForGross(nativeAmount, appliedFeeBps);
        totalFee = creatorFee + programmableFee;
        if (totalFee == 0) return 0;

        _accrue(
            poolId,
            config,
            sender,
            isBuy,
            appliedFeeBps,
            nativeAmount + (amountIsNet ? totalFee : 0),
            creatorFee,
            programmableFee
        );
        NATIVE.take(poolManager, address(this), totalFee, true);
    }

    function _redeemNative(address recipient, uint256 amount) private {
        bytes memory result = poolManager.unlock(abi.encode(recipient, amount));
        if (result.length != 0) revert UnexpectedUnlockResult();
    }

    function _registeredConfig(PoolKey calldata key) private view returns (PoolFeeConfig storage config) {
        _validatePoolShape(key);
        bytes32 poolId = PoolId.unwrap(key.toId());
        config = poolFeeConfig[poolId];
        if (!config.registered) revert PoolNotRegistered(poolId);
    }

    function _registeredPoolId(PoolKey calldata key) private view returns (bytes32 poolId) {
        _validatePoolShape(key);
        poolId = PoolId.unwrap(key.toId());
        if (!poolFeeConfig[poolId].registered) revert PoolNotRegistered(poolId);
    }

    function _validatePoolShape(PoolKey calldata key) private view {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 != address(0) || currency1 == address(0)) {
            revert InvalidCurrencyOrder(currency0, currency1);
        }
        if (address(key.hooks) != address(this)) revert InvalidHook(address(key.hooks), address(this));
        if (key.fee != LP_FEE_PIPS) revert InvalidLpFee(key.fee, LP_FEE_PIPS);
        if (key.tickSpacing != TICK_SPACING) revert InvalidTickSpacing(key.tickSpacing, TICK_SPACING);
    }

    function _recordedTokenCreator(address token) private view returns (address recordedCreator) {
        if (token.code.length == 0) revert UnrecognizedToken(token);
        try ICreatorToken(token).creator() returns (address creator) {
            recordedCreator = creator;
        } catch {
            revert UnrecognizedToken(token);
        }
        if (recordedCreator == address(0)) revert UnrecognizedToken(token);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        if (value >= 0) return value.toUint256();
        return (-(value + 1)).toUint256() + 1;
    }
}
