// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

import { FadeDecayFeeMath } from "../src/FadeDecayFeeMath.sol";

contract FadeDecayFeeMathHarness {
    function feeBpsAt(uint64 launchTimestamp, uint256 timestamp) external pure returns (uint16) {
        return FadeDecayFeeMath.feeBpsAt(launchTimestamp, timestamp);
    }

    function feesForGross(uint256 grossNativeAmount, uint16 totalFeeBps)
        external
        pure
        returns (uint256 creatorFee, uint256 programmableFee)
    {
        return FadeDecayFeeMath.feesForGross(grossNativeAmount, totalFeeBps);
    }

    function feesForNet(uint256 netNativeAmount, uint16 totalFeeBps)
        external
        pure
        returns (uint256 creatorFee, uint256 programmableFee)
    {
        return FadeDecayFeeMath.feesForNet(netNativeAmount, totalFeeBps);
    }
}

contract FadeDecayFeeMathTest is Test {
    uint256 internal constant BASIS_POINTS = 10_000;
    FadeDecayFeeMathHarness internal harness;

    function setUp() public {
        harness = new FadeDecayFeeMathHarness();
    }

    function test_exactScheduleBoundaries() public view {
        uint64 launchedAt = 1_000_000;
        assertEq(harness.feeBpsAt(launchedAt, launchedAt - 1), 300);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt), 300);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt + 6 hours), 250);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt + 12 hours), 200);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt + 18 hours), 150);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt + 24 hours - 1), 101);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt + 24 hours), 100);
        assertEq(harness.feeBpsAt(launchedAt, launchedAt + 365 days), 100);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_scheduleIsBoundedAndMonotonic(uint64 launchedAt, uint32 firstRaw, uint32 secondRaw) public view {
        uint256 first = bound(uint256(firstRaw), 0, 365 days);
        uint256 second = bound(uint256(secondRaw), 0, 365 days);
        if (first > second) (first, second) = (second, first);

        uint16 firstFee = harness.feeBpsAt(launchedAt, uint256(launchedAt) + first);
        uint16 secondFee = harness.feeBpsAt(launchedAt, uint256(launchedAt) + second);
        assertLe(secondFee, firstFee);
        assertGe(firstFee, 100);
        assertLe(firstFee, 300);
        assertGe(secondFee, 100);
        assertLe(secondFee, 300);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_grossSplitConservesFeeAndFixesProgrammableAtTenBps(uint96 grossRaw, uint32 elapsedRaw)
        public
        view
    {
        uint256 gross = bound(uint256(grossRaw), 10_000, 100_000 ether);
        uint16 feeBps = harness.feeBpsAt(1, 1 + bound(uint256(elapsedRaw), 0, 365 days));
        (uint256 creatorFee, uint256 programmableFee) = harness.feesForGross(gross, feeBps);

        assertEq(creatorFee + programmableFee, FullMath.mulDiv(gross, feeBps, BASIS_POINTS));
        assertEq(programmableFee, FullMath.mulDiv(gross, 10, BASIS_POINTS));
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_netSplitPreservesRequestedPoolAmount(uint96 netRaw, uint32 elapsedRaw) public view {
        uint256 net = bound(uint256(netRaw), 10_000, 100_000 ether);
        uint16 feeBps = harness.feeBpsAt(1, 1 + bound(uint256(elapsedRaw), 0, 365 days));
        (uint256 creatorFee, uint256 programmableFee) = harness.feesForNet(net, feeBps);
        uint256 gross = FullMath.mulDivRoundingUp(net, BASIS_POINTS, BASIS_POINTS - feeBps);

        assertEq(net + creatorFee + programmableFee, gross);
        assertEq(programmableFee, FullMath.mulDiv(gross, 10, BASIS_POINTS));
    }
}
