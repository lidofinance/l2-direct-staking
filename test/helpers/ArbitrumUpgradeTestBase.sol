// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {ArbitrumL2Defaults} from "script/arbitrum/ArbitrumL2Upgrade.s.sol";
import {ArbitrumMigrationConstants as C} from "script/arbitrum/ArbitrumMigrationConstants.sol";

/// @notice Populates UpgradeTestBase with Arbitrum mainnet constants.
/// @dev L2 config from ArbitrumL2Defaults; L1 actions inherited via UpgradeTestBase.
abstract contract ArbitrumUpgradeTestBase is UpgradeTestBase, ArbitrumL2Defaults {
    function _envOr(string memory primary, string memory secondary) internal view returns (string memory) {
        try vm.envString(primary) returns (string memory value) {
            return value;
        } catch {
            return vm.envString(secondary);
        }
    }

    function setUp() public virtual override {
        // L2 governance executor (network-specific)
        LIDO_L2_GOVERNANCE_EXECUTOR = C.LIDO_L2_GOVERNANCE_EXECUTOR;

        // L1 adapter (network-specific)
        L1_ADAPTER = C.L1_ARBITRUM_ADAPTER;

        // L2
        L2_CUSTOM_SENDER = C.L2_CUSTOM_SENDER;
        L2_CUSTOM_SENDER_IMPL = C.L2_CUSTOM_SENDER_IMPL;
        L2_PROXY_ADMIN = C.L2_PROXY_ADMIN;
        L2_OLD_ORACLE_POOL = C.L2_OLD_ORACLE_POOL;
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
        return _envOr("LOCAL_L2_ARBITRUM_RPC_URL", "L2_ARBITRUM_RPC_URL");
    }

    function _l1RpcUrl() internal view override returns (string memory) {
        return vm.envString("L1_RPC_URL");
    }


    function _defaultL2Config(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        pure
        override
        returns (L2UpgradeConfig memory)
    {
        return defaultL2Config(initialOwner, governanceExecutor, liquidityOwner);
    }

    function _defaultL1Config(address initialOwner, address lidoDaoAgent)
        internal
        pure
        override
        returns (L1UpgradeConfig memory)
    {
        return defaultL1Config(initialOwner, lidoDaoAgent);
    }

    function _defaultFeeDtoO() internal pure override returns (bytes memory) {
        return FeeCodec.encodeArbitrumL1toL2(
            C.L2_SYNC_ORIGIN_MAX_SUBMISSION_COST, C.L2_SYNC_ORIGIN_MAX_GAS, C.L2_SYNC_ORIGIN_GAS_PRICE_BID
        );
    }
}
