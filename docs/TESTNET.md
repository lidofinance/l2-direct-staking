# Testnet (Sepolia) Deployment Guide

This guide covers deploying the Lido Direct Staking system to **Ethereum Sepolia + Optimism Sepolia** testnets.

## Prerequisites

1. **RPC endpoints** for both Sepolia and OP Sepolia (e.g., Alchemy, Infura)
2. **Funded accounts** with Sepolia ETH on both chains
3. **Testnet LINK tokens** on OP Sepolia (for SyncTrigger funding)
4. **Foundry** installed (`forge`, `cast`, `anvil`)
5. **just** command runner installed

## Environment Setup

```bash
cp .env.sepolia.example .env.sepolia
# Edit .env.sepolia with your RPC URLs and private keys
```

Load the environment before running commands:
```bash
source .env.sepolia
# or use: set -a && source .env.sepolia && set +a
```

## Deployment Flow

The deployment is a 4-step process. On mainnet, step 1 was done separately (the CSR infrastructure already exists). On testnet, we must deploy it first.

### Step 1: Deploy CSR Infrastructure

Deploys the base infrastructure (LidoCustomReceiver, OptimismAdapter, PriceOracle, CustomSender, etc.) to both chains.

```bash
just sepolia-deploy-csr
```

This runs `SepoliaCSRDeploy.s.sol` which:
- Deploys `LidoCustomReceiver` + proxy on Sepolia L1
- Deploys `OptimismLegacyAdapterL1toL2` on Sepolia L1
- Deploys `MockAggregator` (returns 1.2e18 wstETH/stETH price) on OP Sepolia
- Deploys `PriceOracle` + `CustomSenderReferral` + proxy on OP Sepolia
- Wires adapters, senders, and receivers

**Save the output addresses** — you need them for the next steps, especially `L2_BOOTSTRAP_SYNC_AUTOMATION`, which step 2 uses to retire the bootstrap automation cleanly.

### Step 2: Run L2 Upgrade on OP Sepolia

Set the addresses from step 1 in your environment, then:

```bash
export L2_BOOTSTRAP_SYNC_AUTOMATION=<address from step 1>
export L2_CUSTOM_SENDER=<address from step 1>
export L2_PROXY_ADMIN=<address from step 1>
export L2_PRICE_ORACLE=<address from step 1>
just sepolia-upgrade-l2
```

This deploys a replacement `OraclePool` and `SyncTrigger`, repoints `CustomSender`, sweeps any WETH/wstETH out of the bootstrap pool into the replacement pool, revokes the bootstrap automation's `SYNC_ROLE`, and hands the retired bootstrap contracts over to `L2_GOVERNANCE_EXECUTOR`.

### Step 3: Run L1 Upgrade on Sepolia

```bash
just sepolia-upgrade-l1
```

This transfers admin roles on the L1 receiver and proxy admin.

## Local Testing with Anvil Forks

To dry-run against Anvil forks before broadcasting to live testnets:

```bash
# Terminal 1: Start L1 Sepolia fork
just rpc-start-l1-sepolia

# Terminal 2: Start L2 OP Sepolia fork
just rpc-start-l2-optimism-sepolia

# Terminal 3: Run scripts against local forks
export L1_SEPOLIA_RPC_URL=http://localhost:8545
export L2_OPTIMISM_SEPOLIA_RPC_URL=http://localhost:8551
just sepolia-deploy-csr
```

## Differences from Mainnet

| Aspect | Mainnet | Sepolia |
|---|---|---|
| wstETH/stETH price feed | Real Chainlink feeds | MockAggregator (fixed 1.2e18) |
| Min sync amount | 5 ETH | 0.01 ETH |
| Max sync amount | 100 ETH | 1 ETH |
| Sync delay | 12 hours | 5 minutes |
| CSR infrastructure | Pre-deployed | Deployed in step 1 |
| Config source | Hardcoded in `OptimismMigrationConstants.sol` | `SepoliaMigrationConstants.sol` + env vars |

## Contract Verification

After deploying to live Sepolia, verify contracts on Etherscan:

```bash
# L1 contracts
forge verify-contract <RECEIVER_IMPL> LidoCustomReceiver \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY

# L2 contracts
forge verify-contract <SENDER_IMPL> CustomSenderReferral \
  --chain optimism-sepolia --etherscan-api-key $ETHERSCAN_API_KEY
```

## CRE Workflow Testnet Deployment

To deploy the CRE workflow to testnet, update `cre-workflows/sync-automation/config.test.json` with the Sepolia contract addresses and chain selectors.

## Sepolia Token Addresses

| Token | L1 Sepolia | L2 OP Sepolia |
|---|---|---|
| wstETH | `0xB82381A3fBD3FaFA77B3a7bE693342618240067b` | `0x24B47cd3A74f1799b32B2de11073764Cb1bb318B` |
| WETH | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` | `0x4200000000000000000000000000000000000006` |
| LINK | `0x779877A7B0D9E8603169DdbD7836e478b4624789` | `0xE4aB69C077896252FAFBD49EFD26B5D171A32410` |

## Troubleshooting

- **"EvmError: Revert" on adapter deploy**: The Sepolia token bridge at `0x4Abf633d9c0F4aEebB4C2E3213c7aa1b8505D332` must support `L1_TOKEN_NON_REBASABLE()`. Verify the bridge contract is the correct Lido wstETH bridge on Sepolia.
- **Out of gas**: Increase the gas limit with `--gas-limit` flag.
- **Stale mock price**: The `MockAggregator` always returns `block.timestamp` as `updatedAt`, so staleness checks in `PriceOracle` will pass.
