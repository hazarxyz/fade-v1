// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

import { FadeDecayFeeMath } from "../src/FadeDecayFeeMath.sol";

contract FadeAccountingHandler {
    uint256 internal constant BASIS_POINTS = 10_000;
    uint64 public constant LAUNCH_TIMESTAMP = 1_000_000;

    uint256 public elapsed;
    uint16 public lastFeeBps = 300;
    bool public scheduleHolds = true;
    bool public accountingHolds = true;

    function advance(uint32 rawSecondsForward) external {
        uint256 increment = uint256(rawSecondsForward) % 1 days;
        uint256 next = elapsed + increment;
        if (next > 365 days) next = 365 days;

        uint16 nextFee = FadeDecayFeeMath.feeBpsAt(LAUNCH_TIMESTAMP, uint256(LAUNCH_TIMESTAMP) + next);
        if (nextFee > lastFeeBps || nextFee < 100 || nextFee > 300) scheduleHolds = false;
        elapsed = next;
        lastFeeBps = nextFee;
    }

    function quoteGross(uint96 rawGross) external {
        uint256 gross = uint256(rawGross) + 10_000;
        uint16 feeBps = FadeDecayFeeMath.feeBpsAt(LAUNCH_TIMESTAMP, uint256(LAUNCH_TIMESTAMP) + elapsed);
        (uint256 creatorFee, uint256 programmableFee) = FadeDecayFeeMath.feesForGross(gross, feeBps);
        if (
            creatorFee + programmableFee != FullMath.mulDiv(gross, feeBps, BASIS_POINTS)
                || programmableFee != FullMath.mulDiv(gross, 10, BASIS_POINTS)
        ) accountingHolds = false;
    }

    function quoteNet(uint96 rawNet) external {
        uint256 net = uint256(rawNet) + 10_000;
        uint16 feeBps = FadeDecayFeeMath.feeBpsAt(LAUNCH_TIMESTAMP, uint256(LAUNCH_TIMESTAMP) + elapsed);
        (uint256 creatorFee, uint256 programmableFee) = FadeDecayFeeMath.feesForNet(net, feeBps);
        uint256 gross = FullMath.mulDivRoundingUp(net, BASIS_POINTS, BASIS_POINTS - feeBps);
        if (net + creatorFee + programmableFee != gross || programmableFee != FullMath.mulDiv(gross, 10, BASIS_POINTS))
        {
            accountingHolds = false;
        }
    }
}

contract FadeAccountingInvariantTest is StdInvariant, Test {
    FadeAccountingHandler internal handler;

    function setUp() public {
        handler = new FadeAccountingHandler();
        targetContract(address(handler));
    }

    function invariant_scheduleNeverIncreasesOrLeavesOneToThreePercent() public view {
        assertTrue(handler.scheduleHolds());
        assertGe(handler.lastFeeBps(), 100);
        assertLe(handler.lastFeeBps(), 300);
    }

    function invariant_grossAndNetFeeAccountingAlwaysConserveValue() public view {
        assertTrue(handler.accountingHolds());
    }
}
