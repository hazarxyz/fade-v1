// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ITimelockedPositionRecipient
} from "@uniswap/liquidity-launcher/src/interfaces/ITimelockedPositionRecipient.sol";
import { PositionFeesForwarder } from "@uniswap/liquidity-launcher/src/periphery/PositionFeesForwarder.sol";
import { UERC20Factory } from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import { UERC20Metadata } from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import { UERC20 } from "@uniswap/uerc20-factory/src/tokens/UERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PositionManager } from "@uniswap/v4-periphery/src/PositionManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { FadeDecayFeeHookFactoryV1 } from "../src/FadeDecayFeeHookFactoryV1.sol";
import { FadeDecayFeeHookV1 } from "../src/FadeDecayFeeHookV1.sol";
import { LockedPositionFeeForwarderFactoryV1 } from "../src/LockedPositionFeeForwarderFactoryV1.sol";
import { FadeLaunchV1 } from "../src/FadeLaunchV1.sol";

contract FadeLaunchV1Test is Deployers {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    struct OfficialMetadataV2 {
        string description;
        string website;
        string image;
        bytes extraData;
    }

    struct OfficialLaunchParametersV2 {
        string name;
        string symbol;
        bytes32 creatorSalt;
        OfficialMetadataV2 metadata;
    }

    address internal constant CANONICAL_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant CANONICAL_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    bytes32 internal constant CREATOR_SALT = keccak256("fade-launch-fixture");
    uint256 internal constant MIN_INITIAL_BUY_WEI = 0.0006 ether;

    IPositionManager internal positionManager;
    UERC20Factory internal tokenFactory;
    FadeDecayFeeHookFactoryV1 internal hookFactory;
    FadeDecayFeeHookV1 internal feeHook;
    LockedPositionFeeForwarderFactoryV1 internal positionForwarderFactory;
    FadeLaunchV1 internal launcher;

    address internal creator;
    address internal programmableTreasury;
    address internal tokenAddress;
    bytes32 internal effectiveGraffiti;

    function setUp() public {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), CANONICAL_POOL_MANAGER);
        manager = IPoolManager(CANONICAL_POOL_MANAGER);
        deployCodeTo(
            "PositionManager.sol:PositionManager",
            abi.encode(manager, address(0), uint256(0), address(0), address(0)),
            CANONICAL_POSITION_MANAGER
        );
        positionManager = IPositionManager(CANONICAL_POSITION_MANAGER);

        tokenFactory = new UERC20Factory();
        hookFactory = new FadeDecayFeeHookFactoryV1();
        positionForwarderFactory = new LockedPositionFeeForwarderFactoryV1(positionManager);
        feeHook = _deployHook();
        programmableTreasury = feeHook.PROGRAMMABLE_TREASURY();
        launcher = new FadeLaunchV1(manager, positionManager, tokenFactory, feeHook, positionForwarderFactory);

        creator = makeAddr("fadeLaunchCreator");
        vm.deal(creator, 10 ether);
        (tokenAddress, effectiveGraffiti) =
            launcher.predictTokenAddress("FADE Launch Token", "FADE", creator, CREATOR_SALT);
    }

    function testSimulation_launchesLockedPositionAndExecutesMinimumCreatorBuy() public {
        uint256 creatorEthBefore = creator.balance;
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PositionFeesForwarder forwarder = PositionFeesForwarder(payable(result.positionRecipient));

        assertEq(result.token, tokenAddress);
        assertEq(result.positionTokenId, positionManager.nextTokenId() - 1);
        assertEq(result.poolId, PoolId.unwrap(key.toId()));
        assertEq(result.launchHash, launcher.launchHashOf(result.token));
        assertTrue(result.launchHash != bytes32(0));

        assertEq(IERC20(result.token).totalSupply(), launcher.TOKEN_SUPPLY());
        assertEq(result.initialBuyNativeAmount, MIN_INITIAL_BUY_WEI);
        assertEq(IERC20(result.token).balanceOf(creator), result.initialBuyTokenAmount);
        assertGt(result.initialBuyTokenAmount, 0);
        assertEq(IERC20(result.token).balanceOf(address(launcher)), 0);
        assertEq(IERC20(result.token).balanceOf(address(positionManager)), 0);
        assertEq(IERC20(result.token).balanceOf(result.positionRecipient), result.lockedTokenDust);
        assertEq(result.tokenLiquidityAmount + result.lockedTokenDust, launcher.TOKEN_SUPPLY());
        assertGt(result.tokenLiquidityAmount, 0);
        assertEq(creator.balance, creatorEthBefore - MIN_INITIAL_BUY_WEI);
        assertEq(address(launcher).balance, 0);

        assertEq(UERC20(result.token).creator(), address(launcher));
        assertEq(UERC20(result.token).graffiti(), effectiveGraffiti);
        assertEq(positionManager.getPositionLiquidity(result.positionTokenId) > 0, true);
        assertEq(IERC721(address(positionManager)).ownerOf(result.positionTokenId), result.positionRecipient);

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        assertLt(sqrtPriceX96, TickMath.getSqrtPriceAtTick(launcher.INITIAL_TICK()));
        assertLt(tick, launcher.INITIAL_TICK());
        assertGt(manager.getLiquidity(key.toId()), 0);
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, 200);
        assertEq(address(key.hooks), address(feeHook));

        (address feeCreator, address registrar, uint64 launchTimestamp, bool registered, uint256 accrued) =
            feeHook.poolFeeConfig(result.poolId);
        assertEq(feeCreator, creator);
        assertEq(registrar, address(launcher));
        assertEq(launchTimestamp, block.timestamp);
        assertTrue(registered);
        assertEq(accrued, 17_400_000_000_000);
        assertEq(feeHook.programmableFeesAccrued(), 600_000_000_000);

        assertEq(forwarder.operator(), address(0));
        assertEq(forwarder.timelockBlockNumber(), type(uint256).max);
        assertEq(forwarder.feeRecipient(), creator);
        assertTrue(positionForwarderFactory.isFactoryForwarder(result.positionRecipient));

        vm.expectRevert(ITimelockedPositionRecipient.Timelocked.selector);
        forwarder.approveOperator();
        vm.expectRevert();
        vm.prank(creator);
        IERC721(address(positionManager)).transferFrom(result.positionRecipient, creator, result.positionTokenId);
    }

    function test_creatorCanChooseALargerAtomicDevBuy() public {
        FadeLaunchV1.LaunchResult memory minimumResult = _launch();
        uint256 largerBuy = 0.002 ether;
        FadeLaunchV1.LaunchParameters memory parameters = _parametersFor(keccak256("larger-dev-buy"));

        uint256 creatorEthBefore = creator.balance;
        vm.prank(creator);
        FadeLaunchV1.LaunchResult memory largerResult = launcher.launch{ value: largerBuy }(parameters);

        assertEq(largerResult.initialBuyNativeAmount, largerBuy);
        assertGt(largerResult.initialBuyTokenAmount, minimumResult.initialBuyTokenAmount);
        assertEq(IERC20(largerResult.token).balanceOf(creator), largerResult.initialBuyTokenAmount);
        assertEq(creator.balance, creatorEthBefore - largerBuy);
        assertEq(address(launcher).balance, 0);
    }

    function test_launchRoundTripsNonemptyOfficialExtraDataWithoutAbiGarbage() public {
        bytes memory expectedExtraData = hex"0102030405aabbcc";
        OfficialLaunchParametersV2 memory parameters = OfficialLaunchParametersV2({
            name: "Metadata Fixture",
            symbol: "META",
            creatorSalt: keccak256("official-metadata-v2-fixture"),
            metadata: OfficialMetadataV2({
                description: "Official UERC20 metadata fixture",
                website: "https://programmable.family",
                image: "ipfs://programmable-metadata-fixture",
                extraData: expectedExtraData
            })
        });
        bytes4 officialLaunchSelector =
            bytes4(keccak256("launch((string,string,bytes32,(string,string,string,bytes)))"));

        vm.prank(creator);
        (bool launchSucceeded, bytes memory launchData) = address(launcher).call{ value: MIN_INITIAL_BUY_WEI }(
            abi.encodeWithSelector(officialLaunchSelector, parameters)
        );
        assertTrue(launchSucceeded, "official extraData ABI launch reverted");

        FadeLaunchV1.LaunchResult memory result = abi.decode(launchData, (FadeLaunchV1.LaunchResult));
        (bool metadataSucceeded, bytes memory metadataData) =
            result.token.staticcall(abi.encodeWithSignature("metadata()"));
        assertTrue(metadataSucceeded, "metadata read reverted");

        (string memory description, string memory website, string memory image, bytes memory actualExtraData) =
            abi.decode(metadataData, (string, string, string, bytes));
        assertEq(description, parameters.metadata.description);
        assertEq(website, parameters.metadata.website);
        assertEq(image, parameters.metadata.image);
        assertEq(actualExtraData.length, expectedExtraData.length);
        assertEq(keccak256(actualExtraData), keccak256(expectedExtraData));
    }

    function test_acceptsEveryMetadataFieldAtItsExactUtf8ByteLimit() public {
        FadeLaunchV1.LaunchParameters memory parameters = _parameters();
        parameters.name = _asciiBytes(launcher.MAX_TOKEN_NAME_BYTES(), "n");
        parameters.symbol = _asciiBytes(launcher.MAX_TOKEN_SYMBOL_BYTES(), "S");
        parameters.metadata.description = _asciiBytes(launcher.MAX_TOKEN_DESCRIPTION_BYTES(), "d");
        parameters.metadata.website = _asciiBytes(launcher.MAX_METADATA_URL_BYTES(), "w");
        parameters.metadata.image = _asciiBytes(launcher.MAX_METADATA_URL_BYTES(), "i");
        parameters.metadata.extraData = bytes(_asciiBytes(launcher.MAX_SOCIAL_EXTRA_DATA_BYTES(), "x"));

        vm.prank(creator);
        FadeLaunchV1.LaunchResult memory result = launcher.launch{ value: MIN_INITIAL_BUY_WEI }(parameters);

        (string memory description, string memory website, string memory image, bytes memory extraData) =
            UERC20(result.token).metadata();
        assertEq(bytes(description).length, launcher.MAX_TOKEN_DESCRIPTION_BYTES());
        assertEq(bytes(website).length, launcher.MAX_METADATA_URL_BYTES());
        assertEq(bytes(image).length, launcher.MAX_METADATA_URL_BYTES());
        assertEq(extraData.length, launcher.MAX_SOCIAL_EXTRA_DATA_BYTES());
        assertTrue(launcher.launchHashOf(result.token) != bytes32(0));
    }

    function test_rejectsOverlongDirectCallMetadataBeforeRegistryWrite() public {
        FadeLaunchV1.LaunchParameters memory parameters = _parameters();

        parameters.name = _asciiBytes(launcher.MAX_TOKEN_NAME_BYTES() + 1, "n");
        _expectMetadataRevert(
            parameters,
            FadeLaunchV1.TokenNameTooLong.selector,
            launcher.MAX_TOKEN_NAME_BYTES() + 1,
            launcher.MAX_TOKEN_NAME_BYTES()
        );

        parameters = _parameters();
        parameters.symbol = _asciiBytes(launcher.MAX_TOKEN_SYMBOL_BYTES() + 1, "S");
        _expectMetadataRevert(
            parameters,
            FadeLaunchV1.TokenSymbolTooLong.selector,
            launcher.MAX_TOKEN_SYMBOL_BYTES() + 1,
            launcher.MAX_TOKEN_SYMBOL_BYTES()
        );

        parameters = _parameters();
        parameters.metadata.description = _asciiBytes(launcher.MAX_TOKEN_DESCRIPTION_BYTES() + 1, "d");
        _expectMetadataRevert(
            parameters,
            FadeLaunchV1.TokenDescriptionTooLong.selector,
            launcher.MAX_TOKEN_DESCRIPTION_BYTES() + 1,
            launcher.MAX_TOKEN_DESCRIPTION_BYTES()
        );

        parameters = _parameters();
        parameters.metadata.website = _asciiBytes(launcher.MAX_METADATA_URL_BYTES() + 1, "w");
        _expectMetadataRevert(
            parameters,
            FadeLaunchV1.MetadataWebsiteTooLong.selector,
            launcher.MAX_METADATA_URL_BYTES() + 1,
            launcher.MAX_METADATA_URL_BYTES()
        );

        parameters = _parameters();
        parameters.metadata.image = _asciiBytes(launcher.MAX_METADATA_URL_BYTES() + 1, "i");
        _expectMetadataRevert(
            parameters,
            FadeLaunchV1.MetadataImageTooLong.selector,
            launcher.MAX_METADATA_URL_BYTES() + 1,
            launcher.MAX_METADATA_URL_BYTES()
        );

        parameters = _parameters();
        parameters.metadata.extraData = bytes(_asciiBytes(launcher.MAX_SOCIAL_EXTRA_DATA_BYTES() + 1, "x"));
        _expectMetadataRevert(
            parameters,
            FadeLaunchV1.MetadataExtraDataTooLong.selector,
            launcher.MAX_SOCIAL_EXTRA_DATA_BYTES() + 1,
            launcher.MAX_SOCIAL_EXTRA_DATA_BYTES()
        );
    }

    function test_initialTickDefinesOnePointThreeFiveEthStartingFdv() public view {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(launcher.INITIAL_TICK());
        uint256 priceDenominator = uint256(sqrtPriceX96) * sqrtPriceX96;
        uint256 startingFdvWei = FullMath.mulDiv(launcher.TOKEN_SUPPLY(), 1 << 192, priceDenominator);

        assertApproxEqAbs(startingFdvWei, 1_355_657_760_817_103_798, 1);
    }

    function test_buyAndSellAccrueOnlyEthFeesForCreatorAndProgrammable() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PoolSwapTest router = new PoolSwapTest(manager);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
        address trader = makeAddr("fadeTrader");
        vm.deal(trader, 10 ether);

        vm.prank(trader);
        router.swap{ value: 0.1 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ""
        );

        uint256 traderTokens = IERC20(result.token).balanceOf(trader);
        assertGt(traderTokens, 0);
        vm.startPrank(trader);
        IERC20(result.token).approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -(traderTokens / 2).toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        vm.stopPrank();

        (,,,, uint256 creatorFees) = feeHook.poolFeeConfig(result.poolId);
        uint256 programmableFees = feeHook.programmableFeesAccrued();
        assertGt(creatorFees, 0);
        assertGt(programmableFees, 0);
        assertEq(
            manager.balanceOf(address(feeHook), CurrencyLibrary.ADDRESS_ZERO.toId()), creatorFees + programmableFees
        );
        assertEq(manager.balanceOf(address(feeHook), Currency.wrap(result.token).toId()), 0);

        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = programmableTreasury.balance;
        vm.prank(makeAddr("claimCaller"));
        feeHook.claimCreatorFees(result.poolId);
        feeHook.claimProgrammableFees();
        assertEq(creator.balance, creatorBefore + creatorFees);
        assertEq(programmableTreasury.balance, treasuryBefore + programmableFees);
    }

    function test_buyExactInputChargesTheCurrentEthFee() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PoolSwapTest router = new PoolSwapTest(manager);
        address trader = makeAddr("buyExactInputTrader");
        vm.deal(trader, 1 ether);
        (uint256 creatorBefore, uint256 programmableBefore) = _accrued(result.poolId);

        vm.prank(trader);
        BalanceDelta delta = router.swap{ value: 0.05 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            ""
        );

        (uint256 creatorAfter, uint256 programmableAfter) = _accrued(result.poolId);
        (uint256 expectedCreator, uint256 expectedProgrammable) =
            feeHook.quoteGrossFees(result.poolId, 0.05 ether, block.timestamp);
        assertEq(uint256(-int256(delta.amount0())), 0.05 ether);
        assertEq(creatorAfter - creatorBefore, expectedCreator);
        assertEq(programmableAfter - programmableBefore, expectedProgrammable);
    }

    function test_nonemptyHookDataRevertsBeforeFeeEffects() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PoolSwapTest router = new PoolSwapTest(manager);
        address trader = makeAddr("nonemptyHookDataTrader");
        vm.deal(trader, 1 ether);
        (uint256 creatorBefore, uint256 programmableBefore) = _accrued(result.poolId);

        vm.prank(trader);
        vm.expectRevert();
        router.swap{ value: 0.05 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            hex"01"
        );

        (uint256 creatorAfter, uint256 programmableAfter) = _accrued(result.poolId);
        assertEq(creatorAfter, creatorBefore);
        assertEq(programmableAfter, programmableBefore);
    }

    function test_buyExactOutputChargesTheCurrentEthFee() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PoolSwapTest router = new PoolSwapTest(manager);
        address trader = makeAddr("buyExactOutputTrader");
        vm.deal(trader, 1 ether);
        uint256 tokenOutput = 1000 ether;
        (uint256 creatorBefore, uint256 programmableBefore) = _accrued(result.poolId);

        vm.prank(trader);
        BalanceDelta delta = router.swap{ value: 1 ether }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: tokenOutput.toInt256(),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            ""
        );

        _assertBuyExactOutputAccounting(result.poolId, delta, tokenOutput, creatorBefore, programmableBefore);
    }

    function test_sellExactInputChargesTheCurrentEthFee() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PoolSwapTest router = new PoolSwapTest(manager);
        uint256 tokenInput = result.initialBuyTokenAmount / 4;
        vm.prank(creator);
        IERC20(result.token).approve(address(router), type(uint256).max);
        (uint256 creatorBefore, uint256 programmableBefore) = _accrued(result.poolId);

        vm.prank(creator);
        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -tokenInput.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            ""
        );

        (uint256 creatorAfter, uint256 programmableAfter) = _accrued(result.poolId);
        uint256 creatorDelta = creatorAfter - creatorBefore;
        uint256 programmableDelta = programmableAfter - programmableBefore;
        uint256 grossNativeOutput = uint256(int256(delta.amount0())) + creatorDelta + programmableDelta;
        (uint256 expectedCreator, uint256 expectedProgrammable) =
            feeHook.quoteGrossFees(result.poolId, grossNativeOutput, block.timestamp);
        assertEq(uint256(-int256(delta.amount1())), tokenInput);
        assertEq(creatorDelta, expectedCreator);
        assertEq(programmableDelta, expectedProgrammable);
    }

    function test_sellExactOutputChargesTheCurrentEthFee() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        PoolKey memory key = launcher.poolKey(result.token);
        PoolSwapTest router = new PoolSwapTest(manager);
        uint256 nativeOutput = 0.000_05 ether;
        vm.prank(creator);
        IERC20(result.token).approve(address(router), type(uint256).max);
        (uint256 creatorBefore, uint256 programmableBefore) = _accrued(result.poolId);

        vm.prank(creator);
        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: nativeOutput.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            ""
        );

        (uint256 creatorAfter, uint256 programmableAfter) = _accrued(result.poolId);
        (uint256 expectedCreator, uint256 expectedProgrammable) =
            feeHook.quoteExactOutputFees(result.poolId, nativeOutput, block.timestamp);
        assertEq(uint256(int256(delta.amount0())), nativeOutput);
        assertEq(creatorAfter - creatorBefore, expectedCreator);
        assertEq(programmableAfter - programmableBefore, expectedProgrammable);
    }

    function test_feeScheduleStartsAtThreePercentAndEndsAtOnePercentAfterOneDay() public {
        FadeLaunchV1.LaunchResult memory result = _launch();
        (,, uint64 launchedAt,,) = feeHook.poolFeeConfig(result.poolId);

        assertEq(feeHook.totalSwapFeeBpsFor(result.poolId, launchedAt), 300);
        assertEq(feeHook.totalSwapFeeBpsFor(result.poolId, launchedAt + 12 hours), 200);
        assertEq(feeHook.totalSwapFeeBpsFor(result.poolId, launchedAt + 24 hours - 1), 101);
        assertEq(feeHook.totalSwapFeeBpsFor(result.poolId, launchedAt + 24 hours), 100);
        assertEq(feeHook.totalSwapFeeBpsFor(result.poolId, launchedAt + 365 days), 100);
    }

    function testDeployment_hookFactoryPermissionsAndDependenciesAreBound() public view {
        assertGt(address(manager).code.length, 0);
        assertGt(address(positionManager).code.length, 0);
        assertGt(address(tokenFactory).code.length, 0);
        assertGt(address(feeHook).code.length, 0);
        assertGt(address(launcher).code.length, 0);
        assertEq(address(feeHook.poolManager()), address(manager));
        assertEq(feeHook.PROGRAMMABLE_TREASURY(), 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c);
        assertEq(uint160(address(feeHook)) & hookFactory.ALL_HOOK_MASK(), hookFactory.REQUIRED_HOOK_FLAGS());
        assertTrue(hookFactory.isFactoryHook(address(feeHook)));
        assertEq(address(launcher.poolManager()), address(manager));
        assertEq(address(launcher.positionManager()), address(positionManager));
        assertEq(address(launcher.feeHook()), address(feeHook));
        assertEq(address(launcher.positionForwarderFactory()), address(positionForwarderFactory));
    }

    function test_rejectsDuplicateTokenLaunch() public {
        _launch();
        vm.expectRevert(abi.encodeWithSelector(FadeLaunchV1.TokenAlreadyExists.selector, tokenAddress));
        vm.prank(creator);
        launcher.launch{ value: MIN_INITIAL_BUY_WEI }(_parameters());
    }

    function test_reusesMatchingPredeployedPermanentPositionRecipient() public {
        bytes32 positionSalt = keccak256(abi.encode("programmable.fade-position.v1", tokenAddress, creator));
        address predicted = address(positionForwarderFactory.deploy(positionSalt, creator));

        FadeLaunchV1.LaunchResult memory result = _launch();
        assertEq(result.positionRecipient, predicted);
        assertEq(IERC721(address(positionManager)).ownerOf(result.positionTokenId), predicted);
    }

    function _deployHook() private returns (FadeDecayFeeHookV1 deployed) {
        (, bytes32 salt) = HookMiner.find(
            address(hookFactory),
            hookFactory.REQUIRED_HOOK_FLAGS(),
            type(FadeDecayFeeHookV1).creationCode,
            abi.encode(manager)
        );
        deployed = hookFactory.deploy(salt, manager);
    }

    function _launch() private returns (FadeLaunchV1.LaunchResult memory result) {
        vm.prank(creator);
        result = launcher.launch{ value: MIN_INITIAL_BUY_WEI }(_parameters());
    }

    function _parameters() private pure returns (FadeLaunchV1.LaunchParameters memory) {
        return _parametersFor(CREATOR_SALT);
    }

    function _parametersFor(bytes32 salt) private pure returns (FadeLaunchV1.LaunchParameters memory parameters) {
        parameters = FadeLaunchV1.LaunchParameters({
            name: "FADE Launch Token",
            symbol: "FADE",
            creatorSalt: salt,
            metadata: UERC20Metadata({
                description: "A fixed supply one-sided v4 launch", website: "", image: "", extraData: bytes("")
            })
        });
    }

    function _accrued(bytes32 poolId) private view returns (uint256 creatorFees, uint256 programmableFees) {
        (,,,, creatorFees) = feeHook.poolFeeConfig(poolId);
        programmableFees = feeHook.programmableFeesAccrued();
    }

    function _assertBuyExactOutputAccounting(
        bytes32 poolId,
        BalanceDelta delta,
        uint256 tokenOutput,
        uint256 creatorBefore,
        uint256 programmableBefore
    ) private view {
        (uint256 creatorAfter, uint256 programmableAfter) = _accrued(poolId);
        uint256 creatorDelta = creatorAfter - creatorBefore;
        uint256 programmableDelta = programmableAfter - programmableBefore;
        uint256 grossNativeInput = uint256(-int256(delta.amount0()));
        uint256 netNativeInput = grossNativeInput - creatorDelta - programmableDelta;
        (uint256 expectedCreator, uint256 expectedProgrammable) =
            feeHook.quoteExactOutputFees(poolId, netNativeInput, block.timestamp);
        assertEq(uint256(int256(delta.amount1())), tokenOutput);
        assertEq(creatorDelta, expectedCreator);
        assertEq(programmableDelta, expectedProgrammable);
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
    }

    function _expectMetadataRevert(
        FadeLaunchV1.LaunchParameters memory parameters,
        bytes4 selector,
        uint256 actualBytes,
        uint256 maximumBytes
    ) private {
        (address predictedToken,) = launcher.predictTokenAddress(
            parameters.name, parameters.symbol, creator, parameters.creatorSalt
        );
        vm.expectRevert(abi.encodeWithSelector(selector, actualBytes, maximumBytes));
        vm.prank(creator);
        launcher.launch(parameters);
        assertEq(predictedToken.code.length, 0);
        assertEq(launcher.launchHashOf(predictedToken), bytes32(0));
    }

    function _asciiBytes(uint256 length, bytes1 character) private pure returns (string memory value) {
        bytes memory buffer = new bytes(length);
        for (uint256 i; i < length; i++) {
            buffer[i] = character;
        }
        value = string(buffer);
    }
}
