// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {L1UpgradeActions} from "script/shared/L1UpgradeActions.s.sol";
import {L1UpgradeScriptBase} from "script/shared/L1UpgradeScriptBase.s.sol";

/// @dev Re-export so test bases can still inherit "BaseL1Defaults".
contract BaseL1Defaults is L1UpgradeActions {}

/// @notice Production broadcast script for L1 upgrade (Base context).
contract BaseL1UpgradeScript is L1UpgradeScriptBase {}
