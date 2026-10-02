// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {L2Config} from "script/shared/L2Config.sol";
import {L2ConfigScriptBase} from "script/shared/L2ConfigScriptBase.s.sol";
import {L1Constants as L1} from "script/l1/L1Constants.sol";
import {LineaConstants as C} from "script/linea/LineaConstants.sol";

/**
 * @notice Linea-specific lane configuration.
 * @dev Provides defaultL2Config() with Linea constants + Linea bridge fee encoding.
 *      Used by fork tests and fee checks.
 */
contract LineaL2Defaults is L2Config {
    function defaultL2Config(address liquidityOwner) public pure returns (LaneConfig memory cfg) {
        cfg = LaneConfig({
            liquidityOwner: liquidityOwner,
            customSender: C.L2_CUSTOM_SENDER,
            tokenIn: C.L2_WETH,
            tokenOut: C.L2_WSTETH,
            priceOracle: C.L2_PRICE_ORACLE,
            fee: 0,
            destChainSelector: L1.ETH_CCIP_CHAIN_SELECTOR,
            destinationMaxFee: C.L2_SYNC_DESTINATION_MAX_FEE,
            destinationGasLimit: C.L2_SYNC_DESTINATION_GAS_LIMIT,
            maxGasLimit: C.L2_SYNC_MAX_GAS_LIMIT,
            feeDtoO: FeeCodec.encodeLineaL1toL2(),
            minSyncAmount: C.L2_SYNC_MIN_AMOUNT,
            maxSyncAmount: C.L2_SYNC_MAX_AMOUNT,
            minSyncDelay: C.L2_SYNC_DELAY
        });
    }
}

/// @notice RPC-free fee configuration for Linea.
contract LineaConfigScript is L2ConfigScriptBase, LineaL2Defaults {
    function _buildConfig() internal pure override returns (LaneConfig memory) {
        return defaultL2Config(C.LIQUIDITY_OWNER);
    }
}
