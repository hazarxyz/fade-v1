// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title FadeDecayFeeMath
/// @notice Exact fee schedule and ETH split used by every FADE pool.
library FadeDecayFeeMath {
    uint16 internal constant BASIS_POINTS = 10_000;
    uint16 internal constant PROGRAMMABLE_FEE_BPS = 10;
    uint16 internal constant START_TOTAL_FEE_BPS = 300;
    uint16 internal constant END_TOTAL_FEE_BPS = 100;
    uint256 internal constant DECAY_DURATION = 1 days;

    /// @notice Returns the integer-basis-point fee at `timestamp`.
    /// @dev The schedule is 3.00% at registration, decreases monotonically, and is exactly 1.00% after 24 hours.
    function feeBpsAt(uint64 launchTimestamp, uint256 timestamp) internal pure returns (uint16) {
        if (timestamp <= launchTimestamp) return START_TOTAL_FEE_BPS;

        uint256 elapsed = timestamp - uint256(launchTimestamp);
        if (elapsed >= DECAY_DURATION) return END_TOTAL_FEE_BPS;

        uint256 decay = FullMath.mulDiv(uint256(START_TOTAL_FEE_BPS - END_TOTAL_FEE_BPS), elapsed, DECAY_DURATION);
        return START_TOTAL_FEE_BPS - SafeCast.toUint16(decay);
    }

    /// @notice Splits a gross native amount into creator and Programmable fees.
    function feesForGross(uint256 grossNativeAmount, uint16 totalFeeBps)
        internal
        pure
        returns (uint256 creatorFee, uint256 programmableFee)
    {
        uint256 totalFee = FullMath.mulDiv(grossNativeAmount, totalFeeBps, BASIS_POINTS);
        programmableFee = FullMath.mulDiv(grossNativeAmount, PROGRAMMABLE_FEE_BPS, BASIS_POINTS);
        if (programmableFee > totalFee) programmableFee = totalFee;
        creatorFee = totalFee - programmableFee;
    }

    /// @notice Splits fees while preserving `netNativeAmount` as the requested pool-side amount.
    function feesForNet(uint256 netNativeAmount, uint16 totalFeeBps)
        internal
        pure
        returns (uint256 creatorFee, uint256 programmableFee)
    {
        uint256 grossNativeAmount = FullMath.mulDivRoundingUp(netNativeAmount, BASIS_POINTS, BASIS_POINTS - totalFeeBps);
        uint256 totalFee = grossNativeAmount - netNativeAmount;
        programmableFee = FullMath.mulDiv(grossNativeAmount, PROGRAMMABLE_FEE_BPS, BASIS_POINTS);
        if (programmableFee > totalFee) programmableFee = totalFee;
        creatorFee = totalFee - programmableFee;
    }
}
