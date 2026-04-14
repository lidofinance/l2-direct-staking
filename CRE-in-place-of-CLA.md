# CLA → CRE Migration Plan for Lido Direct Staking

> **Note:** This is the original planning document. The actual implementation diverged:
> - A new **`SyncTrigger`** contract replaces `SyncAutomation` entirely (not a config-only change).
> - `SyncTrigger` is deployed and fully configured by the **Lido Deployer** in Stage 1 (`runDeploy`), not by the Initial Owner.
> - The CRE workflow calls `SyncTrigger.shouldSync()` / `triggerSync()` instead of `checkUpkeep()` / `performUpkeep()`.
> - See [README.md](README.md) for the current migration flow and [LEVERS.md](LEVERS.md) for admin functions.

## Current Setup: How CLA Works in This Repo

The repo uses **Chainlink Automation (CLA)** with a **Custom Logic trigger** for pool rebalancing on Optimism.

**Contract:** `SyncAutomation` (in `lib/chainlink-csr/contracts/automations/SyncAutomation.sol`)

**Flow:**
1. CLA nodes periodically call `checkUpkeep()` on `SyncAutomation`
2. It checks three conditions:
   - Pool WETH balance >= 5 ETH (`minAmount`)
   - 12 hours passed since last sync (`delay`)
   - Balance <= 100 ETH (`maxAmount`)
3. If conditions met, CLA calls `performUpkeep()` (restricted to the CLA **Forwarder** via `onlyForwarder`)
4. `performUpkeep()` calls `CustomSender.sync()` which sends a CCIP message to L1
5. On L1, `LidoCustomReceiver` stakes to Lido and bridges wstETH back to the L2 pool

### Key Addresses

| Component | Address | Network |
|-----------|---------|---------|
| CustomSender (L2) | 0x328de900860816d29D1367F6903a24D8ed40C997 | Optimism |
| LidoCustomReceiver (L1) | 0x6F357d53d6bE3238180316BA5F8f11467e164588 | Ethereum |

### Key Parameters (from `OptimismMigrationConstants.sol`)

| Parameter | Value |
|-----------|-------|
| `L2_SYNC_DELAY` | 12 hours |
| `L2_SYNC_MIN_AMOUNT` | 5 ETH |
| `L2_SYNC_MAX_AMOUNT` | 100 ETH |
| `L2_SYNC_DESTINATION_MAX_FEE` | 0.1 ETH |
| `L2_SYNC_DESTINATION_GAS_LIMIT` | 400,000 |
| `L2_SYNC_ORIGIN_L2_GAS` | 100,000 |

---

## What CRE Changes

CRE replaces the CLA registry/upkeep model with **TypeScript workflows** running on a Chainlink DON. The key architectural difference:

| CLA | CRE |
|-----|-----|
| CLA Registry calls `checkUpkeep`/`performUpkeep` directly | CRE DON runs a TypeScript workflow off-chain |
| CLA Forwarder is the caller | CRE Forwarder → **Receiver contract** → target contract |
| Register upkeep in CLA UI | Deploy workflow via `cre workflow deploy` |
| Polling frequency set by CLA | You control polling via cron schedule |

The critical new piece is a **Receiver contract** — a lightweight on-chain bridge that receives signed reports from the CRE Forwarder, decodes them, and executes calls on the target contract.

### CRE Workflow Execution Pattern

```
CRE DON (off-chain, TypeScript)
    ↓ (encodes + signs report)
CRE Forwarder (on-chain, verifies ECDSA signatures)
    ↓ (onReport call)
Receiver Contract (decodes + executes)
    ↓ (low-level call)
SyncAutomation.performUpkeep() (existing logic)
    ↓
CustomSender.sync() → CCIP → L1 Receiver → Lido
```

---

## Migration Plan

### Step 1: Deploy a Receiver Contract on Optimism

Deploy `CREReceiver.sol` (from `src/cre/`) configured with:
- The CRE **Forwarder address** for Optimism
- Optionally, an `expectedAuthor` for workflow owner validation

The CREReceiver's `onReport()` decodes `(address target, bytes data)` from the report and does `target.call(data)`.

### Step 2: Update SyncAutomation's Access Control

Currently `performUpkeep()` has an `onlyForwarder` modifier that only allows the CLA Forwarder. Two options:

- **Option A (minimal change, recommended):** Call `setForwarder()` to point to the new **Receiver contract** address instead of the CLA forwarder. The Receiver will be the one calling `performUpkeep()`.
- **Option B (cleaner but more invasive):** Grant the Receiver contract the `SYNC_ROLE` on `CustomSender` directly and have the CRE workflow call `sync()` directly, bypassing `SyncAutomation` entirely.

Option A is recommended — it preserves all existing on-chain logic and the `checkUpkeep`/`performUpkeep` pattern.

### Step 3: Write the CRE Workflow (TypeScript)

Based on the **custom-logic-trigger** example in `docs/cla-cre-migration/cla-custom-logic-trigger/`, the workflow would:

```
CronCapability (e.g. every 1-5 minutes)
  → EVMClient.callContract() → checkUpkeep("0x") on SyncAutomation
  → If upkeepNeeded == true:
      → Encode performUpkeep(performData) call
      → runtime.report() → sign the payload
      → EVMClient.writeReport() → send to Receiver on Optimism
```

Config values needed:

```json
{
  "receiverAddress": "<deployed Receiver on Optimism>",
  "targetAddress": "<SyncAutomation address>",
  "chainSelectorName": "optimism-mainnet",
  "schedule": "0 */5 * * * *",
  "checkData": "0x",
  "writeGasLimit": "500000"
}
```

### Step 4: Set Up Project Structure

```
cre-workflows/
├── project.yaml              # DON config, RPC URLs
├── secrets.yaml              # (if needed for API keys)
└── sync-automation/
    ├── workflow.yaml          # Workflow name, paths
    ├── main.ts               # TypeScript workflow logic
    ├── config.test.json      # Test config (Sepolia)
    ├── config.simulate.json  # Local simulation config
    └── config.deploy.json    # Production config (Optimism mainnet)
```

### Step 5: Test

1. **Simulate locally:** `cre workflow simulate . --target=test-settings`
2. **Broadcast to testnet:** `cre workflow simulate . --target=test-settings --broadcast`
3. **Update Solidity tests** to account for the Receiver in the call chain (Forwarder → Receiver → SyncAutomation)

### Step 6: Deploy & Cutover

1. Deploy Receiver contract to Optimism mainnet
2. Deploy CRE workflow: `cre workflow deploy .`
3. Call `setForwarder(receiverAddress)` on SyncAutomation (pointing it to the new Receiver)
4. Cancel/deregister the old CLA upkeep to stop paying CLA fees
5. Monitor via CRE UI at `cre.chain.link/workflows` and on-chain events

### Step 7: Update Documentation & Tests

- Update `docs/optimism-pool-upgrade.md` to reflect CRE setup
- Update `LEVERS.md` with new admin actions (Receiver management)
- Update Forge tests to mock the CRE Forwarder → Receiver → SyncAutomation path

---

## Summary of Changes (Implemented)

| Area | What Changed | Location |
|------|-------------|----------|
| **New contract** | `CREReceiver.sol` + `IReceiver.sol` | `src/cre/` |
| **Existing contract** | `SyncAutomation.setForwarder()` → point to CREReceiver | No code change (config only) |
| **New code** | TypeScript CRE workflow (`main.ts`, `encoding.ts`, `abi.ts` + configs) | `cre-workflows/sync-automation/` |
| **New tooling** | CRE CLI + Bun for workflow management | `cre-workflows/` |
| **Remove** | CLA upkeep registration + LINK funding | (to be done at cutover) |
| **Solidity tests** | 20 unit tests (`CREReceiverTest`) + 8 fork-based integration tests (`CREIntegrationTest`) | `test/` |
| **TypeScript tests** | 11 encoding/decoding tests | `cre-workflows/sync-automation/main.test.ts` |
| **Docs** | Updated LEVERS.md with CREReceiver section | `LEVERS.md` |

The on-chain logic in `SyncAutomation` (checkUpkeep/performUpkeep) stays **unchanged**. The migration is primarily about replacing *who calls* `performUpkeep` — from CLA directly to CRE via the Receiver bridge.

---

## Benefits of CRE Over CLA

| Feature | CLA | CRE |
|---------|-----|-----|
| Off-chain Logic | Limited (`checkUpkeep` only) | Full TypeScript |
| External APIs | Not available | HTTPClient capability |
| Polling Control | Set by CLA registry | Custom cron schedule |
| Multi-chain | Separate upkeeps per chain | Single workflow possible |
| Cost Model | Fixed fees + LINK funding | Usage-based billing |
| Customization | Registry constraints | Fully programmable |
