// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice L1 (Ethereum) constants shared across all L2 network migrations.
library L1MigrationConstants {
    // Roles
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // Owners — same across all networks
    address internal constant INITIAL_OWNER = 0xb5c336a5c60D3482b29d83C742C65AE8351b91a8;
    address internal constant LIDO_DAO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

    // L1 contracts
    address internal constant L1_LIDO_CUSTOM_RECEIVER = 0x6F357d53d6bE3238180316BA5F8f11467e164588;
    address internal constant L1_LIDO_CUSTOM_RECEIVER_IMPL = 0x301cBCDA894c932E9EDa3Cf8878f78304e69E367;
    address internal constant L1_PROXY_ADMIN = 0x88a45d2760b63c1500E3D2E3552b28e5Cdaa37BD;
    address internal constant L1_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant L1_WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant L1_LINK_TOKEN = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address internal constant L1_CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

    // Ethereum CCIP / chain ID
    uint64 internal constant ETH_CCIP_CHAIN_SELECTOR = 5009297550715157269;
    uint256 internal constant ETH_CHAIN_ID = 1;

    // EIP-1967 slots
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
}
