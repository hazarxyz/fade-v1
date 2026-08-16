// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Permit2 } from "permit2/src/Permit2.sol";

/// @dev Isolated 0.8.17 compilation root used only to deploy the exact pinned Permit2 runtime in tests.
contract PinnedPermit2Artifact is Permit2 { }
