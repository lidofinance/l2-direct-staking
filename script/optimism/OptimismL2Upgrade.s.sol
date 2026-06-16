// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L2UpgradeScriptBase} from "script/shared/L2UpgradeScriptBase.s.sol";
import {L1MigrationConstants as L1} from "script/l1/L1MigrationConstants.sol";
import {OptimismMigrationConstants as C} from "script/optimism/OptimismMigrationConstants.sol";

/**
 * @notice Optimism-specific default config builder for L2 upgrade.
 * @dev Provides defaultL2Config() with Optimism constants + Optimism bridge fee encoding.
 *      Inheritable by tests and scripts.
 */
contract OptimismL2Defaults is L2UpgradeActions {
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
            feeDtoO: FeeCodec.encodeOptimismL1toL2(C.L2_SYNC_ORIGIN_L2_GAS),
            minSyncAmount: C.L2_SYNC_MIN_AMOUNT,
            maxSyncAmount: C.L2_SYNC_MAX_AMOUNT,
            minSyncDelay: C.L2_SYNC_DELAY,
            syncTriggerInitialFloat: C.L2_SYNC_TRIGGER_INITIAL_FLOAT,
            oldChainlinkAutomation: C.L2_OLD_CHAINLINK_AUTOMATION,
            oldGelatoAutomation: address(0)
        });
    }
}

/// @notice Production broadcast script for Optimism L2 upgrade operations.
contract OptimismL2UpgradeScript is L2UpgradeScriptBase, OptimismL2Defaults {
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

    function _expectedChainId() internal pure override returns (uint256) {
        return C.OPTIMISM_CHAIN_ID;
    }

    function _expectedGovernanceExecutor() internal pure override returns (address) {
        return C.LIDO_L2_GOVERNANCE_EXECUTOR;
    }

    function _expectedCREForwarder() internal pure override returns (address) {
        return C.CRE_FORWARDER;
    }
}
