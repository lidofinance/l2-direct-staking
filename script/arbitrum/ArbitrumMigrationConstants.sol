// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Arbitrum-specific constants for lane migration.
/// @dev L1 and shared constants live in L1MigrationConstants.
library ArbitrumMigrationConstants {
    // L2 governance executor (ArbitrumBridgeExecutor)
    address internal constant LIDO_L2_GOVERNANCE_EXECUTOR = 0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29;

    // Liquidity Observation Lab (LOL) multisig — pool owner and liquidity provider
    address internal constant LIQUIDITY_OWNER = 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61;

    // L1 adapter (Arbitrum-specific)
    address internal constant L1_ARBITRUM_ADAPTER = 0xBf96561e4519182CFA4cebBf95494D9CA5a316f9;

    // L2 (Arbitrum)
    address internal constant L2_CUSTOM_SENDER = 0x72229141D4B016682d3618ECe47c046f30Da4AD1;
    address internal constant L2_CUSTOM_SENDER_IMPL = 0x220F64A4793Bc8aca7330ceCc4ae4e2F3B5Bc664;
    address internal constant L2_PROXY_ADMIN = 0x5B42aEbFe95247f1d22e282831e2A513bF050217;
    address internal constant L2_OLD_ORACLE_POOL = 0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace;
    address internal constant L2_PRICE_ORACLE = 0x328de900860816d29D1367F6903a24D8ed40C997;
    address internal constant L2_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant L2_WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address internal constant L2_CCIP_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address internal constant L2_LINK_TOKEN = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;

    // Old Chainlink Automation (to be retired during migration — revoke SYNC_ROLE)
    address internal constant L2_OLD_CHAINLINK_AUTOMATION = 0x7EbD06BF137077fF5EE858ca6368dBd95DB7c66A;

    // L2 SyncTrigger defaults — see README.md §Sync fee parameters for the Glamsterdam fee headroom rationale.
    uint128 internal constant L2_SYNC_DESTINATION_MAX_FEE = 0.125e18;
    bool internal constant L2_SYNC_DESTINATION_PAY_IN_LINK = false;
    uint32 internal constant L2_SYNC_DESTINATION_GAS_LIMIT = 1_000_000;
    // Arbitrum retryable ticket parameters (used by FeeCodec.encodeArbitrumL1toL2).
    // NOTE: The live SyncAutomation at 0x7EbD06BF137077fF5EE858ca6368dBd95DB7c66A had its
    // FeeDtoO re-encoded from 29-byte ArbitrumL1toL2 format to 21-byte CCIP format
    // (tx 0xb7660bcaac043b63c5d2d3cea328ade8eaffaa593aeeab4278d09227f36ab881).
    // We keep the ArbitrumL1toL2 encoding here because:
    //   1. The L1 ArbitrumLegacyAdapterL1toL2 decodes feeDtoO with FeeCodec.decodeArbitrumL1toL2(),
    //      so the 29-byte format is required for the bridge call to succeed.
    //   2. These constants configure a NEW SyncTrigger deployment, not the existing one.
    //   3. The on-chain 21-byte value appears to be a configuration anomaly — it would cause
    //      decodeArbitrumL1toL2() to revert (expects exactly 29 bytes).
    uint128 internal constant L2_SYNC_ORIGIN_MAX_SUBMISSION_COST = 0.001e18;
    uint32 internal constant L2_SYNC_ORIGIN_MAX_GAS = 100_000;
    uint64 internal constant L2_SYNC_ORIGIN_GAS_PRICE_BID = 50_000_000; // 0.05 gwei
    uint128 internal constant L2_SYNC_MIN_AMOUNT = 5e18;
    uint128 internal constant L2_SYNC_MAX_AMOUNT = 100e18;
    uint48 internal constant L2_SYNC_DELAY = 12 hours;
    // Initial native-ETH fee float funded into the SyncTrigger at Stage-1 deploy (it fronts
    // maxFee + feeDtoO per sync from its own balance — README §Funding the float).
    // Floor ≈ 0.1266 (0.125 maxFee + maxSubmissionCost + maxGas×gasPriceBid ≈ 0.0016);
    // 0.5 ≈ floor + ~30 days runway at measured ~0.007 ETH/sync. Keep modest: recovering
    // excess is sweep() = GovExec-only.
    uint128 internal constant L2_SYNC_TRIGGER_INITIAL_FLOAT = 0.5e18;

    // CCIP / Chain IDs (Arbitrum-specific)
    uint64 internal constant ARBITRUM_CCIP_CHAIN_SELECTOR = 4949039107694359620;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
}
