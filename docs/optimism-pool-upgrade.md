# Optimism Pool Upgrade Test Harness

Fork-based test suite that simulates the Lido Direct Staking pool migration on Optimism before executing on mainnet.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Node.js (for chainlink-csr dependencies)
- RPC URLs in `.env` (see `.env` example below)

## Setup

```sh
# 1. Clone with submodules
git submodule update --init --recursive

# 2. Install dependencies
just setup
```

## Environment

Create a `.env` file in the project root:

```env
L1_RPC_URL...
L2_OPTIMISM_RPC_URL=...
```

## Running Tests

```sh
# Run all upgrade tests
just test-optimism-upgrade

# Or directly with forge
forge test --match-contract OptimismPoolUpgradeTest -vvv
```

## Test Cases

### `test_migrateL2`
Deploys the new `PausableImmutableOraclePool`, migrates sender admin rights and ProxyAdmin ownership, and verifies all immutable/mutable sender state.

### `test_fastStakeAfterMigration`
Runs `fastStake` end to end after migration and verifies user output plus pool token deltas.

### `test_regularStakeAfterMigration`
Validates regular stake (`slowStake`) debits user WETH, returns a non-zero CCIP message ID, and leaves oracle pool balances unchanged.

### `test_migrateL1`
Migrates L1 receiver admin and ProxyAdmin ownership, verifies full post-migration L1 state, then validates L2 ProxyAdmin ownership transfer.

### `test_postMigrationAclRegression`
Checks that the old admin cannot mutate sender/receiver configuration and that the new owner can.

### `test_oldPoolIsolated`
Confirms swaps route only through the new pool after migration while the old pool can still be swept by its owner.

### `test_liquidityProvision`
Verifies owner-funded liquidity expansion, larger post-migration swaps, and owner sweep behavior.

### `test_rebalanceViaSync`
Validates `SYNC_ROLE`-gated `sync` behavior and unauthorized access reverts.

### `test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer`
Full dual-fork CCIP path test: L2 `sync`, L1 message processing, adapter dispatch, and simulated L2 bridge finalization.

The 9 tests above are highlights; the full suite shared via `test/helpers/PoolUpgradeTests.sol` is 17 tests, also covering pool pause/unpause, SyncTrigger thresholds (min/max amount, delay, insufficient fees), consecutive sync cycles, the deployed SyncTrigger operational invariants, and the end-to-end production migration path.

## Architecture

### Dual-Fork Testing

The test uses Foundry's `vm.createFork` to create two independent forks:

```
L1 Fork (Ethereum)                    L2 Fork (Optimism)
  - LidoCustomReceiver (proxy)          - CustomSenderReferral (proxy)
  - ProxyAdmin                          - Old OraclePool
                                        - New PausableImmutableOraclePool
                                        - PriceOracle
```

Each test selects the appropriate fork with `vm.selectFork()` before executing operations.

### Test Layout

- Shared fork/migration/CCIP helpers live in `test/helpers/UpgradeTestBase.sol` (network-agnostic) and `test/helpers/OptimismUpgradeTestBase.sol`.
- Shared test scenarios (17 tests) live in `test/helpers/PoolUpgradeTests.sol`, instantiated per network.
- Optimism test harness lives in `test/OptimismPoolUpgrade.t.sol`.
- CREReceiver unit tests live in `test/CREReceiverTest.t.sol` (34 tests, no fork needed).
- CRE integration tests live in `test/helpers/CREIntegrationTests.sol`, instantiated per network via `test/CREIntegrationTest.t.sol` (9 shared tests × 4 networks = 36 total, fork-based, covers CRE Forwarder → CREReceiver → SyncTrigger path).
- CRE TypeScript encoding tests live in `cre-workflows/sync-automation/main.test.ts` (9 tests, run with `bun test`).
- Shared addresses, roles, and chain constants are centralized in `script/optimism/OptimismMigrationConstants.sol`.

### Migration Flow

```
Stage 1 — Lido Deployer (runDeploy):
  1. Deploy new PausableImmutableOraclePool(sender, WETH, wstETH, oracle, 0, liquidityOwner)
  2. Deploy SyncTrigger, configure (fees, amounts, delay), deploy CREReceiver, wire forwarder
  3. Transfer SyncTrigger ownership to L2 Governance Executor
  4. Transfer CREReceiver ownership to LOL multisig

Stage 2 — Initial Owner (runMigrate):
  5. CustomSender.setOraclePool(newPool)
  6. Grant SYNC_ROLE to SyncTrigger, revoke from old automation
  7. Grant DEFAULT_ADMIN_ROLE to L2 Governance Executor, revoke from self
  8. Transfer ProxyAdmin ownership to L2 Governance Executor

Post-migration:
  9. LOL multisig seeds new pool with wstETH liquidity
```

See [README.md](../README.md) for the full migration runbook across all networks.

### Key Techniques

- **`vm.prank(address)`** — impersonate the on-chain admin to test actual access control
- **`deal(token, address, amount)`** — set token balances without needing whale addresses
- **`vm.createFork(rpcUrl)`** — fork live chain state for realistic testing

## Contract Addresses

### L1 (Ethereum)

| Contract | Address |
|---|---|
| LidoCustomReceiver (proxy) | `0x6F357d53d6bE3238180316BA5F8f11467e164588` |
| ProxyAdmin | `0x88a45d2760b63c1500e3d2e3552b28e5cdaa37bd` |

### L2 (Optimism)

| Contract | Address |
|---|---|
| CustomSenderReferral (proxy) | `0x328de900860816d29D1367F6903a24D8ed40C997` |
| Old OraclePool | `0x6F357d53d6bE3238180316BA5F8f11467e164588` |
| PriceOracle | `0x301cBCDA894c932E9EDa3Cf8878f78304e69E367` |
| WETH | `0x4200000000000000000000000000000000000006` |
| wstETH | `0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb` |

### Roles

| Role | Value |
|---|---|
| DEFAULT_ADMIN_ROLE | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| Current deployer/admin | `0xb5c336a5c60D3482b29d83C742C65AE8351b91a8` |
| LIDO_NEW_L1_OWNER | `0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c` |
| LIDO_L2_GOVERNANCE_EXECUTOR | `0xefa0db536d2c8089685630fafe88cf7805966fc3` |
| L2_LIQUIDITY_OWNER | `L2_LIQUIDITY_OWNER` env (defaults to the network LOL multisig — `OptimismMigrationConstants.LIQUIDITY_OWNER`) |
