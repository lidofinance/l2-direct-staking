// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {L2Config} from "script/shared/L2Config.sol";

/// @notice Print encoded lane fees for verify-constants-sync. No RPC or signing key required.
abstract contract L2ConfigScriptBase is Script, L2Config {
    function _buildConfig() internal pure virtual returns (LaneConfig memory);

    function runPrintFeeParams() public pure {
        LaneConfig memory cfg = _buildConfig();

        bytes memory feeOtoD = _encodeFeeOtoD(cfg);
        bytes memory feeDtoO = cfg.feeDtoO;

        uint256 maxNativeFee = _maxFees(feeOtoD, feeDtoO);

        console2.log("FEE_OTO_D=%s", vm.toString(feeOtoD));
        console2.log("FEE_DTO_O=%s", vm.toString(feeDtoO));
        console2.log("MAX_NATIVE_FEE=%s", vm.toString(maxNativeFee));
        // The FeeOtoD gasLimit ceiling (SyncTrigger.getMaxGasLimit) — cross-checked vs the &maxGasLimit
        // .inputs anchor by verify-constants-sync, the same Solidity→.inputs guard as the fee blobs.
        console2.log("MAX_GAS_LIMIT=%s", vm.toString(uint256(cfg.maxGasLimit)));
    }
}
