// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Canonical constants for Optimism Sepolia testnet lane migration.
/// @dev Mirrors the structure of OptimismMigrationConstants.sol but with Sepolia addresses.
///      Deployed infrastructure addresses (CustomSender, ProxyAdmin, PriceOracle, Receiver)
///      are set to address(0) as sentinels — scripts read them from environment variables.
library SepoliaMigrationConstants {
    // Roles (same as mainnet)
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SYNC_ROLE = keccak256("SYNC_ROLE");

    // L1 (Ethereum Sepolia) — well-known addresses
    address internal constant L1_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address internal constant L1_WSTETH = 0xB82381A3fBD3FaFA77B3a7bE693342618240067b;
    address internal constant L1_LINK_TOKEN = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address internal constant L1_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address internal constant L1_OPTIMISM_TOKEN_BRIDGE = 0x4Abf633d9c0F4aEebB4C2E3213c7aa1b8505D332;

    // L2 (Optimism Sepolia) — well-known addresses
    address internal constant L2_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant L2_WSTETH = 0x24B47cd3A74f1799b32B2de11073764Cb1bb318B;
    address internal constant L2_CCIP_ROUTER = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57;
    address internal constant L2_LINK_TOKEN = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    address internal constant L2_OPTIMISM_TOKEN_BRIDGE = 0xdBA2760246f315203F8B716b3a7590F0FFdc704a;

    // L2 SyncTrigger defaults — lower thresholds for testnet
    uint128 internal constant L2_SYNC_DESTINATION_MAX_FEE = 0.1e18;
    bool internal constant L2_SYNC_DESTINATION_PAY_IN_LINK = false;
    uint32 internal constant L2_SYNC_DESTINATION_GAS_LIMIT = 400_000;
    // FeeOtoD gasLimit ceiling for the Optimism-Sepolia rehearsal lane (matches the OP mainnet cap;
    // any value >= the gasLimit suffices on testnet). Mirrors L2_SYNC_MAX_GAS_LIMIT on the prod lanes.
    uint32 internal constant L2_SYNC_MAX_GAS_LIMIT = 7_000_000;
    uint32 internal constant L2_SYNC_ORIGIN_L2_GAS = 100_000;
    uint128 internal constant L2_SYNC_MIN_AMOUNT = 0.01e18;
    uint128 internal constant L2_SYNC_MAX_AMOUNT = 1e18;
    uint48 internal constant L2_SYNC_DELAY = 5 minutes;
    // Initial native-ETH fee float funded into the SyncTrigger at deploy (it fronts
    // maxFee + feeDtoO per sync from its own balance — README §Funding the float).
    // Floor = 0.1 (maxFee, DtoO is free on OP-stack); small runway is fine on testnet.
    uint128 internal constant L2_SYNC_TRIGGER_INITIAL_FLOAT = 0.15e18;

    // CCIP / Chain IDs (Sepolia)
    uint64 internal constant ETH_CCIP_CHAIN_SELECTOR = 16015286601757825753;
    uint64 internal constant OPTIMISM_CCIP_CHAIN_SELECTOR = 5224473277236331295;
    uint256 internal constant ETH_CHAIN_ID = 11155111;
    uint256 internal constant OPTIMISM_CHAIN_ID = 11155420;

    // EIP-1967 slots (same as mainnet)
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
}
