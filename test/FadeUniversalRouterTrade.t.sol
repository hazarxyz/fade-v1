// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { UERC20Factory } from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import { UERC20Metadata } from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PositionManager } from "@uniswap/v4-periphery/src/PositionManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PathKey } from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { FadeDecayFeeHookFactoryV1 } from "../src/FadeDecayFeeHookFactoryV1.sol";
import { FadeDecayFeeHookV1 } from "../src/FadeDecayFeeHookV1.sol";
import { FadeLaunchV1 } from "../src/FadeLaunchV1.sol";
import { LockedPositionFeeForwarderFactoryV1 } from "../src/LockedPositionFeeForwarderFactoryV1.sol";
import { FadeUniversalRouterFixture, FadeV4Planner, IFadeUniversalRouterV4 } from "./helpers/FadeUniversalRouterV4.sol";

contract FadeBridgeToken is ERC20 {
    constructor() ERC20("FADE Bridge Fixture", "FBRIDGE") { }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract FadeUniversalRouterTradeTest is Deployers, FadeUniversalRouterFixture {
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    address internal constant CANONICAL_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant CANONICAL_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    uint256 internal constant INITIAL_BUY = 0.0006 ether;
    uint16 internal constant SLIPPAGE_BPS = 50;

    IPositionManager internal positionManager;
    FadeDecayFeeHookFactoryV1 internal hookFactory;
    FadeDecayFeeHookV1 internal feeHook;
    FadeLaunchV1 internal launcher;
    PoolKey internal fadeKey;
    address internal token;
    FadeBridgeToken internal bridgeToken;
    bytes32 internal poolId;
    bytes32 internal hookSalt;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(18_000_000);
        vm.setBlockhash(block.number - 1, keccak256("fade-local-v4-reference-block"));
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), CANONICAL_POOL_MANAGER);
        manager = IPoolManager(CANONICAL_POOL_MANAGER);
        deployCodeTo(
            "PositionManager.sol:PositionManager",
            abi.encode(manager, address(0), uint256(0), address(0), address(0)),
            CANONICAL_POSITION_MANAGER
        );
        positionManager = IPositionManager(CANONICAL_POSITION_MANAGER);

        UERC20Factory tokenFactory = new UERC20Factory();
        hookFactory = new FadeDecayFeeHookFactoryV1();
        LockedPositionFeeForwarderFactoryV1 forwarderFactory = new LockedPositionFeeForwarderFactoryV1(positionManager);
        (, hookSalt) = HookMiner.find(
            address(hookFactory),
            hookFactory.REQUIRED_HOOK_FLAGS(),
            type(FadeDecayFeeHookV1).creationCode,
            abi.encode(manager)
        );
        feeHook = hookFactory.deploy(hookSalt, manager);
        launcher = new FadeLaunchV1(manager, positionManager, tokenFactory, feeHook, forwarderFactory);

        FadeLaunchV1.LaunchResult memory result = launcher.launch{ value: INITIAL_BUY }(
            FadeLaunchV1.LaunchParameters({
                name: "FADE Router Fixture",
                symbol: "FADER",
                creatorSalt: keccak256("fade-universal-router-fixture"),
                metadata: UERC20Metadata({
                    description: "FADE Universal Router evidence fixture", website: "", image: "", extraData: bytes("")
                })
            })
        );
        token = result.token;
        poolId = result.poolId;
        fadeKey = launcher.poolKey(token);
        _initializeBridgePool();

        address permit2Contract = vm.deployCode("PinnedPermit2Artifact.sol:PinnedPermit2Artifact");
        address router = vm.deployCode(
            UNIVERSAL_ROUTER_ARTIFACT,
            _universalRouterConstructorArgs(manager, permit2Contract, address(positionManager))
        );
        _bindFadeUniversalRouter(router, permit2Contract, manager);
        IERC20(token).approve(permit2Contract, type(uint256).max);
        _approveFadePermit2(token);
        vm.deal(address(this), 100 ether);
    }

    function test_discover_trade_profile() public {
        bytes memory creationCode = type(FadeDecayFeeHookV1).creationCode;
        bytes memory constructorArgs = abi.encode(manager);
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        emit log_named_uint("chainId", block.chainid);
        emit log_named_uint("blockNumber", block.number - 1);
        emit log_named_bytes32("blockHash", blockhash(block.number - 1));
        emit log_named_uint("blockTimestamp", block.timestamp);
        emit log_named_address("testAccount", address(this));
        emit log_named_address("poolManager", address(manager));
        emit log_named_address("positionManager", address(positionManager));
        emit log_named_address("hookFactory", address(hookFactory));
        emit log_named_address("hook", address(feeHook));
        emit log_named_address("token", token);
        emit log_named_bytes32("poolId", poolId);
        emit log_named_address("router", address(universalRouter));
        emit log_named_address("quoter", address(v4Quoter));
        emit log_named_address("permit2", permit2);
        emit log_named_bytes32("poolManagerCodehash", address(manager).codehash);
        emit log_named_bytes32("routerCodehash", address(universalRouter).codehash);
        emit log_named_bytes32("quoterCodehash", address(v4Quoter).codehash);
        emit log_named_bytes32("permit2Codehash", permit2.codehash);
        emit log_named_bytes32("creationCodeSha256", sha256(creationCode));
        emit log_named_bytes32("constructorArgsSha256", sha256(constructorArgs));
        emit log_named_bytes32("initCodeSha256", sha256(initCode));
        emit log_named_bytes32("salt", hookSalt);
        emit log_named_bytes32("saltSha256", sha256(abi.encodePacked(hookSalt)));
        emit log_named_uint("runtimeByteLength", address(feeHook).code.length);
        emit log_named_bytes32("runtimeCodeSha256", sha256(address(feeHook).code));
    }

    function test_execute_multihop_preserves_per_hop_hook_data() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(token),
            fee: fadeKey.fee,
            tickSpacing: fadeKey.tickSpacing,
            hooks: feeHook,
            hookData: bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(bridgeToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0)),
            hookData: hex"fade"
        });
        uint128 amountIn = uint128(0.000_001 ether);
        uint256 bridgeBefore = bridgeToken.balanceOf(address(this));
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactInput(
            CurrencyLibrary.ADDRESS_ZERO, path, amountIn, 1, Currency.wrap(address(bridgeToken))
        );
        universalRouter.execute{ value: amountIn }(commands, inputs, block.timestamp + 300);
        assertGt(bridgeToken.balanceOf(address(this)), bridgeBefore);
        _assertRouterClean();
    }

    function test_quote_zero_for_one_exact_input() public {
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 quoted = _quoteExactInput(fadeKey, true, uint128(0.01 ether));
        assertGt(quoted, 0);
        _assertStateUnchanged(nativeBefore, tokenBefore, feesBefore);
        _emitQuoteDiscovery("zero-for-one-exact-input", 0.01 ether, quoted, nativeBefore, tokenBefore, feesBefore);
    }

    function test_quote_zero_for_one_exact_output() public {
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 quoted = _quoteExactOutput(fadeKey, true, uint128(1000 ether));
        assertGt(quoted, 0);
        _assertStateUnchanged(nativeBefore, tokenBefore, feesBefore);
        _emitQuoteDiscovery("zero-for-one-exact-output", 1000 ether, quoted, nativeBefore, tokenBefore, feesBefore);
    }

    function test_quote_one_for_zero_exact_input() public {
        uint128 amountIn = (IERC20(token).balanceOf(address(this)) / 20).toUint128();
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 quoted = _quoteExactInput(fadeKey, false, amountIn);
        assertGt(quoted, 0);
        _assertStateUnchanged(nativeBefore, tokenBefore, feesBefore);
        _emitQuoteDiscovery("one-for-zero-exact-input", amountIn, quoted, nativeBefore, tokenBefore, feesBefore);
    }

    function test_quote_one_for_zero_exact_output() public {
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 quoted = _quoteExactOutput(fadeKey, false, uint128(0.000_05 ether));
        assertGt(quoted, 0);
        _assertStateUnchanged(nativeBefore, tokenBefore, feesBefore);
        _emitQuoteDiscovery("one-for-zero-exact-output", 0.000_05 ether, quoted, nativeBefore, tokenBefore, feesBefore);
    }

    function test_execute_zero_for_one_exact_input() public {
        uint128 amountIn = uint128(0.01 ether);
        uint256 quote = _quoteExactInput(fadeKey, true, amountIn);
        uint128 minimumOut = (quote * (10_000 - SLIPPAGE_BPS) / 10_000).toUint128();
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactInputSingle(
            fadeKey, true, amountIn, minimumOut, CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token)
        );
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp + 300;
        universalRouter.execute{ value: amountIn }(commands, inputs, deadline);
        assertEq(nativeBefore - address(this).balance, amountIn);
        assertEq(IERC20(token).balanceOf(address(this)) - tokenBefore, quote);
        assertGe(quote, minimumOut);
        _assertRouterClean();
        _emitExecutionDiscovery(
            "zero-for-one-exact-input",
            amountIn,
            quote,
            amountIn,
            quote,
            minimumOut,
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            0
        );
    }

    function test_execute_zero_for_one_exact_output() public {
        uint128 amountOut = uint128(1000 ether);
        uint256 quote = _quoteExactOutput(fadeKey, true, amountOut);
        uint128 maximumIn = ((quote * (10_000 + SLIPPAGE_BPS) + 9999) / 10_000).toUint128();
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactOutputSingle(
            fadeKey, true, amountOut, maximumIn, CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), true
        );
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp + 300;
        universalRouter.execute{ value: maximumIn }(commands, inputs, deadline);
        assertEq(nativeBefore - address(this).balance, quote);
        assertEq(IERC20(token).balanceOf(address(this)) - tokenBefore, amountOut);
        assertGt(uint256(maximumIn) - quote, 0);
        _assertRouterClean();
        _emitExecutionDiscovery(
            "zero-for-one-exact-output",
            amountOut,
            quote,
            quote,
            amountOut,
            maximumIn,
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            uint256(maximumIn) - quote
        );
    }

    function test_execute_one_for_zero_exact_input() public {
        uint128 amountIn = (IERC20(token).balanceOf(address(this)) / 20).toUint128();
        uint256 quote = _quoteExactInput(fadeKey, false, amountIn);
        uint128 minimumOut = (quote * (10_000 - SLIPPAGE_BPS) / 10_000).toUint128();
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactInputSingle(
            fadeKey, false, amountIn, minimumOut, Currency.wrap(token), CurrencyLibrary.ADDRESS_ZERO
        );
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp + 300;
        universalRouter.execute(commands, inputs, deadline);
        assertEq(tokenBefore - IERC20(token).balanceOf(address(this)), amountIn);
        assertEq(address(this).balance - nativeBefore, quote);
        assertGe(quote, minimumOut);
        _assertRouterClean();
        _emitExecutionDiscovery(
            "one-for-zero-exact-input",
            amountIn,
            quote,
            amountIn,
            quote,
            minimumOut,
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            0
        );
    }

    function test_execute_one_for_zero_exact_output() public {
        uint128 amountOut = uint128(0.000_05 ether);
        uint256 quote = _quoteExactOutput(fadeKey, false, amountOut);
        uint128 maximumIn = ((quote * (10_000 + SLIPPAGE_BPS) + 9999) / 10_000).toUint128();
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactOutputSingle(
            fadeKey, false, amountOut, maximumIn, Currency.wrap(token), CurrencyLibrary.ADDRESS_ZERO, false
        );
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp + 300;
        universalRouter.execute(commands, inputs, deadline);
        assertEq(tokenBefore - IERC20(token).balanceOf(address(this)), quote);
        assertEq(address(this).balance - nativeBefore, amountOut);
        assertLe(quote, maximumIn);
        _assertRouterClean();
        _emitExecutionDiscovery(
            "one-for-zero-exact-output",
            amountOut,
            quote,
            quote,
            amountOut,
            maximumIn,
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            0
        );
    }

    function test_reject_expired_deadline_revert() public {
        uint128 amountIn = uint128(0.01 ether);
        uint256 quote = _quoteExactInput(fadeKey, true, amountIn);
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactInputSingle(
            fadeKey, true, amountIn, quote.toUint128(), CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token)
        );
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp - 1;
        bytes memory reason;
        try universalRouter.execute{ value: amountIn }(commands, inputs, deadline) {
            fail();
        } catch (bytes memory observedReason) {
            reason = observedReason;
        }
        assertGt(reason.length, 0);
        _assertStateUnchanged(nativeBefore, tokenBefore, feesBefore);
        _emitRejectionDiscovery(
            "expired-deadline-revert",
            "zero-for-one-exact-input",
            address(this),
            amountIn,
            quote,
            quote,
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            reason
        );
    }

    function test_reject_slippage_bound_revert() public {
        uint128 amountIn = uint128(0.01 ether);
        uint256 quote = _quoteExactInput(fadeKey, true, amountIn);
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactInputSingle(
            fadeKey, true, amountIn, (quote + 1).toUint128(), CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token)
        );
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp + 300;
        bytes memory reason;
        try universalRouter.execute{ value: amountIn }(commands, inputs, deadline) {
            fail();
        } catch (bytes memory observedReason) {
            reason = observedReason;
        }
        assertGt(reason.length, 0);
        _assertStateUnchanged(nativeBefore, tokenBefore, feesBefore);
        _emitRejectionDiscovery(
            "slippage-bound-revert",
            "zero-for-one-exact-input",
            address(this),
            amountIn,
            quote,
            quote + 1,
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            reason
        );
    }

    function test_reject_funding_requirement_revert() public {
        address unfunded = makeAddr("fade-unfunded-trader");
        uint128 amountIn = (IERC20(token).balanceOf(address(this)) / 100).toUint128();
        assertTrue(IERC20(token).transfer(unfunded, amountIn));
        uint256 quote = _quoteExactInput(fadeKey, false, amountIn);
        (bytes memory commands, bytes[] memory inputs) = FadeV4Planner.exactInputSingle(
            fadeKey,
            false,
            amountIn,
            (quote * (10_000 - SLIPPAGE_BPS) / 10_000).toUint128(),
            Currency.wrap(token),
            CurrencyLibrary.ADDRESS_ZERO
        );
        uint256 nativeBefore = unfunded.balance;
        uint256 tokenBefore = IERC20(token).balanceOf(unfunded);
        uint256 feesBefore = feeHook.totalNativeFeesAccrued();
        uint256 deadline = block.timestamp + 300;
        bytes memory reason;
        vm.prank(unfunded);
        try universalRouter.execute(commands, inputs, deadline) {
            fail();
        } catch (bytes memory observedReason) {
            reason = observedReason;
        }
        assertGt(reason.length, 0);
        assertEq(unfunded.balance, nativeBefore);
        assertEq(IERC20(token).balanceOf(unfunded), tokenBefore);
        assertEq(feeHook.totalNativeFeesAccrued(), feesBefore);
        _emitRejectionDiscovery(
            "funding-requirement-revert",
            "one-for-zero-exact-input",
            unfunded,
            amountIn,
            quote,
            (quote * (10_000 - SLIPPAGE_BPS) / 10_000).toUint128(),
            deadline,
            nativeBefore,
            tokenBefore,
            feesBefore,
            reason
        );
    }

    function _emitQuoteDiscovery(
        string memory modeId,
        uint256 amountSpecified,
        uint256 amountQuoted,
        uint256 nativeBefore,
        uint256 tokenBefore,
        uint256 feesBefore
    ) private {
        string memory objectKey = string.concat("fade-quote-", modeId);
        vm.serializeString(objectKey, "kind", "quote");
        vm.serializeString(objectKey, "modeId", modeId);
        vm.serializeAddress(objectKey, "sender", address(this));
        vm.serializeAddress(objectKey, "recipient", address(this));
        vm.serializeUint(objectKey, "amountSpecified", amountSpecified);
        vm.serializeUint(objectKey, "amountQuoted", amountQuoted);
        vm.serializeUint(objectKey, "deadline", block.timestamp + 300);
        vm.serializeUint(objectKey, "nativeBefore", nativeBefore);
        vm.serializeUint(objectKey, "nativeAfter", address(this).balance);
        vm.serializeUint(objectKey, "tokenBefore", tokenBefore);
        vm.serializeUint(objectKey, "tokenAfter", IERC20(token).balanceOf(address(this)));
        vm.serializeUint(objectKey, "feesBefore", feesBefore);
        string memory json = vm.serializeUint(objectKey, "feesAfter", feeHook.totalNativeFeesAccrued());
        emit log_string(string.concat("FADE_TRADE_DISCOVERY_V1:", json));
    }

    function _emitExecutionDiscovery(
        string memory modeId,
        uint256 amountSpecified,
        uint256 amountQuoted,
        uint256 amountIn,
        uint256 amountOut,
        uint256 slippageGuardAmount,
        uint256 deadline,
        uint256 nativeBefore,
        uint256 tokenBefore,
        uint256 feesBefore,
        uint256 refundAmount
    ) private {
        string memory objectKey = string.concat("fade-execute-", modeId);
        vm.serializeString(objectKey, "kind", "execution");
        vm.serializeString(objectKey, "modeId", modeId);
        vm.serializeAddress(objectKey, "sender", address(this));
        vm.serializeAddress(objectKey, "recipient", address(this));
        vm.serializeUint(objectKey, "amountSpecified", amountSpecified);
        vm.serializeUint(objectKey, "amountQuoted", amountQuoted);
        vm.serializeUint(objectKey, "amountIn", amountIn);
        vm.serializeUint(objectKey, "amountOut", amountOut);
        vm.serializeUint(objectKey, "slippageGuardAmount", slippageGuardAmount);
        vm.serializeUint(objectKey, "deadline", deadline);
        vm.serializeUint(objectKey, "nativeBefore", nativeBefore);
        vm.serializeUint(objectKey, "nativeAfter", address(this).balance);
        vm.serializeUint(objectKey, "tokenBefore", tokenBefore);
        vm.serializeUint(objectKey, "tokenAfter", IERC20(token).balanceOf(address(this)));
        vm.serializeUint(objectKey, "feesBefore", feesBefore);
        vm.serializeUint(objectKey, "feesAfter", feeHook.totalNativeFeesAccrued());
        string memory json = vm.serializeUint(objectKey, "refundAmount", refundAmount);
        emit log_string(string.concat("FADE_TRADE_DISCOVERY_V1:", json));
    }

    function _emitRejectionDiscovery(
        string memory scenario,
        string memory modeId,
        address sender,
        uint256 amountSpecified,
        uint256 amountQuoted,
        uint256 slippageGuardAmount,
        uint256 deadline,
        uint256 nativeBefore,
        uint256 tokenBefore,
        uint256 feesBefore,
        bytes memory reason
    ) private {
        string memory objectKey = string.concat("fade-reject-", scenario);
        vm.serializeString(objectKey, "kind", "rejection");
        vm.serializeString(objectKey, "scenario", scenario);
        vm.serializeString(objectKey, "modeId", modeId);
        vm.serializeAddress(objectKey, "sender", sender);
        vm.serializeAddress(objectKey, "recipient", sender);
        vm.serializeUint(objectKey, "amountSpecified", amountSpecified);
        vm.serializeUint(objectKey, "amountQuoted", amountQuoted);
        vm.serializeUint(objectKey, "slippageGuardAmount", slippageGuardAmount);
        vm.serializeUint(objectKey, "deadline", deadline);
        vm.serializeUint(objectKey, "nativeBefore", nativeBefore);
        vm.serializeUint(objectKey, "nativeAfter", sender.balance);
        vm.serializeUint(objectKey, "tokenBefore", tokenBefore);
        vm.serializeUint(objectKey, "tokenAfter", IERC20(token).balanceOf(sender));
        vm.serializeUint(objectKey, "feesBefore", feesBefore);
        vm.serializeUint(objectKey, "feesAfter", feeHook.totalNativeFeesAccrued());
        string memory json = vm.serializeBytes32(objectKey, "revertDataSha256", sha256(reason));
        emit log_string(string.concat("FADE_TRADE_DISCOVERY_V1:", json));
    }

    function _assertStateUnchanged(uint256 nativeBefore, uint256 tokenBefore, uint256 feesBefore) private view {
        assertEq(address(this).balance, nativeBefore);
        assertEq(IERC20(token).balanceOf(address(this)), tokenBefore);
        assertEq(feeHook.totalNativeFeesAccrued(), feesBefore);
        _assertRouterClean();
    }

    function _assertRouterClean() private view {
        assertEq(address(universalRouter).balance, 0);
        assertEq(IERC20(token).balanceOf(address(universalRouter)), 0);
        assertEq(bridgeToken.balanceOf(address(universalRouter)), 0);
        assertEq(manager.currencyDelta(address(universalRouter), CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(manager.currencyDelta(address(universalRouter), Currency.wrap(token)), 0);
        assertEq(manager.currencyDelta(address(universalRouter), Currency.wrap(address(bridgeToken))), 0);
    }

    function _initializeBridgePool() private {
        bridgeToken = new FadeBridgeToken();
        bridgeToken.mint(address(this), 1_000_000_000 ether);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        IERC20(token).approve(address(modifyLiquidityRouter), type(uint256).max);
        bridgeToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        Currency fadeCurrency = Currency.wrap(token);
        Currency bridgeCurrency = Currency.wrap(address(bridgeToken));
        (Currency first, Currency second) =
            token < address(bridgeToken) ? (fadeCurrency, bridgeCurrency) : (bridgeCurrency, fadeCurrency);
        (PoolKey memory bridgeKey,) = initPool(first, second, IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            bridgeKey,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1_000_000 ether, salt: 0 }),
            bytes("")
        );
    }
}
