// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Linea-specific constants for lane migration.
/// @dev L1 and shared constants live in L1MigrationConstants.
library LineaMigrationConstants {
    // L2 governance executor
    address internal constant LIDO_L2_GOVERNANCE_EXECUTOR = 0x2897A1b134050c01503843db48e034d4C9e2b18c;

    // Liquidity Observation Lab (LOL) multisig — pool owner and liquidity provider
    address internal constant LIQUIDITY_OWNER = 0xA8EF4Db842d95DE72433a8B5b8fF40cB9C74c1B6;

    // L1 adapter (Linea-specific)
    address internal constant L1_LINEA_ADAPTER = 0x122beD1eB48DC4679DDF2C8fc159e9c498344397;

    // L2 (Linea)
    address internal constant L2_CUSTOM_SENDER = 0x328de900860816d29D1367F6903a24D8ed40C997;
    address internal constant L2_CUSTOM_SENDER_IMPL = 0xBf96561e4519182CFA4cebBf95494D9CA5a316f9;
    address internal constant L2_PROXY_ADMIN = 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192;
    address internal constant L2_OLD_ORACLE_POOL = 0x6F357d53d6bE3238180316BA5F8f11467e164588;
    address internal constant L2_PRICE_ORACLE = 0x301cBCDA894c932E9EDa3Cf8878f78304e69E367;
    address internal constant L2_WETH = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
    address internal constant L2_WSTETH = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F;
    address internal constant L2_CCIP_ROUTER = 0x549FEB73F2348F6cD99b9fc8c69252034897f06C;
    address internal constant L2_LINK_TOKEN = 0xa18152629128738a5c081eb226335FEd4B9C95e9;

    // Old automations (to be retired during migration — revoke SYNC_ROLE)
    address internal constant L2_OLD_CHAINLINK_AUTOMATION = 0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace;
    address internal constant L2_OLD_GELATO_AUTOMATION = 0xFbdDDF18Bc681Ae649991f1Aced55b2252a1acAe;

    // L2 SyncTrigger defaults — see docs/sync-fees.md for the Glamsterdam fee headroom rationale.
    // Linea's gasLimit baseline is half the others (Linea Message Service uses a leaner adapter).
    uint128 internal constant L2_SYNC_DESTINATION_MAX_FEE = 0.125e18;
    bool internal constant L2_SYNC_DESTINATION_PAY_IN_LINK = false;
    uint32 internal constant L2_SYNC_DESTINATION_GAS_LIMIT = 500_000;
    // Linea FeeDtoO uses FeeCodec.encodeLineaL1toL2() which takes no parameters
    uint128 internal constant L2_SYNC_MIN_AMOUNT = 5e18;
    uint128 internal constant L2_SYNC_MAX_AMOUNT = 100e18;
    uint48 internal constant L2_SYNC_DELAY = 12 hours;

    // CCIP / Chain IDs (Linea-specific)
    uint64 internal constant LINEA_CCIP_CHAIN_SELECTOR = 4627098889531055414;
    uint256 internal constant LINEA_CHAIN_ID = 59144;
}
