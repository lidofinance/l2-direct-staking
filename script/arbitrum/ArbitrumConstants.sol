// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Arbitrum-specific constants for lane configuration.
/// @dev L1 and shared constants live in L1Constants.
library ArbitrumConstants {
    // L2 governance executor (ArbitrumBridgeExecutor)
    address internal constant LIDO_L2_GOVERNANCE_EXECUTOR = 0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29;

    // Chainlink CRE Keystone forwarder (production) — the sole caller of CREReceiver.onReport().
    // Fixed per network and Chainlink-operated, so it is pinned here rather than supplied via env.
    // Source: Chainlink CRE production forwarder directory. Cross-checked against the l2CreForwarder
    // state-mate anchor by `just verify-constants-sync`.
    address internal constant CRE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    // Liquidity Observation Lab (LOL) multisig — pool owner and liquidity provider
    address internal constant LIQUIDITY_OWNER = 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6;

    // L1 adapter (Arbitrum-specific)
    address internal constant L1_ARBITRUM_ADAPTER = 0xBf96561e4519182CFA4cebBf95494D9CA5a316f9;

    // L2 (Arbitrum)
    address internal constant L2_CUSTOM_SENDER = 0x72229141D4B016682d3618ECe47c046f30Da4AD1;
    address internal constant L2_CUSTOM_SENDER_IMPL = 0x220F64A4793Bc8aca7330ceCc4ae4e2F3B5Bc664;
    address internal constant L2_PROXY_ADMIN = 0x5B42aEbFe95247f1d22e282831e2A513bF050217;
    address internal constant L2_PRICE_ORACLE = 0x328de900860816d29D1367F6903a24D8ed40C997;
    address internal constant L2_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant L2_WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address internal constant L2_CCIP_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address internal constant L2_LINK_TOKEN = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;

    // Former Chainlink automation; SYNC_ROLE must remain revoked.
    address internal constant L2_OLD_CHAINLINK_AUTOMATION = 0x7EbD06BF137077fF5EE858ca6368dBd95DB7c66A;

    // L2 SyncTrigger defaults — see docs/fees.md for fee configuration and measurement limits.
    uint128 internal constant L2_SYNC_DESTINATION_MAX_FEE = 0.125e18;
    uint32 internal constant L2_SYNC_DESTINATION_GAS_LIMIT = 1_000_000;
    // FeeOtoD gasLimit ceiling = Arbitrum's FeeQuoter maxPerMsgGasLimit (docs/fees.md, Tuning,
    // verified on-chain). SyncTrigger._setFeeOtoD rejects gasLimit above this — config-time guard
    // for the over-bump footgun.
    uint32 internal constant L2_SYNC_MAX_GAS_LIMIT = 7_000_000;
    // Retryable ticket parameters: the L1 adapter requires the 29-byte ArbitrumL1toL2 encoding.
    uint128 internal constant L2_SYNC_ORIGIN_MAX_SUBMISSION_COST = 0.001e18;
    uint32 internal constant L2_SYNC_ORIGIN_MAX_GAS = 100_000;
    uint64 internal constant L2_SYNC_ORIGIN_GAS_PRICE_BID = 50_000_000; // 0.05 gwei
    uint128 internal constant L2_SYNC_MIN_AMOUNT = 5e18;
    uint128 internal constant L2_SYNC_MAX_AMOUNT = 100e18;
    uint48 internal constant L2_SYNC_DELAY = 12 hours;

    // CCIP / Chain IDs (Arbitrum-specific)
    uint64 internal constant ARBITRUM_CCIP_CHAIN_SELECTOR = 4949039107694359620;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
}
