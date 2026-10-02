// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PoolTestBase} from "test/helpers/PoolTestBase.sol";
import {ArbitrumL2Defaults} from "script/arbitrum/ArbitrumConfig.s.sol";
import {ArbitrumConstants as C} from "script/arbitrum/ArbitrumConstants.sol";

/// @notice Populates PoolTestBase with Arbitrum mainnet constants.
/// @dev Lane configuration from ArbitrumL2Defaults.
abstract contract ArbitrumPoolTestBase is PoolTestBase, ArbitrumL2Defaults {
    function setUp() public virtual override {
        // L2 governance executor (network-specific)
        LIDO_L2_GOVERNANCE_EXECUTOR = C.LIDO_L2_GOVERNANCE_EXECUTOR;

        // L1 adapter (network-specific)
        L1_ADAPTER = C.L1_ARBITRUM_ADAPTER;

        // L2
        L2_CUSTOM_SENDER = C.L2_CUSTOM_SENDER;
        L2_CUSTOM_SENDER_IMPL = C.L2_CUSTOM_SENDER_IMPL;
        L2_PROXY_ADMIN = C.L2_PROXY_ADMIN;
        L2_PRICE_ORACLE = C.L2_PRICE_ORACLE;
        L2_WETH = C.L2_WETH;
        L2_WSTETH = C.L2_WSTETH;
        L2_CCIP_ROUTER = C.L2_CCIP_ROUTER;
        L2_LINK_TOKEN = C.L2_LINK_TOKEN;

        // Chain (network-specific)
        L2_CCIP_CHAIN_SELECTOR = C.ARBITRUM_CCIP_CHAIN_SELECTOR;
        L2_CHAIN_ID = C.ARBITRUM_CHAIN_ID;

        // Sync defaults
        L2_SYNC_DESTINATION_MAX_FEE = C.L2_SYNC_DESTINATION_MAX_FEE;
        L2_SYNC_DESTINATION_GAS_LIMIT = C.L2_SYNC_DESTINATION_GAS_LIMIT;
        L2_SYNC_MIN_AMOUNT = C.L2_SYNC_MIN_AMOUNT;
        L2_SYNC_MAX_AMOUNT = C.L2_SYNC_MAX_AMOUNT;
        L2_SYNC_DELAY = C.L2_SYNC_DELAY;

        // Old sync automations (to verify revocation)
        L2_OLD_CHAINLINK_AUTOMATION = C.L2_OLD_CHAINLINK_AUTOMATION;

        // Measured 2026-07-29 on an Arbitrum mainnet fork by `test_creWriteGasCarrier` — the most expensive
        // of the four lanes, so it sets the floor for the configured `writeGasLimit`.
        CRE_WRITE_GAS_BASELINE = 339_193;

        super.setUp();
    }

    function _l2RpcUrl() internal view override returns (string memory) {
        return vm.envString("L2_ARBITRUM_RPC_URL");
    }

    function _l1RpcUrl() internal view override returns (string memory) {
        return vm.envString("L1_RPC_URL");
    }

    function _defaultL2Config(address liquidityOwner) internal pure override returns (LaneConfig memory) {
        return defaultL2Config(liquidityOwner);
    }
}
