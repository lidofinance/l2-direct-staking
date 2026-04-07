// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L2UpgradeScriptBase} from "script/shared/L2UpgradeScriptBase.s.sol";
import {L1MigrationConstants as L1} from "script/shared/L1MigrationConstants.sol";
import {LineaMigrationConstants as C} from "script/linea/LineaMigrationConstants.sol";

/**
 * @notice Linea-specific default config builder for L2 upgrade.
 * @dev Provides defaultL2Config() with Linea constants + Linea bridge fee encoding.
 *      Inheritable by tests and scripts.
 */
contract LineaL2Defaults is L2UpgradeActions {
    function defaultL2Config(address initialOwner, address governanceExecutor) public pure returns (L2UpgradeConfig memory cfg) {
        return defaultL2Config(initialOwner, governanceExecutor, C.LIQUIDITY_OWNER);
    }

    function defaultL2Config(address initialOwner, address governanceExecutor, address liquidityOwner)
        public
        pure
        returns (L2UpgradeConfig memory cfg)
    {
        cfg = L2UpgradeConfig({
            initialOwner: initialOwner,
            governanceExecutor: governanceExecutor,
            liquidityOwner: liquidityOwner,
            customSender: C.L2_CUSTOM_SENDER,
            proxyAdmin: C.L2_PROXY_ADMIN,
            tokenIn: C.L2_WETH,
            tokenOut: C.L2_WSTETH,
            priceOracle: C.L2_PRICE_ORACLE,
            fee: 0,
            destChainSelector: L1.ETH_CCIP_CHAIN_SELECTOR,
            destinationMaxFee: C.L2_SYNC_DESTINATION_MAX_FEE,
            destinationPayInLink: C.L2_SYNC_DESTINATION_PAY_IN_LINK,
            destinationGasLimit: C.L2_SYNC_DESTINATION_GAS_LIMIT,
            feeDtoO: FeeCodec.encodeLineaL1toL2(),
            minSyncAmount: C.L2_SYNC_MIN_AMOUNT,
            maxSyncAmount: C.L2_SYNC_MAX_AMOUNT,
            minSyncDelay: C.L2_SYNC_DELAY,
            oldChainlinkAutomation: C.L2_OLD_CHAINLINK_AUTOMATION,
            oldGelatoAutomation: C.L2_OLD_GELATO_AUTOMATION
        });
    }
}

/// @notice Production broadcast script for Linea L2 upgrade operations.
contract LineaL2UpgradeScript is L2UpgradeScriptBase, LineaL2Defaults {
    function _buildConfig(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        pure
        override
        returns (L2UpgradeConfig memory)
    {
        return defaultL2Config(initialOwner, governanceExecutor, liquidityOwner);
    }

    function _defaultLiquidityOwner() internal pure override returns (address) {
        return C.LIQUIDITY_OWNER;
    }
}
