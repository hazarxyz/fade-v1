// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { Constants } from "@uniswap/universal-router/contracts/libraries/Constants.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ActionConstants } from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { PathKey } from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import { V4Quoter } from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

interface IFadeUniversalRouterV4 {
    error ExecutionFailed(uint256 commandIndex, bytes message);
    error TransactionDeadlinePassed();

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

struct FadeUniversalRouterParameters {
    address permit2;
    address weth9;
    address v2Factory;
    address v3Factory;
    bytes32 pairInitCodeHash;
    bytes32 poolInitCodeHash;
    address v4PoolManager;
    address v3NFTPositionManager;
    address v4PositionManager;
    address spokePool;
}

library FadeV4Planner {
    struct ExactInputMultihop {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    function exactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        Currency currencyIn,
        Currency currencyOut
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(currencyIn, uint256(ActionConstants.OPEN_DELTA), true);
        params[2] = abi.encode(currencyOut, ActionConstants.MSG_SENDER, uint256(0));
        return _route(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)), params
        );
    }

    function exactOutputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 amountInMaximum,
        Currency currencyIn,
        Currency currencyOut,
        bool refundNative
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(currencyIn, uint256(ActionConstants.OPEN_DELTA), true);
        params[2] = abi.encode(currencyOut, ActionConstants.MSG_SENDER, uint256(amountOut));
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](refundNative ? 2 : 1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)), params
        );
        if (refundNative) {
            commands = abi.encodePacked(commands, uint8(Commands.SWEEP));
            inputs[1] = abi.encode(Constants.ETH, ActionConstants.MSG_SENDER, uint256(0));
        }
    }

    function exactInput(
        Currency currencyIn,
        PathKey[] memory path,
        uint128 amountIn,
        uint128 amountOutMinimum,
        Currency currencyOut
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputMultihop({
                currencyIn: currencyIn,
                path: path,
                minHopPriceX36: new uint256[](0),
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum
            })
        );
        params[1] = abi.encode(currencyIn, uint256(ActionConstants.OPEN_DELTA), true);
        params[2] = abi.encode(currencyOut, ActionConstants.MSG_SENDER, uint256(0));
        return
            _route(abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE), uint8(Actions.TAKE)), params);
    }

    function _route(bytes memory actions, bytes[] memory params)
        private
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}

abstract contract FadeUniversalRouterFixture {
    string internal constant UNIVERSAL_ROUTER_ARTIFACT =
        "node_modules/@uniswap/universal-router/artifacts/contracts/UniversalRouter.sol/UniversalRouter.json";

    IFadeUniversalRouterV4 internal universalRouter;
    IV4Quoter internal v4Quoter;
    address internal permit2;

    function _bindFadeUniversalRouter(address router, address permit2_, IPoolManager manager) internal {
        universalRouter = IFadeUniversalRouterV4(router);
        permit2 = permit2_;
        v4Quoter = new V4Quoter(manager);
    }

    function _universalRouterConstructorArgs(IPoolManager manager, address permit2_, address positionManager)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            FadeUniversalRouterParameters({
                permit2: permit2_,
                weth9: address(0x000000000000000000000000000000000000bEEF),
                v2Factory: address(0),
                v3Factory: address(0),
                pairInitCodeHash: bytes32(0),
                poolInitCodeHash: bytes32(0),
                v4PoolManager: address(manager),
                v3NFTPositionManager: address(0),
                v4PositionManager: positionManager,
                spokePool: address(0)
            })
        );
    }

    function _quoteExactInput(PoolKey memory key, bool zeroForOne, uint128 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (amountOut,) = v4Quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: bytes("")
            })
        );
    }

    function _quoteExactOutput(PoolKey memory key, bool zeroForOne, uint128 amountOut)
        internal
        returns (uint256 amountIn)
    {
        (amountIn,) = v4Quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountOut, hookData: bytes("")
            })
        );
    }

    function _approveFadePermit2(address token) internal {
        IAllowanceTransfer(permit2).approve(token, address(universalRouter), type(uint160).max, type(uint48).max);
    }
}
