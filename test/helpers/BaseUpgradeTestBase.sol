// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {BaseL2Defaults} from "script/base/BaseL2Upgrade.s.sol";
import {BaseL1Defaults} from "script/base/BaseL1Upgrade.s.sol";
import {BaseMigrationConstants as C} from "script/base/BaseMigrationConstants.sol";

/**
 * @title BaseUpgradeTestBase
 * @notice Populates UpgradeTestBase with Base mainnet constants.
 *         Delegates config construction to BaseL2Defaults / BaseL1Defaults.
 */
abstract contract BaseUpgradeTestBase is UpgradeTestBase, BaseL2Defaults, BaseL1Defaults {
    function setUp() public virtual override {
        // L2 governance executor (network-specific)
        LIDO_L2_GOVERNANCE_EXECUTOR = C.LIDO_L2_GOVERNANCE_EXECUTOR;

        // L1 adapter (network-specific)
        L1_ADAPTER = C.L1_BASE_ADAPTER;

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
        L2_CCIP_CHAIN_SELECTOR = C.BASE_CCIP_CHAIN_SELECTOR;
        L2_CHAIN_ID = C.BASE_CHAIN_ID;

        // Sync defaults
        L2_SYNC_DESTINATION_MAX_FEE = C.L2_SYNC_DESTINATION_MAX_FEE;
        L2_SYNC_DESTINATION_PAY_IN_LINK = C.L2_SYNC_DESTINATION_PAY_IN_LINK;
        L2_SYNC_DESTINATION_GAS_LIMIT = C.L2_SYNC_DESTINATION_GAS_LIMIT;
        L2_SYNC_MIN_AMOUNT = C.L2_SYNC_MIN_AMOUNT;
        L2_SYNC_MAX_AMOUNT = C.L2_SYNC_MAX_AMOUNT;
        L2_SYNC_DELAY = C.L2_SYNC_DELAY;

        // Old sync automations (to verify revocation)
        L2_OLD_SYNC_AUTOMATION = C.L2_OLD_SYNC_AUTOMATION;

        super.setUp();
    }

    function _l2RpcUrl() internal view override returns (string memory) {
        return vm.envString("L2_BASE_RPC_URL");
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
        return FeeCodec.encodeBaseL1toL2(C.L2_SYNC_ORIGIN_L2_GAS);
    }
}
