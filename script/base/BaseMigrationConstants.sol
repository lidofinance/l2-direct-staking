// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Base-specific constants for lane migration.
/// @dev L1 and shared constants live in L1MigrationConstants.
library BaseMigrationConstants {
    // L2 governance executor
    address internal constant LIDO_L2_GOVERNANCE_EXECUTOR = 0x2897A1b134050c01503843db48e034d4C9e2b18c;

    // Liquidity Observation Lab (LOL) multisig — pool owner and liquidity provider
    address internal constant LIQUIDITY_OWNER = 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61;

    // L1 adapter (Base-specific)
    address internal constant L1_BASE_ADAPTER = 0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace;

    // L2 (Base)
    address internal constant L2_CUSTOM_SENDER = 0x328de900860816d29D1367F6903a24D8ed40C997;
    address internal constant L2_CUSTOM_SENDER_IMPL = 0x65498495DdC07c52E12EEe3c44D3a1166eed8703;
    address internal constant L2_PROXY_ADMIN = 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192;
    address internal constant L2_OLD_ORACLE_POOL = 0x6F357d53d6bE3238180316BA5F8f11467e164588;
    address internal constant L2_PRICE_ORACLE = 0x301cBCDA894c932E9EDa3Cf8878f78304e69E367;
    address internal constant L2_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant L2_WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address internal constant L2_CCIP_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address internal constant L2_LINK_TOKEN = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;

    // Old SyncAutomation (to be retired during migration — revoke SYNC_ROLE)
    address internal constant L2_OLD_SYNC_AUTOMATION = 0x3776CC14ce997827F7A87091018Daa1739dc2790;

    // L2 SyncTrigger defaults
    // Current mainnet values: https://basescan.org/address/0x3776CC14ce997827F7A87091018Daa1739dc2790#readContract (getFeeOtoD / getFeeDtoO)
    uint128 internal constant L2_SYNC_DESTINATION_MAX_FEE = 0.1e18;
    bool internal constant L2_SYNC_DESTINATION_PAY_IN_LINK = false;
    uint32 internal constant L2_SYNC_DESTINATION_GAS_LIMIT = 800_000;
    uint32 internal constant L2_SYNC_ORIGIN_L2_GAS = 100_000;
    uint128 internal constant L2_SYNC_MIN_AMOUNT = 5e18;
    uint128 internal constant L2_SYNC_MAX_AMOUNT = 100e18;
    uint48 internal constant L2_SYNC_DELAY = 12 hours;

    // CCIP / Chain IDs (Base-specific)
    uint64 internal constant BASE_CCIP_CHAIN_SELECTOR = 15971525489660198786;
    uint256 internal constant BASE_CHAIN_ID = 8453;
}
