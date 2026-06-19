// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Optimism-specific constants for lane migration.
/// @dev L1 and shared constants live in L1MigrationConstants.
library OptimismMigrationConstants {
    // L2 governance executor (OptimismBridgeExecutor)
    address internal constant LIDO_L2_GOVERNANCE_EXECUTOR = 0xEfa0dB536d2c8089685630fafe88CF7805966FC3;

    // Chainlink CRE Keystone forwarder (production) — the sole caller of CREReceiver.onReport().
    // Fixed per network and Chainlink-operated, so it is pinned here rather than supplied via env.
    // Source: Chainlink CRE production forwarder directory. Cross-checked against the l2CreForwarder
    // state-mate anchor by `just verify-constants-sync`.
    address internal constant CRE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    // Liquidity Observation Lab (LOL) multisig — pool owner and liquidity provider
    address internal constant LIQUIDITY_OWNER = 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61;

    // L1 adapter (Optimism-specific)
    address internal constant L1_OPTIMISM_ADAPTER = 0x328de900860816d29D1367F6903a24D8ed40C997;

    // L2 (Optimism)
    address internal constant L2_CUSTOM_SENDER = 0x328de900860816d29D1367F6903a24D8ed40C997;
    address internal constant L2_CUSTOM_SENDER_IMPL = 0x65498495DdC07c52E12EEe3c44D3a1166eed8703;
    address internal constant L2_PROXY_ADMIN = 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192;
    address internal constant L2_OLD_ORACLE_POOL = 0x6F357d53d6bE3238180316BA5F8f11467e164588;
    address internal constant L2_PRICE_ORACLE = 0x301cBCDA894c932E9EDa3Cf8878f78304e69E367;
    address internal constant L2_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant L2_WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address internal constant L2_CCIP_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    address internal constant L2_LINK_TOKEN = 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;

    // Old Chainlink Automation (to be retired during migration — revoke SYNC_ROLE)
    address internal constant L2_OLD_CHAINLINK_AUTOMATION = 0x3776CC14ce997827F7A87091018Daa1739dc2790;

    // L2 SyncTrigger defaults — see README.md §Sync fee parameters for the Glamsterdam fee headroom rationale.
    uint128 internal constant L2_SYNC_DESTINATION_MAX_FEE = 0.125e18;
    uint32 internal constant L2_SYNC_DESTINATION_GAS_LIMIT = 1_000_000;
    // FeeOtoD gasLimit ceiling = Optimism's FeeQuoter maxPerMsgGasLimit (docs/fees.md §lane caps,
    // verified on-chain). SyncTrigger._setFeeOtoD rejects gasLimit above this — config-time guard
    // for the over-bump footgun (audit-scope C-1).
    uint32 internal constant L2_SYNC_MAX_GAS_LIMIT = 7_000_000;
    uint32 internal constant L2_SYNC_ORIGIN_L2_GAS = 100_000;
    uint128 internal constant L2_SYNC_MIN_AMOUNT = 5e18;
    uint128 internal constant L2_SYNC_MAX_AMOUNT = 100e18;
    uint48 internal constant L2_SYNC_DELAY = 12 hours;
    // Initial native-ETH fee float funded into the SyncTrigger at Stage-1 deploy (it fronts
    // maxFee + feeDtoO per sync from its own balance — README §Funding the float).
    // Floor = 0.125 (maxFee, DtoO is free on OP-stack); 0.5 ≈ floor + ~30 days runway at
    // measured ~0.005 ETH/sync. Keep modest: recovering excess is sweep() = GovExec-only.
    uint128 internal constant L2_SYNC_TRIGGER_INITIAL_FLOAT = 0.5e18;

    // CCIP / Chain IDs (Optimism-specific)
    uint64 internal constant OPTIMISM_CCIP_CHAIN_SELECTOR = 3734403246176062136;
    uint256 internal constant OPTIMISM_CHAIN_ID = 10;
}
